# Improved YippieBlox MCP Tool Descriptions

This document contains rewritten tool descriptions following MCP best practices. Each tool description is optimized to help AI agents understand when and how to use each tool.

---

## Core Status & Connection

### studio-status
**Improved Description:**
```
Get current Studio connection state and playtest status. Use this to verify the plugin is connected before executing other tools, or to check if a playtest is currently active. Returns connection status, playtest mode (none/play/run), and server URL.
```

**Input Schema:**
```json
{
  "type": "object",
  "properties": {},
  "required": []
}
```

---

## Script Execution

### studio-run_script
**Improved Description:**
```
Execute Luau code in Studio's edit mode to modify the place structure, inspect the DataModel, or create/modify instances. Only works when NO playtest is active - this is for editing the place file itself. Returns the script's return value and any print() output. Use studio-test_script instead if you need to test runtime behavior, game logic, or anything involving Players.
```

**Input Schema:**
```json
{
  "type": "object",
  "properties": {
    "code": {
      "type": "string",
      "description": "Luau code to execute in edit mode. Can include print() statements for debugging. Use 'return <value>' to return data. Multi-line scripts are supported. Example: 'local part = Instance.new(\"Part\", workspace); part.Size = Vector3.new(4,1,2); return part.Name'"
    }
  },
  "required": ["code"]
}
```

**Response Notes:**
- Returns: `{ success: true, value: "<return value>", logs: ["..."] }` on success
- Returns: `{ success: false, error: "..." }` on failure
- Fails if playtest is active

---

### studio-test_script
**Improved Description:**
```
Execute Luau code inside a live playtest environment to test game logic, physics, character movement, Players service, or any runtime behavior. Automatically starts a playtest, runs your code in the game server, captures all logs and errors, stops the playtest, and returns results. Use this instead of studio-run_script when testing gameplay features, server scripts, or anything requiring a running game. Cannot modify the place structure - use studio-run_script for that.
```

**Input Schema:**
```json
{
  "type": "object",
  "properties": {
    "code": {
      "type": "string",
      "description": "Luau code to execute during playtest. Runs in server context. Can access running game services like Players, RunService, ReplicatedStorage. Use print() for debugging output. Example: 'local players = game.Players:GetPlayers(); print(#players .. \" players in game\"); return workspace.Gravity'"
    }
  },
  "required": ["code"]
}
```

**Response Notes:**
- Automatically manages playtest lifecycle (start → execute → capture logs → stop)
- Returns captured logs, errors, and return value
- Typical execution time: 2-5 seconds

---

## Checkpoint Management (Undo/Redo)

### studio-checkpoint_begin
**Improved Description:**
```
Start a named ChangeHistoryService checkpoint to track modifications you're about to make. Always call this BEFORE making changes you might want to undo later. Returns a checkpointId that you MUST save and pass to studio-checkpoint_end to commit the changes. Use when batch-creating instances, modifying properties, or making any structural edits to the place.
```

**Input Schema:**
```json
{
  "type": "object",
  "properties": {
    "name": {
      "type": "string",
      "description": "Descriptive name for this checkpoint. Will appear in Studio's undo history. Be specific about what changes you're making. Example: 'Create 10 test parts' or 'Modify lighting settings'"
    }
  },
  "required": ["name"]
}
```

**Response:**
```json
{
  "checkpointId": "unique-id-12345",
  "name": "your checkpoint name"
}
```

**Typical Workflow:**
1. Call `studio-checkpoint_begin({ name: "Create parts" })`
2. Save the returned `checkpointId`
3. Execute your changes with `studio-run_script`
4. Call `studio-checkpoint_end({ checkpointId })` to commit
5. Use `studio-checkpoint_undo()` if you need to revert

---

### studio-checkpoint_end
**Improved Description:**
```
Commit and finalize a checkpoint started with studio-checkpoint_begin. This makes the recorded changes available for undo in Studio's history. You MUST provide the checkpointId returned from the begin call. Always call this after completing your modifications - uncommitted checkpoints cannot be undone.
```

**Input Schema:**
```json
{
  "type": "object",
  "properties": {
    "checkpointId": {
      "type": "string",
      "description": "The unique checkpoint ID returned from studio-checkpoint_begin. Required to commit the correct checkpoint. Example: 'checkpoint-abc123'"
    }
  },
  "required": ["checkpointId"]
}
```

**Important:**
- Must be called with the exact checkpointId from the corresponding begin call
- If you lose the checkpointId, the checkpoint cannot be properly committed
- Fails if checkpointId doesn't exist or was already ended

---

### studio-checkpoint_undo
**Improved Description:**
```
Undo the most recent committed checkpoint in Studio's ChangeHistory. Reverts all changes made in the last checkpoint operation. Use when you need to roll back modifications from the current session. Works the same as Edit → Undo in Studio. Cannot undo past the current session start.
```

**Input Schema:**
```json
{
  "type": "object",
  "properties": {},
  "required": []
}
```

**Behavior:**
- Reverts the most recent checkpoint only
- Does not require a checkpointId (always undoes the last one)
- Multiple calls will undo multiple checkpoints sequentially
- Returns success status

---

## Playtest Control

### studio-playtest_play
**Improved Description:**
```
Start a Play mode playtest session - simulates both client and server like pressing F5 in Studio. Use this when you need to test player-facing features: character movement, UI, camera controls, localscripts, or anything requiring a player character. The local player spawns and can be controlled with studio-virtualuser_* tools. Use studio-playtest_run instead for server-only testing without a player character.
```

**Input Schema:**
```json
{
  "type": "object",
  "properties": {},
  "required": []
}
```

**When to Use:**
- Testing player interactions
- Testing character controllers
- Testing client-side UI or GUIs
- Testing localscripts
- Need to use VirtualUser tools for player control

**When NOT to Use:**
- Server-only testing → Use `studio-playtest_run`
- Quick server script testing → Use `studio-test_script`

---

### studio-playtest_run
**Improved Description:**
```
Start a Run mode playtest session - server-only simulation like pressing F8 in Studio. Use this for testing server scripts, game logic, and systems that don't require a player character. No local player spawns, making it faster than Play mode. Good for testing server systems, AI, physics, or backend logic. Use studio-playtest_play if you need to test player interactions or client-side features.
```

**Input Schema:**
```json
{
  "type": "object",
  "properties": {},
  "required": []
}
```

**When to Use:**
- Testing server scripts only
- Testing game systems (NPCs, spawning, etc.)
- Testing physics or workspace behavior
- Faster iteration when player isn't needed

**When NOT to Use:**
- Need player character → Use `studio-playtest_play`
- Quick one-off testing → Use `studio-test_script`

---

### studio-playtest_stop
**Improved Description:**
```
Stop the currently active playtest and return Studio to edit mode. Works for both Play mode (F5) and Run mode (F8) playtests. Always call this when you're done testing to free up resources and allow edit-mode script execution again. Automatically called by studio-test_script but required when manually starting playtests.
```

**Input Schema:**
```json
{
  "type": "object",
  "properties": {},
  "required": []
}
```

**Behavior:**
- Stops any active playtest (Play or Run mode)
- Returns Studio to edit mode
- No-op if no playtest is active
- Required after manual `studio-playtest_play` or `studio-playtest_run` calls

---

## Log Management

### studio-logs_subscribe
**Improved Description:**
```
Subscribe to real-time Studio log output to capture print() statements, errors, and warnings from scripts. Must be called before studio-logs_get will return any data. Logs are buffered in memory until you unsubscribe. Use includeHistory: true to receive logs from before subscription if available. Essential for debugging script execution.
```

**Input Schema:**
```json
{
  "type": "object",
  "properties": {
    "includeHistory": {
      "type": "boolean",
      "description": "Whether to include logs that were generated before subscribing (default: false). Set to true if you need to see output from scripts that ran earlier in the session. Historical buffer is limited."
    }
  },
  "required": []
}
```

**Typical Workflow:**
1. Call `studio-logs_subscribe({ includeHistory: true })`
2. Execute scripts that produce output
3. Call `studio-logs_get()` to retrieve logs
4. Call `studio-logs_unsubscribe()` when done

**Important:**
- Logs accumulate in memory while subscribed
- Always unsubscribe when finished to prevent memory buildup
- Each MCP client connection maintains separate subscription state

---

### studio-logs_get
**Improved Description:**
```
Fetch buffered log entries that have accumulated since subscribing with studio-logs_subscribe. Returns all captured print() output, errors, and warnings. Requires an active subscription - call studio-logs_subscribe first. Logs are cleared from the buffer after retrieval.
```

**Input Schema:**
```json
{
  "type": "object",
  "properties": {},
  "required": []
}
```

**Response Format:**
```json
{
  "logs": [
    {
      "timestamp": "2025-02-17T10:30:45Z",
      "level": "info",
      "message": "Hello from script"
    },
    {
      "timestamp": "2025-02-17T10:30:46Z",
      "level": "error",
      "message": "attempt to index nil value"
    }
  ]
}
```

**Behavior:**
- Returns empty array if no logs buffered
- Clears returned logs from buffer
- Fails if not subscribed

---

### studio-logs_unsubscribe
**Improved Description:**
```
Stop receiving log output and clear the log buffer. Call this when you're done monitoring logs to free up memory. After unsubscribing, studio-logs_get will fail until you subscribe again. Good practice to always unsubscribe when finished debugging.
```

**Input Schema:**
```json
{
  "type": "object",
  "properties": {},
  "required": []
}
```

**Behavior:**
- Clears buffered logs
- Stops capturing new log output
- Returns success status
- Safe to call even if not subscribed

---

## VirtualUser (Player Control)

### studio-virtualuser_key
**Improved Description:**
```
Simulate keyboard input for the player character during Play mode playtest. Control character movement (W/A/S/D keys), jumping (Space), sprinting (Shift), and crouching. Only works during Play mode (F5) - fails in Run mode or edit mode. Use for automated gameplay testing, character controller validation, or testing movement-based mechanics.
```

**Input Schema:**
```json
{
  "type": "object",
  "properties": {
    "key": {
      "type": "string",
      "enum": ["w", "a", "s", "d", "space", "shift"],
      "description": "Keyboard key to simulate. 'w'=forward, 'a'=left, 's'=backward, 'd'=right, 'space'=jump, 'shift'=sprint. Case-insensitive."
    },
    "action": {
      "type": "string",
      "enum": ["press", "release"],
      "description": "Whether to press the key down or release it. Use 'press' to start movement, 'release' to stop. For jumping, use 'press' only."
    }
  },
  "required": ["key", "action"]
}
```

**Example Usage:**
```javascript
// Start moving forward
studio-virtualuser_key({ key: "w", action: "press" })
// Wait 2 seconds
// Stop moving
studio-virtualuser_key({ key: "w", action: "release" })
// Jump
studio-virtualuser_key({ key: "space", action: "press" })
```

**Prerequisites:**
- Must be in Play mode (use `studio-playtest_play` first)
- Player character must exist
- Character must have a Humanoid

---

### studio-virtualuser_mouse_button
**Improved Description:**
```
Simulate mouse click at the player's current camera position during Play mode. Performs a raycast from the character's camera to detect and interact with world objects. Use for testing click-to-interact mechanics, tool activation, or GUI interactions. Only works during Play mode with an active player character.
```

**Input Schema:**
```json
{
  "type": "object",
  "properties": {
    "button": {
      "type": "integer",
      "enum": [1, 2],
      "description": "Mouse button number. 1 = left click (primary), 2 = right click (secondary). Most interactions use button 1."
    },
    "action": {
      "type": "string",
      "enum": ["press", "release"],
      "description": "Whether to press the button down or release it. For a complete click, call press then release."
    }
  },
  "required": ["button", "action"]
}
```

**Example Usage:**
```javascript
// Complete left click
studio-virtualuser_mouse_button({ button: 1, action: "press" })
studio-virtualuser_mouse_button({ button: 1, action: "release" })
```

**Behavior:**
- Raycasts from camera center
- Can interact with ClickDetectors
- Can activate Tools in character's inventory
- Returns hit information if available

**Prerequisites:**
- Play mode active
- Player character with camera

---

### studio-virtualuser_move_mouse
**Improved Description:**
```
Set the player character's facing direction during Play mode by moving the virtual mouse/camera. Controls where the character looks, affecting camera angle and character rotation. Use for testing camera controls, aiming mechanics, or third-person view rotation. Only works in Play mode.
```

**Input Schema:**
```json
{
  "type": "object",
  "properties": {
    "x": {
      "type": "number",
      "description": "Horizontal mouse position or delta. Affects camera yaw (left-right rotation). Range and interpretation depends on camera mode."
    },
    "y": {
      "type": "number",
      "description": "Vertical mouse position or delta. Affects camera pitch (up-down rotation). Range and interpretation depends on camera mode."
    },
    "relative": {
      "type": "boolean",
      "description": "If true, x/y are deltas added to current position. If false, x/y are absolute positions. Default: false."
    }
  },
  "required": ["x", "y"]
}
```

**Example Usage:**
```javascript
// Rotate camera 90 degrees right
studio-virtualuser_move_mouse({ x: 100, y: 0, relative: true })

// Set absolute camera position
studio-virtualuser_move_mouse({ x: 500, y: 300, relative: false })
```

**Prerequisites:**
- Play mode active
- Player character with camera

---

## NPC Driver (Advanced Character Control)

### studio-npc_driver_start
**Improved Description:**
```
Start controlling any NPC character (any Model with a Humanoid) during Play mode playtest. Enables AI-style control for testing NPC movement, pathfinding, and behavior. Provide the full instance path to the character. Once started, use studio-npc_driver_command to move the NPC, make it jump, adjust speed, or face directions. Stop control with studio-npc_driver_stop.
```

**Input Schema:**
```json
{
  "type": "object",
  "properties": {
    "characterPath": {
      "type": "string",
      "description": "Full instance path to the NPC character model. Must contain a Humanoid. Example: 'workspace.NPCs.Zombie1' or 'workspace.Enemies.Guard'. Case-sensitive."
    }
  },
  "required": ["characterPath"]
}
```

**Example Workflow:**
```javascript
// Start controlling NPC
studio-npc_driver_start({ characterPath: "workspace.NPCs.Zombie1" })

// Move to position
studio-npc_driver_command({ 
  characterPath: "workspace.NPCs.Zombie1",
  command: "move_to",
  args: { position: [10, 0, 20] }
})

// Make it jump
studio-npc_driver_command({
  characterPath: "workspace.NPCs.Zombie1", 
  command: "jump"
})

// Stop controlling
studio-npc_driver_stop({ characterPath: "workspace.NPCs.Zombie1" })
```

**Requirements:**
- Play mode or Run mode active
- Target must be a Model with a Humanoid
- Character must be in workspace or accessible via path

**Returns:**
```json
{
  "success": true,
  "characterPath": "workspace.NPCs.Zombie1"
}
```

---

### studio-npc_driver_command
**Improved Description:**
```
Send movement and behavior commands to an NPC being controlled by studio-npc_driver_start. Available commands: 'move_to' (navigate to position), 'jump', 'wait' (pause for duration), 'set_walkspeed', and 'look_at' (face direction). Commands are queued and executed in sequence. Use for testing pathfinding, NPC behavior, or creating automated movement patterns.
```

**Input Schema:**
```json
{
  "type": "object",
  "properties": {
    "characterPath": {
      "type": "string",
      "description": "Full instance path to the NPC being controlled. Must match the path used in studio-npc_driver_start."
    },
    "command": {
      "type": "string",
      "enum": ["move_to", "jump", "wait", "set_walkspeed", "look_at"],
      "description": "Command to execute. 'move_to' navigates to position, 'jump' makes NPC jump, 'wait' pauses for seconds, 'set_walkspeed' changes movement speed, 'look_at' rotates to face position."
    },
    "args": {
      "type": "object",
      "description": "Command-specific arguments. Format varies by command - see examples below.",
      "properties": {
        "position": {
          "type": "array",
          "items": { "type": "number" },
          "description": "For 'move_to' and 'look_at': [x, y, z] world position. Example: [10, 5, -20]"
        },
        "duration": {
          "type": "number",
          "description": "For 'wait': number of seconds to pause. Example: 2.5"
        },
        "speed": {
          "type": "number",
          "description": "For 'set_walkspeed': new WalkSpeed value. Default Roblox character is 16. Range: 0-100+"
        }
      }
    }
  },
  "required": ["characterPath", "command"]
}
```

**Command Examples:**

**move_to:**
```json
{
  "characterPath": "workspace.NPCs.Zombie1",
  "command": "move_to",
  "args": { "position": [25, 0, 10] }
}
```

**jump:**
```json
{
  "characterPath": "workspace.NPCs.Zombie1",
  "command": "jump"
}
```

**wait:**
```json
{
  "characterPath": "workspace.NPCs.Zombie1",
  "command": "wait",
  "args": { "duration": 3 }
}
```

**set_walkspeed:**
```json
{
  "characterPath": "workspace.NPCs.Zombie1",
  "command": "set_walkspeed",
  "args": { "speed": 25 }
}
```

**look_at:**
```json
{
  "characterPath": "workspace.NPCs.Zombie1",
  "command": "look_at",
  "args": { "position": [0, 0, 0] }
}
```

**Prerequisites:**
- Must call `studio-npc_driver_start` first for this character
- Character must have a Humanoid
- Playtest must be active

---

### studio-npc_driver_stop
**Improved Description:**
```
Stop controlling an NPC that was started with studio-npc_driver_start. Releases control and clears any queued commands. The NPC will stop moving and return to idle behavior. Always call this when finished controlling an NPC to free up resources. Safe to call even if the NPC isn't being controlled.
```

**Input Schema:**
```json
{
  "type": "object",
  "properties": {
    "characterPath": {
      "type": "string",
      "description": "Full instance path to the NPC to stop controlling. Must match the path used in studio-npc_driver_start. Example: 'workspace.NPCs.Zombie1'"
    }
  },
  "required": ["characterPath"]
}
```

**Behavior:**
- Stops all movement
- Clears command queue
- Releases control of the NPC
- Returns success even if NPC wasn't being controlled
- Good practice to always call when done

---

## Disabled Tools (Non-Functional)

### studio-capture_screenshot
**Status:** ❌ **DISABLED - DO NOT USE**

**Why It Doesn't Work:**
```
Roblox's CaptureService.CaptureScreenshot() returns rbxtemp:// content IDs that cannot be extracted as actual files from the Roblox security sandbox. While the API exists, there's no way to access the screenshot data for saving or processing. This tool is registered but will always fail.
```

**Tool Description (for reference):**
```
Capture a screenshot of the current Studio viewport. NOTE: This tool is non-functional due to Roblox API limitations. CaptureService returns inaccessible rbxtemp:// URIs that cannot be extracted as files. Will return an error if called. Screenshot capability is not currently available.
```

---

### studio-capture_video_start
**Status:** ❌ **DISABLED - DO NOT USE**

**Why It Doesn't Work:**
```
Roblox's CaptureService does not expose any video recording API to plugins. While screenshots are theoretically possible (though not extractable), video recording is completely unavailable in the plugin environment.
```

**Tool Description (for reference):**
```
Start recording video of Studio viewport. NOTE: This tool is non-functional - Roblox's CaptureService does not expose video recording APIs to plugins. Will return an error if called. Video capture is not currently available.
```

---

### studio-capture_video_stop
**Status:** ❌ **DISABLED - DO NOT USE**

**Why It Doesn't Work:**
```
Same as studio-capture_video_start - no video recording API available.
```

**Tool Description (for reference):**
```
Stop recording video and save the file. NOTE: This tool is non-functional - Roblox's CaptureService does not expose video recording APIs to plugins. Will return an error if called. Video capture is not currently available.
```

---

## Implementation Notes

### How to Apply These Descriptions

These improved descriptions should be placed in your `Tool` definitions in the MCP server code. For example in Rust:

```rust
Tool {
    name: "studio-run_script".to_string(),
    description: Some("Execute Luau code in Studio's edit mode to modify the place structure, inspect the DataModel, or create/modify instances. Only works when NO playtest is active - this is for editing the place file itself. Returns the script's return value and any print() output. Use studio-test_script instead if you need to test runtime behavior, game logic, or anything involving Players.".to_string()),
    input_schema: json!({
        "type": "object",
        "properties": {
            "code": {
                "type": "string",
                "description": "Luau code to execute in edit mode. Can include print() statements for debugging. Use 'return <value>' to return data. Multi-line scripts are supported. Example: 'local part = Instance.new(\"Part\", workspace); part.Size = Vector3.new(4,1,2); return part.Name'"
            }
        },
        "required": ["code"]
    })
}
```

### Key Improvements Made

1. **Clear "when to use" guidance** - Each tool explains when it's appropriate vs alternatives
2. **Prerequisites stated upfront** - Tools mention required conditions (Play mode, subscriptions, etc.)
3. **Failure modes documented** - Tools explain what makes them fail
4. **Parameter descriptions enhanced** - Every parameter has examples and guidance
5. **Workflow examples provided** - Multi-step operations show typical usage patterns
6. **Disabled tools clearly marked** - Non-functional tools explain why they don't work
7. **Concise but complete** - Descriptions are 2-4 sentences, details in parameters
8. **Action-oriented language** - Starts with verbs, focuses on what the tool does

### Testing Recommendations

After implementing these descriptions:

1. Test with Claude to see if tool selection improves
2. Monitor which tools Claude chooses for ambiguous requests
3. Iterate on descriptions that still cause confusion
4. Add examples to documentation based on real usage patterns

### Additional Documentation

Consider creating a separate "Tool Usage Patterns" guide that shows:
- Common workflows (checkpoint → execute → commit)
- Decision trees (when to use run_script vs test_script vs playtest)
- Best practices (always unsubscribe from logs, stop NPCs when done)
- Error handling (what to do when tools fail)
