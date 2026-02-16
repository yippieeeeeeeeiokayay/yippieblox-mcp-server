# YippieBlox MCP Server — Project Instructions

## What This Is

An MCP (Model Context Protocol) server that bridges AI coding assistants (Claude Code, etc.) with Roblox Studio. Two-part system:

1. **Rust MCP Server** — Speaks MCP over STDIO to the AI client, runs an HTTP bridge on localhost for the Studio plugin
2. **Roblox Studio Plugin (Luau)** — Polls the Rust server over HTTP, executes tool requests inside Studio, returns results

## How to Run

```bash
# Build (debug)
cd server && cargo build

# Build (release)
cd server && cargo build --release

# Run the MCP server (STDIO mode — used by Claude Code)
cd server && cargo run

# Run with explicit config (token is optional)
YIPPIE_PORT=3333 cargo run --manifest-path server/Cargo.toml

# Run with auth enabled
YIPPIE_PORT=3333 YIPPIE_TOKEN=mysecret cargo run --manifest-path server/Cargo.toml

# Run the debug CLI helper
cargo run --manifest-path server/Cargo.toml --bin mcpctl -- status
```

## Connecting Claude Code

Add to your `.mcp.json` (project) or `~/.claude.json` (global):

```json
{
  "mcpServers": {
    "roblox-studio-yippieblox": {
      "command": "/path/to/yippieblox_mcp_server/server/target/release/roblox-studio-yippieblox-mcp-server",
      "args": ["--stdio"],
      "env": {
        "YIPPIE_PORT": "3333"
      }
    }
  }
}
```

## Repo Structure

```
/CLAUDE.md                       ← You are here
/README.md                       ← End-to-end setup guide
/server/                         ← Rust MCP server + HTTP bridge
  Cargo.toml
  src/
    main.rs                      ← Entry point: spawns MCP stdio loop + HTTP bridge
    mcp_stdio.rs                 ← MCP JSON-RPC 2.0 over stdin/stdout
    bridge_http.rs               ← Localhost HTTP endpoints for plugin
    state.rs                     ← Shared state (clients, queues, pending calls)
    config.rs                    ← Config from env/file
    types.rs                     ← Shared types (requests, responses, events, tools)
    captures.rs                  ← Capture file handling + index.json management
    bin/mcpctl.rs                ← Debug CLI for bridge + captures
/plugin/                         ← Roblox Studio plugin
  build_plugin.sh                ← Builds YippieBlox.rbxmx from source
  YippieBlox/                    ← Plugin source (Luau modules)
    init.server.lua              ← Plugin entry point
    bridge.lua                   ← HTTP poll/push logic
    tools/*.lua                  ← Tool handler modules
    ui/*.lua                     ← Dock widget + command trace
    util/*.lua                   ← Ring buffer helpers
```

## Conventions

- **Rust**: Use `rustfmt` defaults. Modules split by concern. All public types in `types.rs`.
- **Luau**: Roblox style — `PascalCase` for services/classes, `camelCase` for variables/functions, `UPPER_SNAKE` for constants.
- **Error handling**: All plugin tool handlers must be `pcall`-wrapped. Rust uses `anyhow` for internal errors, structured MCP errors for client-facing.
- **Logging**: Rust uses `tracing` crate. Plugin prefixes internal messages with `[MCP]` (which are filtered from log capture to avoid loops).

## MCP Tool Schema Summary

All tools are namespaced under `studio.*`:

| Tool | Purpose |
|------|---------|
| `studio.status` | Connection + playtest status |
| `studio.run_script` | Execute Luau code in Studio |
| `studio.checkpoint_begin` | Start ChangeHistoryService waypoint |
| `studio.checkpoint_end` | Commit checkpoint |
| `studio.checkpoint_undo` | Undo to checkpoint |
| `studio.playtest_start` | Start playtest via StudioTestService |
| `studio.playtest_stop` | Stop playtest |
| `studio.logs_subscribe` | Subscribe to LogService output |
| `studio.logs_unsubscribe` | Unsubscribe from logs |
| `studio.logs_get` | Fetch log entries |
| `studio.virtualuser_attach` | Attach VirtualUser controller |
| `studio.virtualuser_key` | Simulate keyboard input |
| `studio.virtualuser_mouse_button` | Simulate mouse button |
| `studio.virtualuser_move_mouse` | Move mouse cursor |
| `studio.npc_driver_start` | Start NPC automation driver |
| `studio.npc_driver_command` | Send command to NPC driver |
| `studio.npc_driver_stop` | Stop NPC driver |
| `studio.capture_screenshot` | Take screenshot via CaptureService |
| `studio.capture_video_start` | Start video recording |
| `studio.capture_video_stop` | Stop video recording |

## Capture Folder

- Default location: `<PROJECT_ROOT>/.roblox-captures/`
- Configurable via `YIPPIE_CAPTURE_DIR` env var or config file
- Contains screenshots, videos, and `index.json` metadata
- **Agents must request permission** for this folder before reading files — do not request broad filesystem access
- To allowlist in Claude Code: use `/permissions` to add the capture folder path

## Auth

- `YIPPIE_TOKEN` is **optional**. If not set, the HTTP bridge accepts all localhost requests without auth.
- If set, both the Rust server and the Studio plugin must use the same token (Bearer auth).
- The plugin's token field in the UI can be left blank when auth is disabled.

## Plugin Behavior

- The plugin **auto-starts** when Studio opens (it's a Script in the Plugins folder).
- On load it prints `[MCP] YippieBlox MCP Bridge Plugin loaded` to the Output window.
- If a server URL was previously saved, it **auto-connects** on startup (token optional).
- After building, copy to Studio: `cp plugin/YippieBlox.rbxmx ~/Documents/Roblox/Plugins/`

## Don'ts

- **No network beyond localhost** — The HTTP bridge binds to `127.0.0.1` only. Never expose externally.
- **No writing outside capture folder** — The server only writes to the capture dir and its own config. No other filesystem writes.
- **No unbounded buffers** — Log ring buffer and command trace are bounded (default 500 entries).
- **No committing secrets** — If using a token, it's config/env only, never committed to repo.
- **No skipping feature detection** — Every Roblox API call (StudioTestService, CaptureService, VirtualUser) must be feature-detected with a clear error if unavailable.

## Testing

```bash
# Run Rust tests
cd server && cargo test

# Clippy lint
cd server && cargo clippy -- -D warnings

# Format check
cd server && cargo fmt -- --check
```
