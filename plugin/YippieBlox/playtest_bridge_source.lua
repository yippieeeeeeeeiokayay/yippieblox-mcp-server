-- playtest_bridge_source.lua
-- Returns the Luau source code for the playtest bridge Script
-- that gets injected into ServerScriptService during playtest.
-- This runs in the SERVER context where HttpService works.

return [==[
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local LogService = game:GetService("LogService")

-- Only run during playtest (server context)
if not RunService:IsRunning() then
	return
end

-- Read config from StringValue children
local urlValue = script:FindFirstChild("_YippieBlox_URL")
local tokenValue = script:FindFirstChild("_YippieBlox_Token")

if not urlValue then
	warn("[MCP-Playtest] No server URL configured, exiting")
	return
end

local BASE_URL = urlValue.Value
local TOKEN = tokenValue and tokenValue.Value or ""

print("[MCP-Playtest] Bridge starting (server context), URL: " .. BASE_URL)

-- Minimal HTTP Bridge

local clientId = nil

local function request(method, path, body)
	local url = BASE_URL .. path
	if clientId then
		local sep = if string.find(path, "?", 1, true) then "&" else "?"
		url = url .. sep .. "clientId=" .. clientId
	end

	local headers = { ["Content-Type"] = "application/json" }
	if TOKEN ~= "" then
		headers["Authorization"] = "Bearer " .. TOKEN
	end

	local opts = { Url = url, Method = method, Headers = headers }
	if body then
		opts.Body = HttpService:JSONEncode(body)
	end

	local ok, response = pcall(function()
		return HttpService:RequestAsync(opts)
	end)

	if not ok then
		return false, nil, tostring(response)
	end

	if response.StatusCode >= 200 and response.StatusCode < 300 then
		local decodeOk, decoded = pcall(function()
			return HttpService:JSONDecode(response.Body)
		end)
		return true, (if decodeOk then decoded else response.Body), nil
	else
		return false, nil, "HTTP " .. tostring(response.StatusCode) .. ": " .. tostring(response.Body)
	end
end

local function pushResponse(requestId, success, result, errorMsg)
	request("POST", "/push", {
		responses = { { request_id = requestId, success = success, result = result, error = errorMsg } },
		events = {},
	})
end

-- Tool Handlers (server-context subset)

local logBuffer = {}
local logConnection = nil
local logSeq = 0

local MESSAGE_TYPE_MAP = {
	[Enum.MessageType.MessageOutput] = "output",
	[Enum.MessageType.MessageInfo] = "info",
	[Enum.MessageType.MessageWarning] = "warning",
	[Enum.MessageType.MessageError] = "error",
}

local function handleTool(toolName, args)
	if toolName == "studio-run_script" then
		local code = args.code
		if not code or code == "" then
			return false, "Missing required argument: code"
		end
		local fn, compileErr = loadstring(code, "=MCP:run_script")
		if not fn then
			return false, "Compilation error: " .. tostring(compileErr)
		end
		local ok, result = pcall(fn)
		if not ok then
			return false, "Runtime error: " .. tostring(result)
		end
		return true, { value = tostring(result) }

	elseif toolName == "studio-status" then
		return true, {
			connected = true,
			playtest = { active = true, mode = "playtest (server context)" },
			context = "playtest-bridge",
		}

	elseif toolName == "studio-logs_subscribe" then
		if logConnection then
			return true, { already_subscribed = true, buffered_count = #logBuffer }
		end
		local includeHistory = args.includeHistory
		if includeHistory == nil then includeHistory = true end
		if includeHistory then
			local ok, history = pcall(function() return LogService:GetLogHistory() end)
			if ok and history then
				local maxHistory = args.maxHistory or 200
				local startIdx = math.max(1, #history - maxHistory + 1)
				for i = startIdx, #history do
					local entry = history[i]
					if string.sub(entry.message, 1, 5) ~= "[MCP]" and string.sub(entry.message, 1, 15) ~= "[MCP-Playtest]" then
						logSeq = logSeq + 1
						table.insert(logBuffer, {
							seq = logSeq,
							ts = entry.timestamp or os.clock(),
							level = MESSAGE_TYPE_MAP[entry.messageType] or "output",
							message = entry.message,
						})
					end
				end
			end
		end
		logConnection = LogService.MessageOut:Connect(function(message, messageType)
			if string.sub(message, 1, 5) == "[MCP]" or string.sub(message, 1, 15) == "[MCP-Playtest]" then return end
			logSeq = logSeq + 1
			table.insert(logBuffer, {
				seq = logSeq,
				ts = os.clock(),
				level = MESSAGE_TYPE_MAP[messageType] or "output",
				message = message,
			})
			while #logBuffer > 500 do
				table.remove(logBuffer, 1)
			end
		end)
		return true, { ok = true, history = logBuffer }

	elseif toolName == "studio-logs_unsubscribe" then
		if logConnection then
			logConnection:Disconnect()
			logConnection = nil
		end
		return true, { ok = true }

	elseif toolName == "studio-logs_get" then
		local sinceSeq = args.sinceSeq or 0
		local limit = args.limit or 200
		local entries = {}
		for _, entry in ipairs(logBuffer) do
			if entry.seq > sinceSeq then
				table.insert(entries, entry)
			end
		end
		if #entries > limit then
			local trimmed = {}
			for i = #entries - limit + 1, #entries do
				table.insert(trimmed, entries[i])
			end
			entries = trimmed
		end
		return true, { entries = entries, nextSeq = logSeq, subscribed = (logConnection ~= nil) }

	elseif toolName == "studio-playtest_stop" then
		local ok, err = pcall(function()
			game:GetService("StudioTestService"):EndTest(nil)
		end)
		if not ok then
			return false, "EndTest() failed: " .. tostring(err)
		end
		return true, { ok = true }

	else
		return false, "Tool '" .. tostring(toolName) .. "' is not available during playtest. Available: studio-run_script, studio-status, studio-logs_subscribe, studio-logs_unsubscribe, studio-logs_get, studio-playtest_stop"
	end
end

-- Register + Poll Loop

task.wait(1)

local ok, data, err = request("POST", "/register", { plugin_version = "0.1.0-playtest" })
if not ok then
	warn("[MCP-Playtest] Failed to register: " .. tostring(err))
	for i = 1, 5 do
		task.wait(2)
		ok, data, err = request("POST", "/register", { plugin_version = "0.1.0-playtest" })
		if ok then break end
		warn("[MCP-Playtest] Retry " .. i .. " failed: " .. tostring(err))
	end
end

if ok and data then
	clientId = data.client_id
	print("[MCP-Playtest] Registered with server, clientId: " .. tostring(clientId))
else
	warn("[MCP-Playtest] Could not register, giving up")
	return
end

while RunService:IsRunning() do
	local pollOk, requests, pollErr = request("GET", "/pull")

	if pollOk and requests and type(requests) == "table" and #requests > 0 then
		for _, req in ipairs(requests) do
			task.spawn(function()
				local toolName = req.tool_name or "unknown"
				local arguments = req.arguments or {}
				local requestId = req.request_id or "?"

				print("[MCP-Playtest] <- " .. toolName .. " (id: " .. requestId .. ")")

				local success, result = handleTool(toolName, arguments)

				local errorMsg = nil
				if not success then
					if type(result) == "string" then
						errorMsg = result
						result = nil
					end
				end

				pushResponse(requestId, success, result, errorMsg)

				local status = if success then "OK" else "FAIL"
				print("[MCP-Playtest] -> " .. toolName .. " " .. status)
			end)
		end
	end
end

print("[MCP-Playtest] Playtest ended, bridge shutting down")
]==]
