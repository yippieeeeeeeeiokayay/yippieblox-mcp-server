-- tools/run_script.lua
-- Execute Luau code in Studio's plugin context.

local LogService = game:GetService("LogService")
local RunService = game:GetService("RunService")

local RunScript = {}

function RunScript.execute(args, ctx)
	local code = args.code
	if not code or type(code) ~= "string" then
		return false, "Missing or invalid 'code' argument (must be a string)"
	end

	if code == "" then
		return false, "Empty code string"
	end

	-- Safety: default to blocking execution during playtest unless explicitly allowed
	local allowInPlay = args.allowInPlay or false
	if RunService:IsRunning() and not allowInPlay then
		return false, "Cannot run scripts during playtest. Set allowInPlay=true to override."
	end

	-- Optional log capture
	local captureLogsMs = args.captureLogsMs or 0
	local capturedLogs = {}
	local logConnection = nil

	if captureLogsMs > 0 then
		logConnection = LogService.MessageOut:Connect(function(message, messageType)
			-- Filter our own messages
			if string.find(message, "[MCP]", 1, true) then
				return
			end
			table.insert(capturedLogs, {
				message = message,
				level = messageType.Name,
				ts = os.clock(),
			})
		end)
	end

	-- Compile
	local fn, compileErr = loadstring(code, "=MCP:run_script")
	if not fn then
		if logConnection then
			logConnection:Disconnect()
		end
		return false, "Compile error: " .. tostring(compileErr)
	end

	-- Execute with pcall
	local ok, result = pcall(fn)

	-- Wait for log capture window if specified
	if captureLogsMs > 0 and logConnection then
		task.wait(captureLogsMs / 1000)
		logConnection:Disconnect()
	end

	if not ok then
		return false, {
			error = "Runtime error: " .. tostring(result),
			logs = capturedLogs,
		}
	end

	-- Serialize the result
	local resultStr
	if result == nil then
		resultStr = "nil"
	elseif type(result) == "table" then
		-- Try to JSON-encode tables
		local HttpService = game:GetService("HttpService")
		local encodeOk, encoded = pcall(function()
			return HttpService:JSONEncode(result)
		end)
		resultStr = if encodeOk then encoded else tostring(result)
	else
		resultStr = tostring(result)
	end

	return true, {
		value = resultStr,
		logs = capturedLogs,
	}
end

return RunScript
