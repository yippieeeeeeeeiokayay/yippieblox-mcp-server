-- init.server.lua
-- YippieBlox MCP Bridge Plugin for Roblox Studio
--
-- This plugin connects to a local Rust MCP server via HTTP,
-- polls for tool requests from AI coding assistants (Claude Code),
-- executes them inside Studio, and returns results.
--
-- During playtest, a server-side Script takes over HTTP polling
-- (plugin context can't use HttpService during playtest).
--
-- Install: Copy this YippieBlox folder to your Studio Plugins directory.
-- Requires: HttpService enabled in Game Settings.

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

-- ─── Require Modules ──────────────────────────────────────────

local Bridge = require(script.bridge)
local ToolRouter = require(script.tools)
local Widget = require(script.ui.widget)
local CommandTrace = require(script.ui.command_trace)
local PLAYTEST_BRIDGE_SOURCE = require(script.playtest_bridge_source)

-- ─── Check HttpService ────────────────────────────────────────

local function checkHttpEnabled()
	local ok, result = pcall(function()
		return HttpService:RequestAsync({
			Url = "http://localhost:1/test",
			Method = "GET",
		})
	end)
	-- If we get a connection refused error, HTTP is enabled but nothing is listening — that's fine.
	-- If we get "Http requests are not enabled", HTTP is disabled.
	if not ok and string.find(tostring(result), "not enabled", 1, true) then
		return false
	end
	return true
end

-- ─── Feature Detection ────────────────────────────────────────

local function detectFeatures()
	local features = {}

	local serviceChecks = {
		"ChangeHistoryService",
		"LogService",
		"TestService",
		"CaptureService",
	}

	for _, name in ipairs(serviceChecks) do
		local ok = pcall(function()
			return game:GetService(name)
		end)
		features[name] = ok
	end

	-- VirtualInputManager needs special handling (LocalUserSecurity)
	local ok = pcall(function()
		return game:GetService("VirtualInputManager")
	end)
	features["VirtualInputManager"] = ok

	if not ok then
		local ok2 = pcall(function()
			return game:GetService("VirtualUser")
		end)
		features["VirtualUser"] = ok2
	end

	return features
end

-- ─── Playtest Bridge Injection ───────────────────────────────

local BRIDGE_SCRIPT_NAME = "_YippieBloxPlaytestBridge"

local function injectPlaytestBridge(serverUrl, token)
	-- Remove old one if it exists
	local existing = ServerScriptService:FindFirstChild(BRIDGE_SCRIPT_NAME)
	if existing then
		existing:Destroy()
	end

	-- Create a Script in ServerScriptService with the bridge code
	local bridgeScript = Instance.new("Script")
	bridgeScript.Name = BRIDGE_SCRIPT_NAME
	bridgeScript.Source = PLAYTEST_BRIDGE_SOURCE

	-- Store config as StringValue children (the script reads these)
	local urlVal = Instance.new("StringValue")
	urlVal.Name = "_YippieBlox_URL"
	urlVal.Value = serverUrl
	urlVal.Parent = bridgeScript

	local tokenVal = Instance.new("StringValue")
	tokenVal.Name = "_YippieBlox_Token"
	tokenVal.Value = token or ""
	tokenVal.Parent = bridgeScript

	bridgeScript.Parent = ServerScriptService
	print("[MCP] Injected playtest bridge into ServerScriptService")
end

local function removePlaytestBridge()
	local existing = ServerScriptService:FindFirstChild(BRIDGE_SCRIPT_NAME)
	if existing then
		existing:Destroy()
		print("[MCP] Removed playtest bridge from ServerScriptService")
	end
end

-- ─── Main Plugin Logic ────────────────────────────────────────

-- Create UI widget
local widgetController = Widget.create(plugin)
local commandTrace = CommandTrace.new(500)

-- State
local bridge = nil
local connected = false
local pollThread = nil
local pollPaused = false
local currentServerUrl = nil
local currentToken = nil

local features = detectFeatures()

-- Build context table passed to tool handlers
local function makeContext()
	return {
		features = features,
		bridge = bridge,
		plugin = plugin,
	}
end

-- ─── Poll Loop ────────────────────────────────────────────────

local function startPollLoop()
	if pollThread then
		pcall(function()
			task.cancel(pollThread)
		end)
	end

	pollThread = task.spawn(function()
		local consecutiveFailures = 0
		local MAX_FAILURES = 3

		while connected do
			-- Pause polling during playtest — HttpService is blocked in plugin context.
			-- The injected server-side Script handles tool calls during playtest.
			if RunService:IsRunning() then
				if not pollPaused then
					pollPaused = true
					print("[MCP] Plugin polling paused (playtest active — server-side bridge takes over)")
					widgetController:setStatus("Playtest active (server bridge)", true)
				end
				task.wait(1)
				continue
			elseif pollPaused then
				pollPaused = false
				print("[MCP] Plugin polling resumed (playtest ended)")
				widgetController:setStatus("Reconnecting...", true)
				-- Re-register since the server may have timed out the client
				local ok, clientId = bridge:register()
				if ok then
					widgetController:setStatus("Connected (" .. clientId .. ")", true)
					consecutiveFailures = 0
				end
			end

			local requests = bridge:pull()

			if #requests > 0 then
				consecutiveFailures = 0

				for _, req in ipairs(requests) do
					-- Dispatch each tool call in a separate thread
					task.spawn(function()
						local startTime = os.clock()
						local toolName = req.tool_name or "unknown"
						local arguments = req.arguments or {}
						local requestId = req.request_id or "?"

						print("[MCP] <- " .. toolName .. " (id: " .. requestId .. ")")

						local success, result = ToolRouter.dispatch(toolName, arguments, makeContext())
						local elapsed = os.clock() - startTime

						-- Send response back to server
						local errorMsg = nil
						if not success then
							if type(result) == "string" then
								errorMsg = result
								result = nil
							elseif type(result) == "table" and result.error then
								errorMsg = result.error
							end
						end

						bridge:pushResponse(requestId, success, result, errorMsg)

						-- Log to command trace
						local details = if not success then tostring(errorMsg or "") else nil
						commandTrace:add(toolName, success, elapsed, details)
						widgetController:addTrace(toolName, success, elapsed, details)

						local status = if success then "OK" else "FAIL"
						print("[MCP] -> " .. toolName .. " " .. status .. " (" .. string.format("%.1fs", elapsed) .. ")")
					end)
				end
			else
				-- Empty poll (timeout or no requests)
				if bridge.lastError then
					consecutiveFailures = consecutiveFailures + 1
					if consecutiveFailures >= MAX_FAILURES then
						warn("[MCP] Too many consecutive failures, reconnecting...")
						connected = false
						widgetController:setStatus("Reconnecting...", false)
						task.wait(5)

						-- Try to re-register
						local ok, clientId = bridge:register()
						if ok then
							connected = true
							widgetController:setStatus("Connected (" .. clientId .. ")", true)
							consecutiveFailures = 0
						else
							widgetController:setStatus("Disconnected (server unreachable)", false)
						end
					end
				else
					consecutiveFailures = 0
				end
			end
		end
	end)
end

-- ─── Connect Handler ──────────────────────────────────────────

local function doConnect(serverUrl, token)
	if connected then
		-- Disconnect
		connected = false
		bridge = nil
		currentServerUrl = nil
		currentToken = nil
		removePlaytestBridge()
		widgetController:setStatus("Disconnected", false)
		widgetController:setConnectButtonText("Connect")
		return
	end

	-- Validate
	if not serverUrl or serverUrl == "" then
		widgetController:setStatus("Error: No server URL", false)
		return
	end
	-- Token is optional — if blank, connect without auth

	-- Check HTTP is enabled
	if not checkHttpEnabled() then
		widgetController:setStatus("Error: HTTP requests not enabled in Game Settings", false)
		warn("[MCP] HTTP requests are not enabled. Go to Game Settings > Security > Allow HTTP Requests.")
		return
	end

	widgetController:setStatus("Connecting...", false)

	bridge = Bridge.new(serverUrl, token)
	local ok, clientId = bridge:register()

	if ok then
		connected = true
		currentServerUrl = serverUrl
		currentToken = token
		widgetController:setStatus("Connected (" .. clientId .. ")", true)
		widgetController:setConnectButtonText("Disconnect")
		print("[MCP] Connected to server. ClientId: " .. clientId)
		print("[MCP] Features: " .. game:GetService("HttpService"):JSONEncode(features))

		-- Inject playtest bridge Script so it's available when playtest starts
		injectPlaytestBridge(serverUrl, token)

		startPollLoop()
	else
		widgetController:setStatus("Failed: " .. tostring(clientId), false)
		warn("[MCP] Failed to connect: " .. tostring(clientId))
	end
end

-- ─── Wire Up UI ───────────────────────────────────────────────

widgetController:onConnect(doConnect)

widgetController:onClear(function()
	commandTrace:clear()
	widgetController:clearTrace()
end)

-- ─── Startup ──────────────────────────────────────────────────

print("[MCP] YippieBlox MCP Bridge Plugin loaded")
print("[MCP] Supported tools: " .. table.concat(ToolRouter.toolNames(), ", "))

-- Auto-connect if server URL is saved (token is optional)
local savedUrl = plugin:GetSetting("YippieBlox_ServerURL")
local savedToken = plugin:GetSetting("YippieBlox_Token") or ""
if savedUrl and savedUrl ~= "" then
	task.delay(1, function()
		print("[MCP] Auto-connecting to " .. savedUrl)
		doConnect(savedUrl, savedToken)
	end)
end
