-- tools/playtest.lua
-- Start/stop playtest sessions and run test scripts via StudioTestService.
-- Uses ExecutePlayModeAsync / ExecuteRunModeAsync (yielding calls).

local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Playtest = {}

-- Track session state
local currentSession = nil
local nextSessionId = 1
local testThread = nil
local lastError = nil

local TEST_RUNNER_NAME = "_YippieBloxTestRunner"

-- Get StudioTestService
local studioTestService = nil
do
	local ok, svc = pcall(function()
		return game:GetService("StudioTestService")
	end)
	if ok and svc then
		studioTestService = svc
		print("[MCP] StudioTestService available")
	else
		warn("[MCP] StudioTestService NOT available: " .. tostring(svc))
	end
end

-- Source code for the test runner Script that gets injected into ServerScriptService.
-- It reads test args, runs the code, captures logs, and calls EndTest with results.
local TEST_RUNNER_SOURCE = [==[
local StudioTestService = game:GetService("StudioTestService")
local LogService = game:GetService("LogService")
local RunService = game:GetService("RunService")

-- Only run during playtest
if not RunService:IsRunning() then
	return
end

local testArgs = StudioTestService:GetTestArgs()
if not testArgs or type(testArgs) ~= "table" or not testArgs.code then
	return
end

local code = testArgs.code
local capturedLogs = {}
local logConnection = nil

-- Map message types
local MESSAGE_TYPE_MAP = {
	[Enum.MessageType.MessageOutput] = "output",
	[Enum.MessageType.MessageInfo] = "info",
	[Enum.MessageType.MessageWarning] = "warning",
	[Enum.MessageType.MessageError] = "error",
}

-- Start capturing logs
logConnection = LogService.MessageOut:Connect(function(message, messageType)
	if string.sub(message, 1, 5) == "[MCP]" then return end
	table.insert(capturedLogs, {
		level = MESSAGE_TYPE_MAP[messageType] or "output",
		message = message,
		ts = os.clock(),
	})
end)

-- Compile and run the test code
local startTime = os.clock()
local fn, compileErr = loadstring(code, "=MCP:test_script")
if not fn then
	if logConnection then logConnection:Disconnect() end
	StudioTestService:EndTest({
		success = false,
		error = "Compilation error: " .. tostring(compileErr),
		logs = capturedLogs,
		duration = os.clock() - startTime,
	})
	return
end

local ok, result = pcall(fn)
local duration = os.clock() - startTime

-- Give a brief moment for any async log output to arrive
task.wait(0.1)

if logConnection then logConnection:Disconnect() end

-- Extract errors from captured logs
local errors = {}
for _, log in ipairs(capturedLogs) do
	if log.level == "error" or log.level == "warning" then
		table.insert(errors, log)
	end
end

StudioTestService:EndTest({
	success = ok,
	value = if ok then tostring(result) else nil,
	error = if not ok then tostring(result) else nil,
	logs = capturedLogs,
	errors = errors,
	duration = duration,
})
]==]

local function injectTestRunner()
	-- Remove old one
	local existing = ServerScriptService:FindFirstChild(TEST_RUNNER_NAME)
	if existing then
		existing:Destroy()
	end

	local runner = Instance.new("Script")
	runner.Name = TEST_RUNNER_NAME
	runner.Source = TEST_RUNNER_SOURCE
	runner.Parent = ServerScriptService
end

local function removeTestRunner()
	local existing = ServerScriptService:FindFirstChild(TEST_RUNNER_NAME)
	if existing then
		existing:Destroy()
	end
end

-- ─── Play / Run / Stop (for interactive playtesting) ─────────

function Playtest.play(args, ctx)
	if currentSession then
		return false, "A playtest session is already running (mode: " .. tostring(currentSession.mode) .. "). Stop it first."
	end

	if not studioTestService then
		return false, "StudioTestService is not available. Cannot start playtest."
	end

	local sessionId = "session_" .. tostring(nextSessionId)
	nextSessionId = nextSessionId + 1
	lastError = nil

	testThread = task.spawn(function()
		local ok, err = pcall(function()
			studioTestService:ExecutePlayModeAsync(nil)
		end)
		if not ok then
			lastError = tostring(err)
			warn("[MCP] ExecutePlayModeAsync error: " .. lastError)
		end
		currentSession = nil
		testThread = nil
		print("[MCP] Play session ended")
		if ctx and ctx.bridge then
			ctx.bridge:pushEvent("studio-playtest_state", {
				active = false,
				sessionId = sessionId,
			})
		end
	end)

	task.wait(0.5)

	if lastError then
		currentSession = nil
		testThread = nil
		return false, "ExecutePlayModeAsync failed: " .. lastError
	end

	local isRunning = pcall(function() return RunService:IsRunning() end) and RunService:IsRunning()

	currentSession = {
		sessionId = sessionId,
		mode = "play",
		startTime = os.clock(),
	}

	if ctx and ctx.bridge then
		ctx.bridge:pushEvent("studio-playtest_state", {
			active = true,
			sessionId = sessionId,
			mode = "play",
		})
	end

	print("[MCP] Play mode started (session: " .. sessionId .. ", isRunning: " .. tostring(isRunning) .. ")")
	return true, {
		sessionId = sessionId,
		status = "started",
		mode = "play",
		isRunning = isRunning,
		service = "StudioTestService",
	}
end

function Playtest.run(args, ctx)
	if currentSession then
		return false, "A playtest session is already running (mode: " .. tostring(currentSession.mode) .. "). Stop it first."
	end

	if not studioTestService then
		return false, "StudioTestService is not available. Cannot start playtest."
	end

	local sessionId = "session_" .. tostring(nextSessionId)
	nextSessionId = nextSessionId + 1
	lastError = nil

	testThread = task.spawn(function()
		local ok, err = pcall(function()
			studioTestService:ExecuteRunModeAsync(nil)
		end)
		if not ok then
			lastError = tostring(err)
			warn("[MCP] ExecuteRunModeAsync error: " .. lastError)
		end
		currentSession = nil
		testThread = nil
		print("[MCP] Run session ended")
		if ctx and ctx.bridge then
			ctx.bridge:pushEvent("studio-playtest_state", {
				active = false,
				sessionId = sessionId,
			})
		end
	end)

	task.wait(0.5)

	if lastError then
		currentSession = nil
		testThread = nil
		return false, "ExecuteRunModeAsync failed: " .. lastError
	end

	local isRunning = pcall(function() return RunService:IsRunning() end) and RunService:IsRunning()

	currentSession = {
		sessionId = sessionId,
		mode = "run",
		startTime = os.clock(),
	}

	if ctx and ctx.bridge then
		ctx.bridge:pushEvent("studio-playtest_state", {
			active = true,
			sessionId = sessionId,
			mode = "run",
		})
	end

	print("[MCP] Run mode started (session: " .. sessionId .. ", isRunning: " .. tostring(isRunning) .. ")")
	return true, {
		sessionId = sessionId,
		status = "started",
		mode = "run",
		isRunning = isRunning,
		service = "StudioTestService",
	}
end

function Playtest.stop(args, ctx)
	if not studioTestService then
		return false, "StudioTestService is not available."
	end

	local stoppedSessionId = currentSession and currentSession.sessionId or nil

	local ok, err = pcall(function()
		studioTestService:EndTest(nil)
	end)
	if not ok then
		return false, "EndTest() failed: " .. tostring(err)
	end

	currentSession = nil

	if ctx and ctx.bridge then
		ctx.bridge:pushEvent("studio-playtest_state", {
			active = false,
			sessionId = stoppedSessionId,
		})
	end

	print("[MCP] Playtest stopped")
	return true, {
		ok = true,
		stoppedSessionId = stoppedSessionId,
	}
end

-- ─── Test Script (one-shot: inject → run → capture → return) ─

function Playtest.testScript(args, ctx)
	if currentSession then
		return false, "A playtest session is already running. Stop it first."
	end

	if not studioTestService then
		return false, "StudioTestService is not available."
	end

	local code = args.code
	if not code or code == "" then
		return false, "Missing required argument: code"
	end

	local mode = args.mode or "run"
	local timeout = args.timeout or 30

	-- Inject the test runner Script into ServerScriptService
	injectTestRunner()

	print("[MCP] Running test script (" .. mode .. " mode, timeout: " .. timeout .. "s)")

	local testResult = nil
	local timedOut = false

	-- ExecuteRunModeAsync/ExecutePlayModeAsync yield until EndTest is called.
	-- The injected test runner calls EndTest with the results.
	-- We run this on a thread so we can apply a timeout.
	local finished = false
	local execThread = task.spawn(function()
		local ok, result = pcall(function()
			if mode == "play" then
				return studioTestService:ExecutePlayModeAsync({ code = code })
			else
				return studioTestService:ExecuteRunModeAsync({ code = code })
			end
		end)

		if ok then
			testResult = result
		else
			testResult = {
				success = false,
				error = "ExecuteAsync failed: " .. tostring(result),
				logs = {},
				errors = {},
				duration = 0,
			}
		end
		finished = true
	end)

	-- Wait for completion or timeout
	local startTime = os.clock()
	while not finished and (os.clock() - startTime) < timeout do
		task.wait(0.2)
	end

	if not finished then
		timedOut = true
		-- Force stop the test
		pcall(function()
			studioTestService:EndTest({
				success = false,
				error = "Test timed out after " .. timeout .. " seconds",
				logs = {},
				errors = {},
				duration = timeout,
			})
		end)
		-- Wait a moment for EndTest to propagate
		task.wait(0.5)
	end

	-- Clean up
	removeTestRunner()
	currentSession = nil

	if not testResult then
		testResult = {
			success = false,
			error = if timedOut then "Test timed out after " .. timeout .. " seconds" else "No result returned",
			logs = {},
			errors = {},
			duration = os.clock() - startTime,
		}
	end

	local status = if testResult.success then "PASS" else "FAIL"
	print("[MCP] Test " .. status .. " (" .. string.format("%.1fs", testResult.duration or 0) .. ")")

	return true, {
		success = testResult.success,
		value = testResult.value,
		error = testResult.error,
		logs = testResult.logs or {},
		errors = testResult.errors or {},
		duration = testResult.duration or 0,
		timedOut = timedOut,
	}
end

return Playtest
