# YippieBlox Studio Plugin

Roblox Studio plugin that bridges to the YippieBlox MCP server.

## Installation

Build the `.rbxmx` plugin file from source, then copy it to your Studio Plugins directory:

```bash
cd plugin && ./build_plugin.sh
```

**macOS:**
```bash
cp YippieBlox.rbxmx ~/Documents/Roblox/Plugins/YippieBlox.rbxmx
```

**Windows (PowerShell):**
```powershell
Copy-Item YippieBlox.rbxmx "$env:LOCALAPPDATA\Roblox\Plugins\YippieBlox.rbxmx"
```

Then restart Roblox Studio. The plugin loads automatically.

## Setup

### 1. Enable HTTP Requests

In Roblox Studio:
1. Go to **Game Settings** (or **File > Game Settings**)
2. Navigate to **Security**
3. Enable **Allow HTTP Requests**

This is required for the plugin to communicate with the localhost Rust server.

### 2. Configure the Plugin

1. Open the **YippieBlox MCP** dock widget (appears after plugin loads)
2. Enter the **Server URL** (default: `http://localhost:3334`)
3. Enter the **Auth Token** (from the Rust server's stderr output)
4. Click **Connect**

The status indicator turns green when connected.

## Troubleshooting

### "HTTP requests are not enabled"
Enable HTTP requests in Game Settings > Security.

### "Trust check failed" or connection errors
- Make sure you're using `http://localhost:3334`, not `http://127.0.0.1:3334`
- Roblox may block direct IP addresses; `localhost` hostname is required

### Plugin doesn't appear
- Verify `YippieBlox.rbxmx` is in the correct Plugins directory
- Rebuild with `./build_plugin.sh` if the file seems corrupted
- Restart Studio after copying the file

### Connection drops frequently
- The plugin auto-reconnects after 3 consecutive failures
- Check that the Rust server is still running
- Check Studio's Output window for `[MCP]` prefixed messages

## File Structure

```
YippieBlox/
  init.server.lua       Entry point (auto-connects if settings saved)
  bridge.lua            HTTP client for server communication
  tools/
    init.lua            Tool dispatcher
    run_script.lua      Luau code execution
    checkpoint.lua      ChangeHistoryService checkpoints
    playtest.lua        Play/Run session control
    logs.lua            LogService capture
    virtualuser.lua     Input simulation
    npc_driver.lua      NPC automation
    capture.lua         Screenshot capture
  ui/
    widget.lua          Dock widget UI
    command_trace.lua   Trace buffer
  util/
    ring_buffer.lua     Bounded ring buffer
```

## Security Notes

- The plugin only communicates with `localhost` — no external network calls
- Auth tokens are stored in Studio's plugin settings (local to your machine)
- All tool handlers are pcall-wrapped to prevent Studio crashes
- Log messages from the plugin are prefixed with `[MCP]` and filtered to avoid infinite loops
