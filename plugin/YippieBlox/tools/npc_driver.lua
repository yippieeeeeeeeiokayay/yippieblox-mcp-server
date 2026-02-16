-- tools/npc_driver.lua
-- NPC automation driver: controls a character model in workspace during playtests.
-- Provides move_to, jump, interact, wait, and set_walkspeed commands.

local RunService = game:GetService("RunService")

local NpcDriver = {}

-- Active drivers keyed by driverId
local drivers = {}
local nextDriverId = 1

-- ─── Driver Instance ──────────────────────────────────────────

local DriverInstance = {}
DriverInstance.__index = DriverInstance

function DriverInstance.new(driverId, npcPath, config)
	return setmetatable({
		driverId = driverId,
		npcPath = npcPath,
		config = config or {},
		running = false,
		commandQueue = {},
		thread = nil,
		character = nil,
		humanoid = nil,
	}, DriverInstance)
end

function DriverInstance:start()
	-- Find the character in workspace
	local target = workspace:FindFirstChild(self.npcPath, true)
	if not target then
		return false, "Character not found at path: " .. tostring(self.npcPath)
	end

	local humanoid = target:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return false, "No Humanoid found in character: " .. tostring(self.npcPath)
	end

	self.character = target
	self.humanoid = humanoid
	self.running = true

	-- Spawn the command processing coroutine
	self.thread = task.spawn(function()
		while self.running do
			if #self.commandQueue > 0 then
				local cmd = table.remove(self.commandQueue, 1)
				self:executeCommand(cmd)
			else
				task.wait(0.1)
			end
		end
	end)

	return true
end

function DriverInstance:executeCommand(cmd)
	local cmdType = cmd.type
	if not cmdType then
		warn("[MCP] NPC driver: command missing 'type' field")
		return
	end

	if cmdType == "move_to" then
		local pos = cmd.position or {}
		local target = Vector3.new(pos.x or 0, pos.y or 0, pos.z or 0)
		if self.humanoid then
			self.humanoid:MoveTo(target)
			-- Wait for movement to finish (with timeout)
			local moveFinished = false
			local conn = self.humanoid.MoveToFinished:Connect(function()
				moveFinished = true
			end)
			local elapsed = 0
			while not moveFinished and elapsed < 30 and self.running do
				task.wait(0.1)
				elapsed = elapsed + 0.1
			end
			conn:Disconnect()
		end

	elseif cmdType == "jump" then
		if self.humanoid then
			self.humanoid.Jump = true
		end

	elseif cmdType == "interact" then
		local targetPath = cmd.targetPath
		if targetPath then
			local target = workspace:FindFirstChild(targetPath, true)
			if target then
				-- Try to fire ProximityPrompt if present
				local prompt = target:FindFirstChildOfClass("ProximityPrompt")
				if prompt then
					pcall(function()
						prompt:InputHoldBegin()
						task.wait(prompt.HoldDuration or 0)
						prompt:InputHoldEnd()
					end)
				end
				-- Try to fire ClickDetector
				local detector = target:FindFirstChildOfClass("ClickDetector")
				if detector then
					pcall(function()
						detector:_fireClick()
					end)
				end
			end
		end

	elseif cmdType == "wait" then
		local ms = cmd.ms or 1000
		task.wait(ms / 1000)

	elseif cmdType == "set_walkspeed" then
		local value = cmd.value
		if self.humanoid and value then
			self.humanoid.WalkSpeed = value
		end

	else
		warn("[MCP] NPC driver: unknown command type: " .. tostring(cmdType))
	end
end

function DriverInstance:queueCommand(cmd)
	table.insert(self.commandQueue, cmd)
end

function DriverInstance:stop()
	self.running = false
	if self.thread then
		pcall(function()
			task.cancel(self.thread)
		end)
		self.thread = nil
	end
end

-- ─── Tool Handlers ────────────────────────────────────────────

function NpcDriver.start(args, _ctx)
	if not RunService:IsRunning() then
		return false, "NPC driver requires an active playtest session. Start a playtest first."
	end

	local mode = args.mode or "scriptedNPC"
	local npcPath = args.npcPath or args.driverName or "MCPDriver"

	if mode == "scriptedNPC" and not npcPath then
		return false, "Missing 'npcPath' for scriptedNPC mode"
	end

	local driverId = "drv_" .. tostring(nextDriverId)
	nextDriverId = nextDriverId + 1

	local driver = DriverInstance.new(driverId, npcPath, args)
	local ok, err = driver:start()
	if not ok then
		return false, err
	end

	drivers[driverId] = driver

	print("[MCP] NPC driver started: " .. driverId .. " (path: " .. npcPath .. ")")
	return true, {
		ok = true,
		driverId = driverId,
		npcPath = npcPath,
		mode = mode,
	}
end

function NpcDriver.command(args, _ctx)
	local driverId = args.driverId
	if not driverId then
		return false, "Missing 'driverId' argument"
	end

	local driver = drivers[driverId]
	if not driver then
		return false, "Unknown driverId: " .. tostring(driverId)
	end

	if not driver.running then
		return false, "Driver " .. driverId .. " is not running"
	end

	local cmd = args.command
	if not cmd then
		return false, "Missing 'command' argument"
	end

	driver:queueCommand(cmd)

	return true, {
		ok = true,
		driverId = driverId,
		queueLength = #driver.commandQueue,
	}
end

function NpcDriver.stop(args, _ctx)
	local driverId = args.driverId
	if not driverId then
		return false, "Missing 'driverId' argument"
	end

	local driver = drivers[driverId]
	if not driver then
		return false, "Unknown driverId: " .. tostring(driverId)
	end

	driver:stop()
	drivers[driverId] = nil

	print("[MCP] NPC driver stopped: " .. driverId)
	return true, {
		ok = true,
		driverId = driverId,
	}
end

return NpcDriver
