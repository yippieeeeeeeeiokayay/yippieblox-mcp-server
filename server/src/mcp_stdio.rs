use anyhow::Result;
use serde_json::{json, Value};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::mpsc;

use crate::state::SharedState;
use crate::types::*;

const SERVER_NAME: &str = "roblox-studio-yippieblox-mcp-server";
const SERVER_VERSION: &str = env!("CARGO_PKG_VERSION");
const PROTOCOL_VERSION: &str = "2025-11-25";
const TOOL_CALL_TIMEOUT: Duration = Duration::from_secs(30);

/// Run the MCP STDIO loop: read JSON-RPC from stdin, write responses to stdout.
pub async fn run(state: SharedState) -> Result<()> {
    let stdin = tokio::io::stdin();
    let reader = BufReader::new(stdin);
    let mut lines = reader.lines();

    // All stdout writes go through this channel to prevent interleaving
    let (tx, mut rx) = mpsc::channel::<String>(64);
    tokio::spawn(async move {
        let mut stdout = tokio::io::stdout();
        while let Some(line) = rx.recv().await {
            if stdout.write_all(line.as_bytes()).await.is_err() {
                break;
            }
            if stdout.write_all(b"\n").await.is_err() {
                break;
            }
            let _ = stdout.flush().await;
        }
    });

    while let Some(line) = lines.next_line().await? {
        let line = line.trim().to_string();
        if line.is_empty() {
            continue;
        }

        let msg: JsonRpcMessage = match serde_json::from_str(&line) {
            Ok(m) => m,
            Err(e) => {
                tracing::warn!("Failed to parse JSON-RPC message: {e}");
                let resp = JsonRpcResponse::error(Value::Null, -32700, format!("Parse error: {e}"));
                let _ = tx.send(serde_json::to_string(&resp)?).await;
                continue;
            }
        };

        tracing::info!(method = %msg.method, id = ?msg.id, "Received MCP message");

        // Notifications (no id) don't get a response
        if msg.id.is_none() {
            handle_notification(&msg.method).await;
            continue;
        }

        let id = msg.id.unwrap();
        let response = handle_request(&state, id.clone(), &msg.method, msg.params).await;
        let serialized = serde_json::to_string(&response)?;
        if tx.send(serialized).await.is_err() {
            tracing::error!("stdout writer closed");
            break;
        }
    }

    tracing::info!("stdin closed, MCP session ending");
    Ok(())
}

async fn handle_notification(method: &str) {
    match method {
        "notifications/initialized" => {
            tracing::info!("MCP client initialized");
        }
        "notifications/cancelled" => {
            tracing::info!("MCP client cancelled a request");
        }
        other => {
            tracing::debug!("Unknown notification: {other}");
        }
    }
}

async fn handle_request(
    state: &SharedState,
    id: Value,
    method: &str,
    params: Value,
) -> JsonRpcResponse {
    match method {
        "initialize" => handle_initialize(id),
        "ping" => JsonRpcResponse::success(id, json!({})),
        "tools/list" => handle_tools_list(id),
        "tools/call" => handle_tools_call(state, id, params).await,
        _ => JsonRpcResponse::error(id, -32601, format!("Method not found: {method}")),
    }
}

fn handle_initialize(id: Value) -> JsonRpcResponse {
    JsonRpcResponse::success(
        id,
        json!({
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {
                "tools": {}
            },
            "serverInfo": {
                "name": SERVER_NAME,
                "version": SERVER_VERSION
            }
        }),
    )
}

fn handle_tools_list(id: Value) -> JsonRpcResponse {
    let tools = tool_definitions();
    let tools_json: Vec<Value> = tools
        .into_iter()
        .map(|t| serde_json::to_value(t).unwrap())
        .collect();
    JsonRpcResponse::success(id, json!({ "tools": tools_json }))
}

async fn handle_tools_call(state: &SharedState, id: Value, params: Value) -> JsonRpcResponse {
    let tool_name = match params.get("name").and_then(|v| v.as_str()) {
        Some(n) => n.to_string(),
        None => {
            return JsonRpcResponse::error(id, -32602, "Missing 'name' in tools/call params");
        }
    };
    let arguments = params
        .get("arguments")
        .cloned()
        .unwrap_or(json!({}));

    // studio-status can be answered directly by the server
    if tool_name == "studio-status" {
        return handle_status_tool(state, id).await;
    }

    // Disabled tools — return unsupported immediately
    let disabled_reason = match tool_name.as_str() {
        "studio-capture_screenshot" => {
            Some("Unsupported: CaptureService returns rbxtemp:// content IDs that cannot be extracted as files from a plugin.")
        }
        "studio-capture_video_start" | "studio-capture_video_stop" => {
            Some("Unsupported: CaptureService does not expose a video recording API.")
        }
        _ => None,
    };
    if let Some(reason) = disabled_reason {
        let result = McpToolResult::error_text(reason);
        return JsonRpcResponse::success(id, result.to_value());
    }

    // All other tools require a connected plugin
    if !state.has_connected_client().await {
        let result = McpToolResult::error_text(
            "No Roblox Studio plugin connected. Install the plugin and click Connect.",
        );
        return JsonRpcResponse::success(id, result.to_value());
    }

    // Create oneshot channel for the response
    let request_id = uuid::Uuid::new_v4().to_string();
    let (tx, rx) = tokio::sync::oneshot::channel();

    let bridge_request = BridgeToolRequest {
        request_id: request_id.clone(),
        tool_name: tool_name.clone(),
        arguments,
    };

    state.register_pending(request_id.clone(), tx).await;

    if !state.enqueue_tool_request(bridge_request).await {
        let result = McpToolResult::error_text("Failed to enqueue tool request to plugin");
        return JsonRpcResponse::success(id, result.to_value());
    }

    tracing::info!(tool = %tool_name, request_id = %request_id, "Forwarding tool call to plugin");

    // Await plugin response with timeout
    let start = std::time::Instant::now();
    match tokio::time::timeout(TOOL_CALL_TIMEOUT, rx).await {
        Ok(Ok(response)) => {
            let elapsed = start.elapsed();
            if response.success {
                tracing::info!(tool = %tool_name, elapsed_ms = elapsed.as_millis(), "Tool call succeeded");
                let text = response
                    .result
                    .map(|v| {
                        if v.is_string() {
                            v.as_str().unwrap().to_string()
                        } else {
                            serde_json::to_string_pretty(&v).unwrap_or_default()
                        }
                    })
                    .unwrap_or_else(|| "ok".to_string());
                let result = McpToolResult::text(text);
                JsonRpcResponse::success(id, result.to_value())
            } else {
                let error_msg = response
                    .error
                    .unwrap_or_else(|| "Unknown plugin error".to_string());
                tracing::warn!(tool = %tool_name, elapsed_ms = elapsed.as_millis(), error = %error_msg, "Tool call failed");
                let result = McpToolResult::error_text(error_msg);
                JsonRpcResponse::success(id, result.to_value())
            }
        }
        Ok(Err(_)) => {
            tracing::error!(tool = %tool_name, "Plugin disconnected while processing tool call");
            let result = McpToolResult::error_text("Plugin disconnected while processing tool call");
            JsonRpcResponse::success(id, result.to_value())
        }
        Err(_) => {
            tracing::warn!(tool = %tool_name, "Tool call timed out after {TOOL_CALL_TIMEOUT:?}");
            let result = McpToolResult::error_text(format!(
                "Tool call '{tool_name}' timed out after {}s. Is the Studio plugin running?",
                TOOL_CALL_TIMEOUT.as_secs()
            ));
            JsonRpcResponse::success(id, result.to_value())
        }
    }
}

async fn handle_status_tool(state: &SharedState, id: Value) -> JsonRpcResponse {
    let connected = state.has_connected_client().await;
    let client_id = state.first_client_id().await;
    let (playtest_active, session_id, mode) = state.playtest_info().await;
    let clients: Vec<Value> = state
        .client_info()
        .await
        .into_iter()
        .map(|(id, version, last_poll, is_bridge)| {
            let age_secs = (chrono::Utc::now() - last_poll).num_seconds();
            json!({
                "clientId": id,
                "version": version,
                "isBridge": is_bridge,
                "lastPollSecsAgo": age_secs,
            })
        })
        .collect();

    let result = json!({
        "connected": connected,
        "clientId": client_id,
        "clients": clients,
        "playtest": {
            "active": playtest_active,
            "sessionId": session_id,
            "mode": mode,
        }
    });

    JsonRpcResponse::success(id, McpToolResult {
        content: vec![McpContent::Text {
            text: serde_json::to_string_pretty(&result).unwrap(),
        }],
        is_error: false,
    }.to_value())
}

// ─── Tool Definitions ─────────────────────────────────────────

fn tool_definitions() -> Vec<McpToolDef> {
    vec![
        McpToolDef {
            name: "studio-status".into(),
            description: Some("Get current Studio connection state and playtest status. Use this to verify the plugin is connected before executing other tools, or to check if a playtest is currently active. Returns connection status, playtest mode (none/play/run), and server URL.".into()),
            input_schema: json!({
                "type": "object",
                "properties": {},
                "additionalProperties": false
            }),
        },
        McpToolDef {
            name: "studio-run_script".into(),
            description: Some("Execute Luau code in Studio's edit mode to modify the place structure, inspect the DataModel, or create/modify instances. Only works when NO playtest is active - this is for editing the place file itself. Returns the script's return value and any print() output. Use studio-test_script instead if you need to test runtime behavior, game logic, or anything involving Players.".into()),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "code": {
                        "type": "string",
                        "description": "Luau code to execute in edit mode. Can include print() statements for debugging. Use 'return <value>' to return data. Multi-line scripts are supported. Example: 'local part = Instance.new(\"Part\", workspace); part.Size = Vector3.new(4,1,2); return part.Name'"
                    },
                    "mode": {
                        "type": "string",
                        "enum": ["module", "command"],
                        "description": "Execution mode (default: module)"
                    },
                    "allowInPlay": {
                        "type": "boolean",
                        "description": "Allow execution during a playtest session (default: false). Usually you should use studio-test_script instead."
                    },
                    "captureLogsMs": {
                        "type": "number",
                        "description": "Milliseconds to capture log output after execution (default: 0). Set to e.g. 500 to capture async print() output."
                    }
                },
                "required": ["code"]
            }),
        },
        McpToolDef {
            name: "studio-checkpoint_begin".into(),
            description: Some("Start a named ChangeHistoryService checkpoint to track modifications you're about to make. Always call this BEFORE making changes you might want to undo later. Returns a checkpointId that you MUST save and pass to studio-checkpoint_end to commit the changes. Typical workflow: checkpoint_begin → run_script (make changes) → checkpoint_end.".into()),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "name": {
                        "type": "string",
                        "description": "Descriptive name for this checkpoint. Will appear in Studio's undo history. Be specific about what changes you're making. Example: 'Create 10 test parts' or 'Modify lighting settings'"
                    }
                },
                "required": ["name"]
            }),
        },
        McpToolDef {
            name: "studio-checkpoint_end".into(),
            description: Some("Commit and finalize a checkpoint started with studio-checkpoint_begin. This makes the recorded changes available for undo in Studio's history. You MUST provide the checkpointId returned from the begin call. Always call this after completing your modifications - uncommitted checkpoints cannot be undone.".into()),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "checkpointId": {
                        "type": "string",
                        "description": "The unique checkpoint ID returned from studio-checkpoint_begin. Required to commit the correct checkpoint."
                    },
                    "commitMessage": {
                        "type": "string",
                        "description": "Optional commit description for the undo history"
                    }
                },
                "required": ["checkpointId"]
            }),
        },
        McpToolDef {
            name: "studio-checkpoint_undo".into(),
            description: Some("Undo the most recent committed checkpoint in Studio's ChangeHistory. Reverts all changes made in the last checkpoint operation. Works the same as Edit → Undo in Studio. Multiple calls will undo multiple checkpoints sequentially. Cannot undo past the current session start.".into()),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "checkpointId": {
                        "type": "string",
                        "description": "Optional: specific checkpoint to undo to. If omitted, undoes the most recent checkpoint."
                    }
                }
            }),
        },
        McpToolDef {
            name: "studio-playtest_play".into(),
            description: Some("Start a Play mode playtest session - simulates both client and server like pressing F5 in Studio. Use this when you need to test player-facing features: character movement, UI, camera controls, localscripts, or anything requiring a player character. The local player spawns and can be controlled with studio-virtualuser_* tools. Use studio-playtest_run instead for server-only testing without a player character, or studio-test_script for quick one-off tests.".into()),
            input_schema: json!({
                "type": "object",
                "properties": {}
            }),
        },
        McpToolDef {
            name: "studio-playtest_run".into(),
            description: Some("Start a Run mode playtest session - server-only simulation like pressing F8 in Studio. Use this for testing server scripts, game logic, and systems that don't require a player character. No local player spawns, making it faster than Play mode. Use studio-playtest_play if you need to test player interactions or client-side features, or studio-test_script for quick one-off tests.".into()),
            input_schema: json!({
                "type": "object",
                "properties": {}
            }),
        },
        McpToolDef {
            name: "studio-playtest_stop".into(),
            description: Some("Stop the currently active playtest and return Studio to edit mode. Works for both Play mode (F5) and Run mode (F8) playtests. Always call this when you're done testing to free up resources and allow edit-mode script execution again. Automatically called by studio-test_script, but required when manually starting playtests with studio-playtest_play or studio-playtest_run.".into()),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "sessionId": {
                        "type": "string",
                        "description": "Optional session ID to stop. If omitted, stops the current active playtest."
                    }
                }
            }),
        },
        McpToolDef {
            name: "studio-test_script".into(),
            description: Some("Execute Luau code inside a live playtest environment to test game logic, physics, character movement, Players service, or any runtime behavior. Automatically starts a playtest, runs your code in the game server, captures all logs and errors, stops the playtest, and returns results. Use this instead of studio-run_script when testing gameplay features, server scripts, or anything requiring a running game. Cannot modify the place structure - use studio-run_script for that. Returns: success (bool), value (return value), error (if failed), logs (all captured output), errors (warnings/errors only), duration (seconds).".into()),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "code": {
                        "type": "string",
                        "description": "Luau code to execute during playtest. Runs in server context. Can access running game services like Players, RunService, ReplicatedStorage. Use print() for debugging output. Example: 'local players = game.Players:GetPlayers(); print(#players .. \" players in game\"); return workspace.Gravity'"
                    },
                    "mode": {
                        "type": "string",
                        "enum": ["run", "play"],
                        "description": "Playtest mode: 'run' (server only, faster, no player character) or 'play' (client+server, player spawns). Default: 'run'"
                    },
                    "timeout": {
                        "type": "number",
                        "description": "Max seconds to wait for the test to complete before force-stopping. Default: 30. Increase for long-running tests."
                    }
                },
                "required": ["code"]
            }),
        },
        McpToolDef {
            name: "studio-logs_subscribe".into(),
            description: Some("Subscribe to real-time Studio log output to capture print() statements, errors, and warnings from scripts. Must be called before studio-logs_get will return any data. Logs are buffered in memory until you unsubscribe. Use includeHistory: true to receive logs from before subscription. Essential for debugging script execution. Always unsubscribe when finished to prevent memory buildup.".into()),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "channels": {
                        "type": "array",
                        "items": { "type": "string", "enum": ["output", "info", "warning", "error"] },
                        "description": "Log levels to subscribe to (default: all). Filter to specific levels to reduce noise."
                    },
                    "includeHistory": {
                        "type": "boolean",
                        "description": "Whether to include logs generated before subscribing (default: true). Set to true if you need to see output from scripts that ran earlier in the session."
                    },
                    "maxHistory": {
                        "type": "number",
                        "description": "Max history entries to return (default: 200). Historical buffer is limited."
                    }
                }
            }),
        },
        McpToolDef {
            name: "studio-logs_unsubscribe".into(),
            description: Some("Stop receiving log output and clear the log buffer. Call this when you're done monitoring logs to free up memory. After unsubscribing, studio-logs_get will fail until you subscribe again. Safe to call even if not subscribed.".into()),
            input_schema: json!({
                "type": "object",
                "properties": {},
                "additionalProperties": false
            }),
        },
        McpToolDef {
            name: "studio-logs_get".into(),
            description: Some("Fetch buffered log entries that have accumulated since subscribing with studio-logs_subscribe. Returns all captured print() output, errors, and warnings. Requires an active subscription - call studio-logs_subscribe first. Logs are cleared from the buffer after retrieval.".into()),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "sinceSeq": {
                        "type": "number",
                        "description": "Return only logs after this sequence number. Use to paginate or avoid re-reading old entries."
                    },
                    "limit": {
                        "type": "number",
                        "description": "Max entries to return (default: 200)"
                    },
                    "levels": {
                        "type": "array",
                        "items": { "type": "string", "enum": ["output", "info", "warning", "error"] },
                        "description": "Filter by log level. Omit to get all levels."
                    }
                }
            }),
        },
        McpToolDef {
            name: "studio-virtualuser_key".into(),
            description: Some("Simulate keyboard input for the player character during Play mode playtest (F5). Control character movement (W/A/S/D), jumping (Space), and sprinting (LeftShift/RightShift). Keys stay held until explicitly released with action 'up'. Use 'down' to start holding a key, do other things, then 'up' to release. Space triggers a single jump. Only works during Play mode with a spawned character. Requires studio-playtest_play to be called first.".into()),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "keyCode": {
                        "type": "string",
                        "enum": ["W", "A", "S", "D", "Space", "LeftShift", "RightShift"],
                        "description": "Keyboard key to simulate. W=forward, A=left, S=backward, D=right, Space=jump, LeftShift/RightShift=sprint."
                    },
                    "action": {
                        "type": "string",
                        "enum": ["down", "up"],
                        "description": "'down' = start holding key (default), 'up' = release key. Keys stay held until released. For jumping, just send 'down' once."
                    }
                },
                "required": ["keyCode"]
            }),
        },
        McpToolDef {
            name: "studio-virtualuser_mouse_button".into(),
            description: Some("Simulate mouse click at the player's position during Play mode. Performs a raycast from the character's head toward a world position or named instance to detect and interact with world objects. Reports what was hit (instance name, class, position, distance, material) and detects interactive elements (ClickDetectors, ProximityPrompts). Only works during Play mode (F5) with a spawned character.".into()),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "button": {
                        "type": "integer",
                        "enum": [1, 2],
                        "description": "Mouse button number. 1=left click (primary), 2=right click (secondary). Most interactions use button 1."
                    },
                    "action": {
                        "type": "string",
                        "enum": ["click"],
                        "description": "Action type. Currently only 'click' is supported."
                    },
                    "worldPosition": {
                        "type": "object",
                        "properties": {
                            "x": { "type": "number" },
                            "y": { "type": "number" },
                            "z": { "type": "number" }
                        },
                        "required": ["x", "y", "z"],
                        "description": "World-space position to raycast toward from the character's head. Provide this OR target."
                    },
                    "target": {
                        "type": "string",
                        "description": "Instance path to target (e.g. 'Workspace.MyPart'). If it's a BasePart and no worldPosition given, its position is used. Provide this OR worldPosition."
                    }
                },
                "required": ["button", "action"]
            }),
        },
        McpToolDef {
            name: "studio-virtualuser_move_mouse".into(),
            description: Some("Set the player character's facing direction during Play mode by rotating the HumanoidRootPart to face toward a world position (horizontal rotation only). Use for controlling where the character looks, affecting camera angle and character rotation. Only works during Play mode (F5) with a spawned character. Requires studio-playtest_play to be called first.".into()),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "lookAt": {
                        "type": "object",
                        "properties": {
                            "x": { "type": "number" },
                            "y": { "type": "number" },
                            "z": { "type": "number" }
                        },
                        "required": ["x", "y", "z"],
                        "description": "World-space position to face toward. The character rotates horizontally to look at this point."
                    }
                },
                "required": ["lookAt"]
            }),
        },
        McpToolDef {
            name: "studio-npc_driver_start".into(),
            description: Some("Start controlling any NPC character (any Model with a Humanoid) during Play mode playtest. Enables AI-style control for testing NPC movement, pathfinding, and behavior. Returns a driverId you MUST use for subsequent studio-npc_driver_command and studio-npc_driver_stop calls. Multiple NPCs can be controlled simultaneously. Stop control with studio-npc_driver_stop when finished.".into()),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "target": {
                        "type": "string",
                        "description": "Full instance path to the NPC character model. Must contain a Humanoid. Example: 'Workspace.NPCModel' or 'Workspace.Enemies.Zombie1'. Case-sensitive."
                    }
                },
                "required": ["target"]
            }),
        },
        McpToolDef {
            name: "studio-npc_driver_command".into(),
            description: Some("Send movement and behavior commands to an NPC being controlled by studio-npc_driver_start. Available commands: 'move_to' (navigate to world position), 'jump', 'wait' (pause for duration), 'set_walkspeed' (change movement speed), and 'look_at' (face a position). Commands execute synchronously - move_to blocks until the NPC arrives or times out. Only works during Play mode with an active driver.".into()),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "driverId": {
                        "type": "string",
                        "description": "Driver ID returned from studio-npc_driver_start. Required to identify which NPC to command."
                    },
                    "command": {
                        "type": "object",
                        "description": "Command to execute on the NPC.",
                        "properties": {
                            "type": {
                                "type": "string",
                                "enum": ["move_to", "jump", "wait", "set_walkspeed", "look_at"],
                                "description": "Command type. 'move_to' navigates to position, 'jump' makes NPC jump, 'wait' pauses for ms duration, 'set_walkspeed' changes speed, 'look_at' rotates to face position."
                            },
                            "position": {
                                "type": "object",
                                "properties": {
                                    "x": { "type": "number" },
                                    "y": { "type": "number" },
                                    "z": { "type": "number" }
                                },
                                "description": "Target world position for 'move_to' and 'look_at'. Example: {x: 10, y: 0, z: 20}"
                            },
                            "ms": {
                                "type": "number",
                                "description": "Duration in milliseconds for 'wait' command. Example: 2000 for 2 seconds."
                            },
                            "value": {
                                "type": "number",
                                "description": "Value for 'set_walkspeed'. Default Roblox character WalkSpeed is 16. Range: 0-100+."
                            },
                            "timeout": {
                                "type": "number",
                                "description": "Max seconds to wait for 'move_to' to complete before giving up (default: 15)."
                            }
                        },
                        "required": ["type"]
                    }
                },
                "required": ["driverId", "command"]
            }),
        },
        McpToolDef {
            name: "studio-npc_driver_stop".into(),
            description: Some("Stop controlling an NPC that was started with studio-npc_driver_start. Releases control, stops all movement, and clears any queued commands. The NPC will return to idle. Always call this when finished controlling an NPC to free up resources. Safe to call even if the NPC isn't being controlled.".into()),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "driverId": {
                        "type": "string",
                        "description": "Driver ID returned from studio-npc_driver_start. Identifies which NPC to stop controlling."
                    }
                },
                "required": ["driverId"]
            }),
        },
        McpToolDef {
            name: "studio-capture_screenshot".into(),
            description: Some("DISABLED - DO NOT USE. Capture a screenshot of the Studio viewport. Non-functional due to Roblox API limitations - CaptureService returns inaccessible rbxtemp:// URIs that cannot be extracted as files. Will return an error if called.".into()),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "tag": {
                        "type": "string",
                        "description": "Tag for this capture (e.g. 'after_jump', 'menu_open')"
                    },
                    "includeUI": {
                        "type": "boolean",
                        "description": "Include UI elements if supported"
                    }
                }
            }),
        },
        McpToolDef {
            name: "studio-capture_video_start".into(),
            description: Some("DISABLED - DO NOT USE. Start recording video of Studio viewport. Non-functional - Roblox's CaptureService does not expose video recording APIs to plugins. Will return an error if called.".into()),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "tag": {
                        "type": "string",
                        "description": "Tag for this recording"
                    },
                    "maxSeconds": {
                        "type": "number",
                        "description": "Maximum recording duration in seconds (default: 10)"
                    }
                }
            }),
        },
        McpToolDef {
            name: "studio-capture_video_stop".into(),
            description: Some("DISABLED - DO NOT USE. Stop video recording. Non-functional - Roblox's CaptureService does not expose video recording APIs to plugins. Will return an error if called.".into()),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "recordingId": {
                        "type": "string",
                        "description": "Recording ID to stop"
                    }
                }
            }),
        },
    ]
}
