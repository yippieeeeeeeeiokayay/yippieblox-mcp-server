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
YIPPIE_PORT=3334 cargo run --manifest-path server/Cargo.toml

# Run with auth enabled
YIPPIE_PORT=3334 YIPPIE_TOKEN=mysecret cargo run --manifest-path server/Cargo.toml

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
        "YIPPIE_PORT": "3334"
      }
    }
  }
}
```

## Repo Structure

```
/CLAUDE.md                       ← You are here
/README.md                       ← End-to-end setup guide
/improve_tool_descriptions.md    ← Source of truth for MCP tool descriptions
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
    playtest_bridge_source.lua   ← Server-side bridge injected during playtest
    tools/*.lua                  ← Tool handler modules
    ui/*.lua                     ← Dock widget + command trace
    util/*.lua                   ← Ring buffer helpers
```

## Conventions

- **Rust**: Use `rustfmt` defaults. Modules split by concern. All public types in `types.rs`.
- **Luau**: Roblox style — `PascalCase` for services/classes, `camelCase` for variables/functions, `UPPER_SNAKE` for constants.
- **Error handling**: All plugin tool handlers must be `pcall`-wrapped. Rust uses `anyhow` for internal errors, structured MCP errors for client-facing.
- **Logging**: Rust uses `tracing` crate. Plugin prefixes internal messages with `[MCP]` (which are filtered from log capture to avoid loops).
- **README.md must stay up to date**: When adding, removing, or renaming tools, changing build steps, updating config options, or modifying the smoke test — always update README.md to match. The tool table, smoke test section, and setup instructions must reflect the current state of the code.
- **`improve_tool_descriptions.md` must stay up to date**: This file is the source of truth for MCP tool descriptions. When adding, removing, or changing tools, update this file first, then apply matching changes to the Rust tool definitions in `mcp_stdio.rs`. Tool descriptions, parameter descriptions, and usage examples must stay in sync across all three places (improve_tool_descriptions.md, mcp_stdio.rs, README.md).
- **No Co-Authored-By in commits**: Do not add `Co-Authored-By` trailers to git commit messages.

## MCP Tool Schema Summary

All tools are namespaced under `studio-*`:

### Working Tools (all verified)

| Tool | Purpose |
|------|---------|
| `studio-status` | Connection + playtest status |
| `studio-run_script` | Execute Luau in edit mode only (NOT during playtest). For modifying the place, inspecting/creating instances. |
| `studio-test_script` | Execute Luau in a playtest session (auto start/stop, captures logs+errors). Use instead of run_script when testing game logic, runtime behavior, Players, physics, etc. |
| `studio-checkpoint_begin` | Start ChangeHistoryService waypoint |
| `studio-checkpoint_end` | Commit checkpoint |
| `studio-checkpoint_undo` | Undo to checkpoint |
| `studio-playtest_play` | Start Play mode playtest (F5, client+server) |
| `studio-playtest_run` | Start Run mode playtest (F8, server only) |
| `studio-playtest_stop` | Stop playtest |
| `studio-logs_subscribe` | Subscribe to LogService output |
| `studio-logs_unsubscribe` | Unsubscribe from logs |
| `studio-logs_get` | Fetch log entries |
| `studio-virtualuser_key` | Hold/release keys to control player character (WASD, Space, Shift) during Play mode. Keys stay held until released with action "up". |
| `studio-virtualuser_mouse_button` | Raycast from character to detect/interact with world objects during Play mode |
| `studio-virtualuser_move_mouse` | Set player character facing direction during Play mode |
| `studio-npc_driver_start` | Start controlling any NPC (character with Humanoid) during Play mode |
| `studio-npc_driver_command` | Send commands: move_to, jump, wait, set_walkspeed, look_at |
| `studio-npc_driver_stop` | Stop controlling an NPC |

### Disabled Tools (Roblox API restrictions)

These tools are registered but **non-functional** due to Roblox engine security levels or missing APIs:

| Tool | Reason |
|------|--------|
| `studio-capture_screenshot` | CaptureService returns rbxtemp:// content IDs that cannot be extracted as files. |
| `studio-capture_video_start/stop` | CaptureService does not expose a video recording API. |

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
- On connect, it **injects a playtest bridge Script** into ServerScriptService so MCP tools work during playtest (HttpService is blocked in plugin context during playtest — the server-side Script takes over).
- During playtest, the plugin pauses its own polling and the injected bridge handles tool calls.
- After building, copy to Studio: `cp plugin/YippieBlox.rbxmx ~/Documents/Roblox/Plugins/`

## Don'ts

- **No network beyond localhost** — The HTTP bridge binds to `127.0.0.1` only. Never expose externally.
- **No writing outside capture folder** — The server only writes to the capture dir and its own config. No other filesystem writes.
- **No unbounded buffers** — Log ring buffer and command trace are bounded (default 500 entries).
- **No committing secrets** — If using a token, it's config/env only, never committed to repo.
- **No skipping feature detection** — Every Roblox API call (StudioTestService, CaptureService, VirtualUser) must be feature-detected with a clear error if unavailable.

## Roblox API Gotchas (Learned the Hard Way)

These are recurring pitfalls discovered during development. **Read before modifying plugin code:**

- **`StudioTestService:EndTest()` requires `{}` not `nil`** — Passing `nil` causes "Argument 1 missing or nil". Always pass an empty table `{}` or a result table. Same applies to `ExecutePlayModeAsync({})` and `ExecuteRunModeAsync({})`.
- **`loadstring()` is NOT available in injected Scripts during playtest** — `ServerScriptService.LoadStringEnabled` is `NotScriptable` (can't be set from code). Workaround: bake user code directly into `Script.Source` instead of using loadstring. Plugin context CAN use loadstring, but injected server scripts cannot.
- **HttpService is blocked in plugin context during playtest** — Error: "Http requests can only be executed by game server". The plugin must pause polling and let the injected server-side bridge Script handle HTTP. The bridge runs in ServerScriptService where HttpService works.
- **Plugin scripts re-run in Play/Server DataModels during playtest** — Guard with `if RunService:IsRunning() then return end` at top of `init.server.lua` to prevent the plugin from re-initializing in playtest DataModels (causes duplicate HTTP errors).
- **VirtualInputManager = RobloxScriptSecurity, VirtualUser = LocalUserSecurity** — Neither accessible from plugins. Character control must use direct Humanoid API instead (Move, Jump, WalkSpeed, CFrame).
- **Server-side `Humanoid:Move()` requires claiming network ownership** — During Play mode (F5), the client's ControlScript calls `Humanoid:Move(Vector3.zero)` every frame, overriding server-side movement and causing stuttering. Fix: call `HumanoidRootPart:SetNetworkOwner(nil)` to claim server ownership before moving, and `SetNetworkOwner(player)` to release when done.
- **CaptureService returns `rbxtemp://` content IDs** — These are in-memory only and cannot be extracted as files from a plugin. Screenshot/video tools are disabled.
- **`RunService:IsRunning()` returns false in Edit DataModel during Play mode** — The plugin runs in the Edit DataModel, so it can't use `RunService:IsRunning()` to detect playtest state. Use the `Playtest.isActive()` helper (checks `currentSession`) instead. HttpService still works from the Edit DataModel during Play mode, so the plugin does NOT need to pause polling.
- **Multi-client routing by tool name** — During playtest, both the plugin client and playtest bridge client are registered with the Rust server. `enqueue_tool_request` in `state.rs` routes by tool name. Falls back to most recently polled client if preferred type unavailable. Bridge is identified by `plugin_version` containing "playtest". Tool handlers in the plugin for bridge-only tools should be stubs that return clear errors as a safety net.
  - **Bridge-preferred tools** (require Server DataModel / Play context): `studio-virtualuser_key`, `studio-virtualuser_mouse_button`, `studio-virtualuser_move_mouse`, `studio-npc_driver_start`, `studio-npc_driver_command`, `studio-npc_driver_stop`, `studio-playtest_stop`
  - **Plugin-handled tools** (work from Edit DataModel): `studio-status`, `studio-run_script`, `studio-test_script`, `studio-checkpoint_begin`, `studio-checkpoint_end`, `studio-checkpoint_undo`, `studio-playtest_play`, `studio-playtest_run`, `studio-logs_subscribe`, `studio-logs_unsubscribe`, `studio-logs_get`
- **`test_script` must wait for playtest to fully stop** — After `EndTest` resolves and test results are captured, poll `RunService:IsRunning()` until it returns false before returning. Otherwise back-to-back `test_script` calls fail because Roblox hasn't finished transitioning back to edit mode.
- **`ClickDetector` cannot be triggered from server scripts** — The click flow is client→server. From server context, ClickDetectors are read-only. ProximityPrompts have the same limitation.
- **virtualuser_key must use hold/release, not timed presses** — Keys must simulate real holding: send action "down" to start holding, "up" to release. Do NOT use timed press-and-release ("type" with duration) because round-trip gaps between calls cause stuttering. The default action is "down" (hold). Space is a one-shot jump trigger. Same principle applies to mouse buttons.
- **Always force re-inject the playtest bridge before every playtest** — `checkpoint_undo`, `test_script`, and other DataModel changes can destroy or corrupt the bridge Script in ServerScriptService. Always call `injectPlaytestBridge()` (destroy old + create fresh) before `playtest_play`, `playtest_run`, and `test_script`. Never rely on checking if it exists — just force re-inject.

## Testing

```bash
# Run Rust tests
cd server && cargo test

# Clippy lint
cd server && cargo clippy -- -D warnings

# Format check
cd server && cargo fmt -- --check
```
