# YippieBlox MCP Server (Rust)

The Rust MCP server component. Runs two concurrent tasks:
1. **MCP STDIO** — JSON-RPC 2.0 over stdin/stdout for AI clients
2. **HTTP Bridge** — localhost server for the Roblox Studio plugin

## Build

```bash
cargo build           # debug
cargo build --release # release
```

## Run

```bash
# Debug mode
cargo run

# With config
YIPPIE_PORT=3333 YIPPIE_TOKEN=mytoken cargo run

# Release
./target/release/yippieblox-mcp-server
```

All diagnostic logging goes to **stderr**. Stdout is reserved for MCP protocol messages.

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `YIPPIE_PORT` | `3333` | HTTP bridge listen port |
| `YIPPIE_TOKEN` | (auto-generated) | Bearer token for plugin auth |
| `YIPPIE_CAPTURE_DIR` | `.roblox-captures/` | Screenshot save directory |
| `RUST_LOG` | `info` | Log level filter (tracing) |

## HTTP Bridge Protocol

### POST /register
Register a plugin client. Returns a `clientId` for subsequent requests.

### GET /pull?clientId=...
Long-poll (25s timeout) for pending tool requests. Returns `BridgeToolRequest[]`.

### POST /push?clientId=...
Push tool responses and events. Body: `{ responses: [...], events: [...] }`.

### GET /health
Health check. No auth required. Returns `"ok"`.

### GET /status
Connection status. Returns connected clients, pending calls, log buffer size.

## Module Overview

- **`types.rs`** — All shared types (JSON-RPC, MCP, Bridge, domain)
- **`config.rs`** — Configuration from environment variables
- **`state.rs`** — Shared state with client registry, queues, pending calls
- **`mcp_stdio.rs`** — MCP protocol handler (20 tool definitions, forwarding)
- **`bridge_http.rs`** — Axum HTTP server with auth middleware
- **`captures.rs`** — Capture directory management and OS screenshots

## Tests

```bash
cargo test
cargo clippy -- -D warnings
cargo fmt -- --check
```
