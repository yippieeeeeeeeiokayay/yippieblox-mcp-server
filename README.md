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

- **Rust toolchain** — Install via [rustup](https://rustup.rs/): `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh`
- **Roblox Studio** — Installed and able to open places

## Quick Start

### 1. Build the Rust Server

```bash
cd server
cargo build --release
```

The binary is at `server/target/release/roblox-studio-yippieblox-mcp-server`.

### 2. Build & Install the Studio Plugin

Build the `.rbxmx` plugin file from source, then copy it to your Studio Plugins directory:

```bash
cd plugin && ./build_plugin.sh
```

**macOS:**
```bash
cp plugin/YippieBlox.rbxmx ~/Documents/Roblox/Plugins/YippieBlox.rbxmx
```

**Windows (PowerShell):**
```powershell
Copy-Item plugin\YippieBlox.rbxmx "$env:LOCALAPPDATA\Roblox\Plugins\YippieBlox.rbxmx"
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

### Working Tools

| Tool | Description |
|---|---|
| `studio-status` | Get connection status and playtest state |
| `studio-run_script` | Execute Luau in edit mode only (NOT during playtest). For modifying the place, inspecting/creating instances. |
| `studio-test_script` | Execute Luau in a playtest session — use instead of `run_script` when testing game logic, runtime behavior, Players, physics, etc. Auto-starts playtest, captures all logs/errors, stops playtest, returns results. |
| `studio-checkpoint_begin` | Start ChangeHistoryService recording |
| `studio-checkpoint_end` | Commit recording |
| `studio-checkpoint_undo` | Undo last change |
| `studio-playtest_play` | Start Play mode playtest (client+server, like F5) |
| `studio-playtest_run` | Start Run mode playtest (server only, like F8) |
| `studio-playtest_stop` | Stop playtest |
| `studio-logs_subscribe` | Subscribe to log output |
| `studio-logs_unsubscribe` | Unsubscribe from logs |
| `studio-logs_get` | Fetch buffered log entries |
| `studio-virtualuser_key` | Control player character movement during Play mode (WASD, Space, Shift) |
| `studio-virtualuser_mouse_button` | Raycast from character to detect/interact with world objects during Play mode |
| `studio-virtualuser_move_mouse` | Set player character facing direction during Play mode |

### Disabled Tools (Roblox API restrictions)

These tools are registered but **will not work** due to Roblox security restrictions or missing APIs:

| Tool | Reason |
|---|---|
| `studio-npc_driver_start` | Not yet implemented |
| `studio-npc_driver_command` | Not yet implemented |
| `studio-npc_driver_stop` | Not yet implemented |
| `studio-capture_screenshot` | CaptureService returns rbxtemp:// content IDs that cannot be extracted as files |
| `studio-capture_video_start` | CaptureService does not expose video recording API |
| `studio-capture_video_stop` | Same as above |

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
