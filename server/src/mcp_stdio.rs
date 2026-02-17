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

    let result = json!({
        "connected": connected,
        "clientId": client_id,
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
            description: Some("Get Studio connection status and playtest state".into()),
            input_schema: json!({
                "type": "object",
                "properties": {},
                "additionalProperties": false
            }),
        },
        McpToolDef {
            name: "studio-run_script".into(),
            description: Some("Execute Luau code in Roblox Studio's edit mode (NOT during playtest). Use this for modifying the place, inspecting the data model, creating/editing instances, or any operation that doesn't need a running game. This does NOT work during playtest — use studio-test_script instead if you need to run code in a live game session with access to Players, physics, etc.".into()),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "code": {
                        "type": "string",
                        "description": "Luau source code to execute in Studio's plugin context"
                    },
                    "mode": {
                        "type": "string",
                        "enum": ["module", "command"],
                        "description": "Execution mode (default: module)"
                    },
                    "allowInPlay": {
                        "type": "boolean",
                        "description": "Allow execution during a playtest session (default: false)"
                    },
                    "captureLogsMs": {
                        "type": "number",
                        "description": "Milliseconds to capture log output after execution (default: 0)"
                    }
                },
                "required": ["code"]
            }),
        },
        McpToolDef {
            name: "studio-checkpoint_begin".into(),
            description: Some("Begin a ChangeHistoryService recording for undo/redo tracking".into()),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "name": {
                        "type": "string",
                        "description": "Human-readable name for this checkpoint"
                    }
                },
                "required": ["name"]
            }),
        },
        McpToolDef {
            name: "studio-checkpoint_end".into(),
            description: Some("End and commit a ChangeHistoryService recording".into()),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "checkpointId": {
                        "type": "string",
                        "description": "Recording ID from checkpoint_begin"
                    },
                    "commitMessage": {
                        "type": "string",
                        "description": "Optional commit description"
                    }
                },
                "required": ["checkpointId"]
            }),
        },
        McpToolDef {
            name: "studio-checkpoint_undo".into(),
            description: Some("Undo the last checkpoint or a specific checkpoint".into()),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "checkpointId": {
                        "type": "string",
                        "description": "Optional: specific checkpoint to undo to"
                    }
                }
            }),
        },
        McpToolDef {
            name: "studio-playtest_play".into(),
            description: Some("Start a Play mode playtest in Roblox Studio (client+server, like pressing F5)".into()),
            input_schema: json!({
                "type": "object",
                "properties": {}
            }),
        },
        McpToolDef {
            name: "studio-playtest_run".into(),
            description: Some("Start a Run mode playtest in Roblox Studio (server only, like pressing F8)".into()),
            input_schema: json!({
                "type": "object",
                "properties": {}
            }),
        },
        McpToolDef {
            name: "studio-playtest_stop".into(),
            description: Some("Stop the current playtest session".into()),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "sessionId": {
                        "type": "string",
                        "description": "Optional session ID to stop"
                    }
                }
            }),
        },
        McpToolDef {
            name: "studio-test_script".into(),
            description: Some("Run Luau code in a playtest session with full game context. Use this instead of studio-run_script when you need to test game logic, verify runtime behavior, or access services that only work during gameplay (Players, physics, Humanoids, etc). Automatically starts a playtest, injects the code as a server Script, captures all output logs and errors, stops the playtest, and returns results. Returns: success (bool), value (return value), error (if failed), logs (all output), errors (warnings/errors only), duration (seconds).".into()),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "code": {
                        "type": "string",
                        "description": "Luau code to execute as a test. The code runs in the server context during playtest. Use print() for output, error() or assert() for failures. The return value of the last expression is captured."
                    },
                    "mode": {
                        "type": "string",
                        "enum": ["run", "play"],
                        "description": "Playtest mode: 'run' (server only, faster) or 'play' (client+server). Default: 'run'"
                    },
                    "timeout": {
                        "type": "number",
                        "description": "Max seconds to wait for the test to complete before force-stopping. Default: 30"
                    }
                },
                "required": ["code"]
            }),
        },
        McpToolDef {
            name: "studio-logs_subscribe".into(),
            description: Some("Subscribe to Studio log output via LogService. Returns existing history.".into()),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "channels": {
                        "type": "array",
                        "items": { "type": "string", "enum": ["output", "info", "warning", "error"] },
                        "description": "Log levels to subscribe to (default: all)"
                    },
                    "includeHistory": {
                        "type": "boolean",
                        "description": "Include existing log history (default: true)"
                    },
                    "maxHistory": {
                        "type": "number",
                        "description": "Max history entries to return (default: 200)"
                    }
                }
            }),
        },
        McpToolDef {
            name: "studio-logs_unsubscribe".into(),
            description: Some("Unsubscribe from Studio log output".into()),
            input_schema: json!({
                "type": "object",
                "properties": {},
                "additionalProperties": false
            }),
        },
        McpToolDef {
            name: "studio-logs_get".into(),
            description: Some("Fetch buffered log entries".into()),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "sinceSeq": {
                        "type": "number",
                        "description": "Return logs after this sequence number"
                    },
                    "limit": {
                        "type": "number",
                        "description": "Max entries to return (default: 200)"
                    },
                    "levels": {
                        "type": "array",
                        "items": { "type": "string", "enum": ["output", "info", "warning", "error"] },
                        "description": "Filter by log level"
                    }
                }
            }),
        },
        McpToolDef {
            name: "studio-virtualuser_key".into(),
            description: Some("Simulate keyboard input to control the player character during a Play mode playtest (F5). Supports WASD movement (hold with down/up for sustained movement), Space for jump, LeftShift/RightShift for sprint. Only works during Play mode with a spawned character.".into()),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "keyCode": {
                        "type": "string",
                        "enum": ["W", "A", "S", "D", "Space", "LeftShift", "RightShift"],
                        "description": "Key to simulate: W/A/S/D for movement, Space for jump, LeftShift/RightShift for sprint"
                    },
                    "action": {
                        "type": "string",
                        "enum": ["down", "up", "type"],
                        "description": "'type' = press+release (tap), 'down' = hold key, 'up' = release key. Use down/up for sustained movement."
                    }
                },
                "required": ["keyCode", "action"]
            }),
        },
        McpToolDef {
            name: "studio-virtualuser_mouse_button".into(),
            description: Some("Raycast from the player character toward a world position or named instance during a Play mode playtest (F5). Reports what was hit (instance name, class, position, distance, material) and detects interactive elements (ClickDetectors, ProximityPrompts). Provide worldPosition {x,y,z} and/or target instance path. Only works during Play mode with a spawned character.".into()),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "button": {
                        "type": "integer",
                        "enum": [1, 2],
                        "description": "Mouse button: 1=left, 2=right"
                    },
                    "action": {
                        "type": "string",
                        "enum": ["click"],
                        "description": "Action type"
                    },
                    "worldPosition": {
                        "type": "object",
                        "properties": {
                            "x": { "type": "number" },
                            "y": { "type": "number" },
                            "z": { "type": "number" }
                        },
                        "required": ["x", "y", "z"],
                        "description": "World-space position to raycast toward from the character's head"
                    },
                    "target": {
                        "type": "string",
                        "description": "Instance path (e.g. 'Workspace.MyPart') to target. If it's a BasePart and no worldPosition given, its position is used."
                    }
                },
                "required": ["button", "action"]
            }),
        },
        McpToolDef {
            name: "studio-virtualuser_move_mouse".into(),
            description: Some("Set the player character's facing direction during a Play mode playtest (F5). Rotates the HumanoidRootPart to face toward the given world position (horizontal rotation only). Only works during Play mode with a spawned character.".into()),
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
                        "description": "World-space position to face toward"
                    }
                },
                "required": ["lookAt"]
            }),
        },
        McpToolDef {
            name: "studio-npc_driver_start".into(),
            description: Some("Start controlling an NPC (any character model with a Humanoid) during a Play mode playtest (F5). Provide the instance path to the character model. Returns a driverId for subsequent commands. Multiple drivers can be active simultaneously.".into()),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "target": {
                        "type": "string",
                        "description": "Instance path to the character model (e.g. 'Workspace.NPCModel' or 'Workspace.Enemies.Zombie1')"
                    }
                },
                "required": ["target"]
            }),
        },
        McpToolDef {
            name: "studio-npc_driver_command".into(),
            description: Some("Send a command to a controlled NPC during a Play mode playtest. Commands execute synchronously — move_to blocks until the NPC arrives or times out. Only works during Play mode with an active driver.".into()),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "driverId": {
                        "type": "string",
                        "description": "Driver ID from npc_driver_start"
                    },
                    "command": {
                        "type": "object",
                        "description": "Command to execute",
                        "properties": {
                            "type": {
                                "type": "string",
                                "enum": ["move_to", "jump", "wait", "set_walkspeed", "look_at"],
                                "description": "Command type"
                            },
                            "position": {
                                "type": "object",
                                "properties": {
                                    "x": { "type": "number" },
                                    "y": { "type": "number" },
                                    "z": { "type": "number" }
                                },
                                "description": "Target position for move_to and look_at"
                            },
                            "ms": {
                                "type": "number",
                                "description": "Duration in milliseconds for wait command"
                            },
                            "value": {
                                "type": "number",
                                "description": "Value for set_walkspeed"
                            },
                            "timeout": {
                                "type": "number",
                                "description": "Max seconds to wait for move_to completion (default: 15)"
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
            description: Some("Stop controlling an NPC and release the driver. Only works during Play mode.".into()),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "driverId": {
                        "type": "string",
                        "description": "Driver ID to stop"
                    }
                },
                "required": ["driverId"]
            }),
        },
        McpToolDef {
            name: "studio-capture_screenshot".into(),
            description: Some("Capture a screenshot of the Studio viewport. Saves to the capture folder on disk.".into()),
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
            description: Some("Start recording video of the Studio viewport".into()),
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
            description: Some("Stop video recording".into()),
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
