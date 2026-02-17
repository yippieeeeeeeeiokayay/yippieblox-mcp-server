# YippieBlox MCP Server

An MCP (Model Context Protocol) server that bridges AI coding assistants like **Claude Code** with **Roblox Studio**. It lets an AI agent execute Luau code, manage undo checkpoints, control playtests, simulate input, capture screenshots, and stream logs — all from within Studio.

## Architecture

```
Claude Code (AI client)
    │  MCP over STDIO (JSON-RPC 2.0)
    ▼
┌────────────────────────────┐
│  Rust MCP Server           │
│  • stdin/stdout ↔ MCP      │
│  • localhost HTTP bridge    │
└────────────────────────────┘
    │  HTTP on 127.0.0.1:3334
    ▼
┌────────────────────────────┐
│  Roblox Studio Plugin      │
│  • Polls for tool requests │
│  • Executes inside Studio  │
│  • Pushes results back     │
└────────────────────────────┘
```

## Prerequisites

- **Roblox Studio** — Installed and able to open places

## Quick Start

### 1. Download the Server Binary + Plugin

Download the latest release from **[GitHub Releases](https://github.com/yippieeeeeeeeiokayay/yippieblox-mcp-server/releases)**:

| Platform | File |
|---|---|
| macOS (Apple Silicon) | `yippieblox-mcp-server-macos-arm64.tar.gz` |
| macOS (Intel) | `yippieblox-mcp-server-macos-x64.tar.gz` |
| Linux (x64) | `yippieblox-mcp-server-linux-x64.tar.gz` |
| Windows (x64) | `yippieblox-mcp-server-windows-x64.zip` |
| Studio Plugin | `YippieBlox.rbxmx` |

Extract the server binary and place it somewhere on your PATH or note its location for the MCP config.

<details>
<summary>Build from source instead</summary>

Requires the [Rust toolchain](https://rustup.rs/).

```bash
# Build the server
cd server && cargo build --release
# Binary is at server/target/release/roblox-studio-yippieblox-mcp-server

# Build the plugin
cd plugin && ./build_plugin.sh
```
</details>

### 2. Install the Studio Plugin

Copy `YippieBlox.rbxmx` to your Studio Plugins directory:

**macOS:**
```bash
cp YippieBlox.rbxmx ~/Documents/Roblox/Plugins/YippieBlox.rbxmx
```

**Windows (PowerShell):**
```powershell
Copy-Item YippieBlox.rbxmx "$env:LOCALAPPDATA\Roblox\Plugins\YippieBlox.rbxmx"
```

### 3. Enable HTTP Requests in Studio

1. Open a place in Roblox Studio
2. Go to **Game Settings** → **Security**
3. Enable **Allow HTTP Requests**

### 4. Start the Server

```bash
# With a specific token:
YIPPIE_TOKEN=mysecrettoken ./server/target/release/roblox-studio-yippieblox-mcp-server

# Or let the server generate a random token (printed to stderr):
./server/target/release/roblox-studio-yippieblox-mcp-server
```

### 5. Connect the Plugin

1. In Studio, open the **YippieBlox MCP** dock widget (appears at the bottom)
2. Set the Server URL (default: `http://localhost:3334`)
3. Paste the auth token from the server output
4. Click **Connect**

### 6. Connect Your AI Client

#### Claude Code (CLI)

Run this from your project directory:

```bash
claude mcp add roblox-studio-yippieblox \
  --env YIPPIE_TOKEN=mysecrettoken \
  --env YIPPIE_PORT=3334 \
  -- /absolute/path/to/server/target/release/roblox-studio-yippieblox-mcp-server --stdio
```

Or manually add to your project's `.mcp.json` (or `~/.claude.json` for global):

```json
{
  "mcpServers": {
    "roblox-studio-yippieblox": {
      "command": "/absolute/path/to/server/target/release/roblox-studio-yippieblox-mcp-server",
      "args": ["--stdio"],
      "env": {
        "YIPPIE_TOKEN": "mysecrettoken",
        "YIPPIE_PORT": "3334"
      }
    }
  }
}
```

Then restart Claude Code. The `studio-*` tools will be available.

#### Claude Desktop

Open **Settings → Developer → Edit Config**, or edit the config file directly:

- **macOS:** `~/Library/Application Support/Claude/claude_desktop_config.json`
- **Windows:** `%APPDATA%\Claude\claude_desktop_config.json`

Add the following:

```json
{
  "mcpServers": {
    "roblox-studio-yippieblox": {
      "command": "/absolute/path/to/server/target/release/roblox-studio-yippieblox-mcp-server",
      "args": ["--stdio"],
      "env": {
        "YIPPIE_TOKEN": "mysecrettoken",
        "YIPPIE_PORT": "3334"
      }
    }
  }
}
```

Restart Claude Desktop after saving. The `studio-*` tools will appear in the tool picker.

## Configuration

| Env Variable | Default | Description |
|---|---|---|
| `YIPPIE_PORT` | `3334` | HTTP bridge port |
| `YIPPIE_TOKEN` | (auto-generated) | Bearer token for auth |
| `YIPPIE_CAPTURE_DIR` | `.roblox-captures/` | Screenshot save directory |

## MCP Tools

All tools are namespaced under `studio-*`. For full descriptions, parameter schemas, and usage examples, see [`improve_tool_descriptions.md`](improve_tool_descriptions.md).

### Script Execution

| Tool | When to Use |
|---|---|
| `studio-run_script` | Execute Luau in **edit mode only** to modify the place, inspect the DataModel, or create/modify instances. Does NOT work during playtest. |
| `studio-test_script` | Execute Luau in a **live playtest** to test game logic, Players, physics, runtime behavior. Auto-starts playtest, captures logs/errors, stops playtest, returns results. |

**Which one do I use?** Use `run_script` to change the place file (add parts, edit properties, inspect the tree). Use `test_script` to test how things behave at runtime (game logic, player interactions, physics).

### Checkpoint Management (Undo/Redo)

| Tool | Description |
|---|---|
| `studio-checkpoint_begin` | Start tracking changes. Returns a `checkpointId` — save it. |
| `studio-checkpoint_end` | Commit changes using the `checkpointId` from begin. |
| `studio-checkpoint_undo` | Undo the most recent committed checkpoint. |

**Typical workflow:** `checkpoint_begin` → `run_script` (make changes) → `checkpoint_end` → `checkpoint_undo` (if needed).

### Playtest Control

| Tool | Description |
|---|---|
| `studio-playtest_play` | Start Play mode (F5) — client+server, player character spawns. Required for virtualuser/NPC tools. |
| `studio-playtest_run` | Start Run mode (F8) — server only, no player. Faster for server-only testing. |
| `studio-playtest_stop` | Stop any active playtest and return to edit mode. |
| `studio-status` | Check connection status and whether a playtest is active. |

### Log Streaming

| Tool | Description |
|---|---|
| `studio-logs_subscribe` | Start capturing print(), errors, and warnings. Call before `logs_get`. |
| `studio-logs_get` | Fetch buffered log entries. Requires active subscription. |
| `studio-logs_unsubscribe` | Stop capturing and clear buffer. Always call when done. |

### Player Control (Play mode only)

These tools require an active Play mode playtest (`studio-playtest_play`).

| Tool | Description |
|---|---|
| `studio-virtualuser_key` | Hold/release keys (W/A/S/D, Space, Shift) to move the player character. Keys stay held until released. |
| `studio-virtualuser_mouse_button` | Raycast from character to detect/interact with world objects. Reports hit info. |
| `studio-virtualuser_move_mouse` | Set player character facing direction (horizontal rotation). |

### NPC Control (Play mode only)

| Tool | Description |
|---|---|
| `studio-npc_driver_start` | Start controlling any Model with a Humanoid. Returns a `driverId`. |
| `studio-npc_driver_command` | Send commands: `move_to`, `jump`, `wait`, `set_walkspeed`, `look_at`. Uses the `driverId`. |
| `studio-npc_driver_stop` | Stop controlling an NPC and release the driver. |

### Disabled Tools

These are registered but **non-functional** due to Roblox API restrictions. Do not use them.

| Tool | Reason |
|---|---|
| `studio-capture_screenshot` | CaptureService returns rbxtemp:// content IDs that cannot be extracted as files |
| `studio-capture_video_start/stop` | CaptureService does not expose video recording API |

## Capture Folder

Screenshots are saved to the capture directory (default: `.roblox-captures/` in the working directory). An `index.json` file tracks all captures with metadata.

**For Claude Code to read capture files**, you must allowlist the capture folder in your permissions. Use `/permissions` in Claude Code to add the capture directory path. Agents should not request broad filesystem access — only the specific capture folder.

If the capture folder is outside the repo (e.g. `~/Pictures/RobloxCaptures/`), OS-level folder access may require user approval on macOS.

## Smoke Test

After setup, verify everything works:

```
1. Start the Rust server
2. Open Studio, install plugin, connect with token
3. From Claude Code (or any MCP client), run these tool calls:

   studio-status
   → Should show connected: true

   studio-logs_subscribe({ includeHistory: true })
   → Should return ok with log history

   studio-run_script({ code: "print('Hello from MCP!') return 42" })
   → Should return value: "42" and the print appears in Studio Output

   studio-checkpoint_begin({ name: "Test checkpoint" })
   studio-run_script({ code: "local p = Instance.new('Part', workspace) p.Name = 'MCPTestPart'" })
   studio-checkpoint_end({ checkpointId: "<id from begin>" })
   studio-checkpoint_undo({})
   → MCPTestPart should disappear from workspace

   studio-test_script({ code: "print('Hello from playtest!') return workspace:GetChildren()" })
   → Should return success: true, value, and captured logs

   studio-playtest_run({})
   → Studio should enter Run mode (F8)
   studio-playtest_stop({})
   → Studio should return to Edit mode

   studio-logs_unsubscribe({})
```

## Security Notes

- The HTTP bridge binds to **`127.0.0.1` only** — it is not accessible from the network
- A **Bearer token** is required for all bridge endpoints (except `/health`)
- **Never expose the bridge port publicly** — it is designed for localhost communication only
- The server only writes files to the configured capture directory
- The auth token should not be committed to version control — use environment variables

## Debug CLI

A `mcpctl` helper binary is included for debugging:

```bash
# Check server health
cargo run --bin mcpctl -- health

# Show connection status
YIPPIE_TOKEN=mysecrettoken cargo run --bin mcpctl -- status

# List captures
cargo run --bin mcpctl -- captures --dir .roblox-captures
```

## Project Structure

```
/CLAUDE.md                          Project instructions for AI agents
/README.md                          This file
/improve_tool_descriptions.md       Source of truth for MCP tool descriptions
/server/
  Cargo.toml                        Rust dependencies
  src/
    main.rs                         Entry point
    mcp_stdio.rs                    MCP JSON-RPC over stdin/stdout
    bridge_http.rs                  HTTP bridge for plugin
    state.rs                        Shared state
    config.rs                       Configuration
    types.rs                        All data types
    captures.rs                     Capture file management
    bin/mcpctl.rs                   Debug CLI
/plugin/
  build_plugin.sh                   Builds YippieBlox.rbxmx from source
  YippieBlox/                       Plugin source (Luau modules)
    init.server.lua                 Plugin entry point
    bridge.lua                      HTTP bridge client
    tools/                          Tool handler modules
    ui/                             Widget and command trace
    util/                           Ring buffer, helpers
```
