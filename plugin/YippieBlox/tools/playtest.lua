-- tools/playtest.lua
-- Start/stop playtest sessions via available Studio services.
-- Uses feature detection since StudioTestService may not be available in all contexts.

local RunService = game:GetService("RunService")

local Playtest = {}

-- Track session state
local currentSession = nil
local nextSessionId = 1

-- Feature-detect available playtest methods
local function getTestService()
	-- Try the documented TestService first
	local ok, svc = pcall(function()
		return game:GetService("TestService")
	end)
	if ok and svc then
		return svc, "TestService"
	end
	return nil, nil
end

function Playtest.start(args, ctx)
	if RunService:IsRunning() then
		return false, "A playtest session is already running. Stop it first."
	end

	local mode = args.mode or "play"
	local sessionId = "session_" .. tostring(nextSessionId)
	nextSessionId = nextSessionId + 1

	local testService, serviceName = getTestService()

	if mode == "run" then
		-- "Run" mode: server-only, simplest to invoke
		if testService and testService.Run then
			local ok, err = pcall(function()
				testService:Run()
			end)
			if not ok then
				return false, "TestService:Run() failed: " .. tostring(err)
			end
		else
			-- Fallback: RunService
			local ok, err = pcall(function()
				RunService:Run()
			end)
			if not ok then
				return false, "RunService:Run() failed: " .. tostring(err)
			end
		end
	elseif mode == "play" then
		-- "Play" mode: client+server
		if testService and testService.Play then
			local ok, err = pcall(function()
				testService:Play()
			end)
			if not ok then
				return false, "TestService:Play() failed: " .. tostring(err)
			end
		else
			-- Fallback: try Run mode with a note
			local ok, err = pcall(function()
				RunService:Run()
			end)
			if not ok then
				return false, "Could not start playtest: " .. tostring(err)
			end
			mode = "run"
		end
	elseif mode == "startServer" then
		if testService and testService.Run then
			local ok, err = pcall(function()
				testService:Run()
			end)
			if not ok then
				return false, "TestService:Run() failed: " .. tostring(err)
			end
		else
			return false, "startServer mode requires TestService which is not available"
		end
	else
		return false, "Invalid mode: " .. tostring(mode) .. ". Use 'play', 'run', or 'startServer'."
	end

	currentSession = {
		sessionId = sessionId,
		mode = mode,
		startTime = os.clock(),
	}

	-- Push playtest state event to bridge
	if ctx and ctx.bridge then
		ctx.bridge:pushEvent("studio.playtest_state", {
			active = true,
			sessionId = sessionId,
			mode = mode,
		})
	end

	print("[MCP] Playtest started: " .. mode .. " (session: " .. sessionId .. ")")
	return true, {
		sessionId = sessionId,
		status = "started",
		mode = mode,
		service = serviceName or "RunService",
	}
end

function Playtest.stop(args, ctx)
	if not RunService:IsRunning() then
		return false, "No playtest session is currently running."
	end

	local testService = getTestService()
	local stoppedSessionId = currentSession and currentSession.sessionId or nil

	if testService and testService.Stop then
		local ok, err = pcall(function()
			testService:Stop()
		end)
		if not ok then
			return false, "TestService:Stop() failed: " .. tostring(err)
		end
	else
		local ok, err = pcall(function()
			RunService:Stop()
		end)
		if not ok then
			return false, "RunService:Stop() failed: " .. tostring(err)
		end
	end

	currentSession = nil

	-- Push playtest state event
	if ctx and ctx.bridge then
		ctx.bridge:pushEvent("studio.playtest_state", {
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

return Playtest
