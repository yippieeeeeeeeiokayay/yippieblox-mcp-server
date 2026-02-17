-- playtest_bridge_source.lua
-- Returns the Luau source code for the playtest bridge Script
-- that gets injected into ServerScriptService during playtest.
-- This runs in the SERVER context where HttpService works.

return [==[
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local LogService = game:GetService("LogService")
local Players = game:GetService("Players")

print("[MCP-Playtest] Bridge script loaded, IsRunning: " .. tostring(RunService:IsRunning()))

-- Only run during playtest (server context)
if not RunService:IsRunning() then
	print("[MCP-Playtest] Not in playtest, exiting")
	return
end

-- Read config from StringValue children
local urlValue = script:FindFirstChild("_YippieBlox_URL")
local tokenValue = script:FindFirstChild("_YippieBlox_Token")

print("[MCP-Playtest] URL value: " .. tostring(urlValue) .. ", Token value: " .. tostring(tokenValue))

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

-- ─── Virtual Input State ──────────────────────────────────────

local MOVEMENT_KEYS = { W = true, A = true, S = true, D = true }
local virtualKeys = {}
local heartbeatConn = nil
local networkOwnerClaimed = false

local function getPlayerCharacterHumanoid()
	local players = Players:GetPlayers()
	if #players == 0 then return nil, nil, nil end
	local player = players[1]
	local character = player.Character
	if not character then return player, nil, nil end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	return player, character, humanoid
end

-- Claim server network ownership so client ControlScript doesn't override
-- our Humanoid:Move() calls. Without this, the client calls Move(Vector3.zero)
-- every frame, causing stuttering.
local function claimNetworkOwnership()
	if networkOwnerClaimed then return end
	local _, character, _ = getPlayerCharacterHumanoid()
	if not character then return end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root then
		pcall(function()
			root:SetNetworkOwner(nil) -- nil = server owns
		end)
		networkOwnerClaimed = true
		print("[MCP-Playtest] Claimed server network ownership of character")
	end
end

local function releaseNetworkOwnership()
	if not networkOwnerClaimed then return end
	local player, character, _ = getPlayerCharacterHumanoid()
	if not character or not player then
		networkOwnerClaimed = false
		return
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root then
		pcall(function()
			root:SetNetworkOwner(player) -- give back to client
		end)
		print("[MCP-Playtest] Released network ownership back to client")
	end
	networkOwnerClaimed = false
end

local function updateMovement()
	local _, _, humanoid = getPlayerCharacterHumanoid()
	if not humanoid or humanoid:GetState() == Enum.HumanoidStateType.Dead then return end

	local moveDir = Vector3.zero
	if virtualKeys["W"] then moveDir = moveDir + Vector3.new(0, 0, -1) end
	if virtualKeys["S"] then moveDir = moveDir + Vector3.new(0, 0, 1) end
	if virtualKeys["A"] then moveDir = moveDir + Vector3.new(-1, 0, 0) end
	if virtualKeys["D"] then moveDir = moveDir + Vector3.new(1, 0, 0) end

	if moveDir.Magnitude > 0 then
		moveDir = moveDir.Unit
	end

	humanoid:Move(moveDir, false)
end

local function ensureHeartbeat()
	if heartbeatConn then return end
	heartbeatConn = RunService.Heartbeat:Connect(updateMovement)
end

local function cleanupVirtualInput()
	if heartbeatConn then
		heartbeatConn:Disconnect()
		heartbeatConn = nil
	end
	virtualKeys = {}
	releaseNetworkOwnership()
end

-- ─── NPC Driver State ─────────────────────────────────────────

local npcDrivers = {}
local nextDriverId = 1

local function resolveInstancePath(path)
	local parts = string.split(path, ".")
	local current = game
	for _, part in ipairs(parts) do
		current = current:FindFirstChild(part)
		if not current then return nil end
	end
	return current
end

local function cleanupNpcDrivers()
	npcDrivers = {}
	nextDriverId = 1
end

local function handleTool(toolName, args)
	if toolName == "studio-run_script" then
		return false, "studio-run_script is not available during playtest (loadstring is restricted). Use studio-test_script instead, which bakes code directly into a Script."

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
		cleanupVirtualInput()
		cleanupNpcDrivers()
		local ok, err = pcall(function()
			game:GetService("StudioTestService"):EndTest({})
		end)
		if not ok then
			return false, "EndTest() failed: " .. tostring(err)
		end
		return true, { ok = true }

	elseif toolName == "studio-virtualuser_key" then
		local player, character, humanoid = getPlayerCharacterHumanoid()
		if not humanoid then
			return false, "No player character found. Requires Play mode playtest (F5) with a spawned character."
		end

		local keyCode = args.keyCode
		local action = args.action or "down"
		if not keyCode then
			return false, "Missing required argument: keyCode"
		end

		if keyCode == "Space" then
			humanoid.Jump = true
			return true, { key = "Space", action = "jump", state = humanoid:GetState().Name }

		elseif keyCode == "LeftShift" or keyCode == "RightShift" then
			if action == "up" then
				humanoid.WalkSpeed = 16
			else
				humanoid.WalkSpeed = 32
			end
			return true, { key = keyCode, action = action, walkSpeed = humanoid.WalkSpeed }

		elseif MOVEMENT_KEYS[keyCode] then
			ensureHeartbeat()
			claimNetworkOwnership()
			if action == "up" then
				virtualKeys[keyCode] = nil
				-- Release network ownership when all keys are released
				local anyHeld = false
				for _, v in pairs(virtualKeys) do
					if v then anyHeld = true break end
				end
				if not anyHeld then
					releaseNetworkOwnership()
				end
			else
				virtualKeys[keyCode] = true
			end
			local held = {}
			for k, v in pairs(virtualKeys) do
				if v then table.insert(held, k) end
			end
			return true, { key = keyCode, action = action, heldKeys = held }

		else
			return false, "Unsupported keyCode: " .. tostring(keyCode) .. ". Supported: W, A, S, D, Space, LeftShift, RightShift"
		end

	elseif toolName == "studio-virtualuser_mouse_button" then
		local player, character, humanoid = getPlayerCharacterHumanoid()
		if not humanoid then
			return false, "No player character found. Requires Play mode playtest (F5) with a spawned character."
		end

		local button = args.button or 1
		local worldPos = args.worldPosition
		local targetPath = args.target
		if not worldPos and not targetPath then
			return false, "Provide 'worldPosition' ({x,y,z}) or 'target' (instance path like 'Workspace.MyPart')"
		end

		local head = character:FindFirstChild("Head")
		if not head then
			return false, "Character has no Head part"
		end

		-- Resolve target instance by path
		local targetInstance = nil
		if targetPath then
			local pathParts = string.split(targetPath, ".")
			local current = game
			for _, part in ipairs(pathParts) do
				current = current:FindFirstChild(part)
				if not current then
					return false, "Instance not found at path: " .. targetPath
				end
			end
			targetInstance = current
			if not worldPos and targetInstance:IsA("BasePart") then
				worldPos = { x = targetInstance.Position.X, y = targetInstance.Position.Y, z = targetInstance.Position.Z }
			end
		end

		local response = { button = button, action = args.action or "click" }

		if worldPos then
			local origin = head.Position
			local target = Vector3.new(worldPos.x, worldPos.y, worldPos.z)
			local direction = (target - origin)
			if direction.Magnitude > 1000 then
				direction = direction.Unit * 1000
			end

			local params = RaycastParams.new()
			params.FilterDescendantsInstances = {character}
			params.FilterType = Enum.RaycastFilterType.Exclude

			local result = workspace:Raycast(origin, direction, params)
			if result then
				local hit = result.Instance
				response.hit = {
					name = hit.Name,
					fullName = hit:GetFullName(),
					className = hit.ClassName,
					position = { x = result.Position.X, y = result.Position.Y, z = result.Position.Z },
					distance = result.Distance,
					material = result.Material.Name,
				}

				local clickDetector = hit:FindFirstChildOfClass("ClickDetector")
				if not clickDetector and hit.Parent then
					clickDetector = hit.Parent:FindFirstChildOfClass("ClickDetector")
				end
				if clickDetector then
					response.hit.hasClickDetector = true
					response.hit.clickNote = "ClickDetector found but cannot be triggered from server context."
				end

				local prompt = hit:FindFirstChildOfClass("ProximityPrompt")
				if not prompt and hit.Parent then
					prompt = hit.Parent:FindFirstChildOfClass("ProximityPrompt")
				end
				if prompt then
					response.hit.hasProximityPrompt = true
					response.hit.promptText = prompt.ActionText
				end
			else
				response.miss = true
				response.note = "Raycast did not hit anything"
			end
		elseif targetInstance then
			response.targetFound = true
			response.targetFullName = targetInstance:GetFullName()
			response.targetClassName = targetInstance.ClassName
		end

		return true, response

	elseif toolName == "studio-virtualuser_move_mouse" then
		local player, character, humanoid = getPlayerCharacterHumanoid()
		if not humanoid then
			return false, "No player character found. Requires Play mode playtest (F5) with a spawned character."
		end

		local lookAt = args.lookAt
		if not lookAt then
			return false, "Missing required argument: lookAt ({x, y, z} world position to face toward)"
		end

		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then
			return false, "Character has no HumanoidRootPart"
		end

		local targetPos = Vector3.new(lookAt.x, rootPart.Position.Y, lookAt.z)
		rootPart.CFrame = CFrame.lookAt(rootPart.Position, targetPos)

		return true, {
			lookVector = {
				x = rootPart.CFrame.LookVector.X,
				y = rootPart.CFrame.LookVector.Y,
				z = rootPart.CFrame.LookVector.Z,
			},
			position = {
				x = rootPart.Position.X,
				y = rootPart.Position.Y,
				z = rootPart.Position.Z,
			},
		}

	elseif toolName == "studio-npc_driver_start" then
		local targetPath = args.target
		if not targetPath then
			return false, "Missing required argument: target (instance path like 'Workspace.NPCModel')"
		end

		local target = resolveInstancePath(targetPath)
		if not target then
			return false, "Instance not found at path: " .. targetPath
		end

		local humanoid = target:FindFirstChildOfClass("Humanoid")
		if not humanoid then
			return false, "No Humanoid found in: " .. targetPath
		end

		local driverId = "drv_" .. tostring(nextDriverId)
		nextDriverId = nextDriverId + 1

		npcDrivers[driverId] = {
			target = target,
			humanoid = humanoid,
			targetPath = targetPath,
		}

		print("[MCP-Playtest] NPC driver started: " .. driverId .. " -> " .. target:GetFullName())
		return true, {
			driverId = driverId,
			target = target:GetFullName(),
			className = target.ClassName,
			walkSpeed = humanoid.WalkSpeed,
			health = humanoid.Health,
			maxHealth = humanoid.MaxHealth,
		}

	elseif toolName == "studio-npc_driver_command" then
		local driverId = args.driverId
		if not driverId then
			return false, "Missing required argument: driverId"
		end

		local driver = npcDrivers[driverId]
		if not driver then
			local ids = {}
			for id in pairs(npcDrivers) do table.insert(ids, id) end
			return false, "Unknown driverId: " .. tostring(driverId) .. ". Active: " .. (if #ids > 0 then table.concat(ids, ", ") else "none")
		end

		local humanoid = driver.humanoid
		if not humanoid or not humanoid.Parent then
			npcDrivers[driverId] = nil
			return false, "Character no longer exists (destroyed or removed). Driver removed."
		end

		local cmd = args.command
		if not cmd or not cmd.type then
			return false, "Missing command or command.type. Supported: move_to, jump, wait, set_walkspeed, look_at"
		end

		local cmdType = cmd.type

		if cmdType == "move_to" then
			local pos = cmd.position
			if not pos then
				return false, "move_to requires 'position' ({x, y, z})"
			end
			local targetPos = Vector3.new(pos.x, pos.y, pos.z)
			humanoid:MoveTo(targetPos)

			local moveFinished = false
			local reached = false
			local conn = humanoid.MoveToFinished:Connect(function(r)
				reached = r
				moveFinished = true
			end)
			local timeout = cmd.timeout or 15
			local elapsed = 0
			while not moveFinished and elapsed < timeout do
				task.wait(0.1)
				elapsed = elapsed + 0.1
			end
			conn:Disconnect()

			local rootPart = driver.target:FindFirstChild("HumanoidRootPart")
			local finalPos = rootPart and rootPart.Position or Vector3.zero
			return true, {
				type = "move_to",
				reached = reached,
				timedOut = not moveFinished,
				elapsed = math.floor(elapsed * 10) / 10,
				position = { x = finalPos.X, y = finalPos.Y, z = finalPos.Z },
			}

		elseif cmdType == "jump" then
			humanoid.Jump = true
			return true, { type = "jump" }

		elseif cmdType == "wait" then
			local seconds = (cmd.ms or 1000) / 1000
			task.wait(seconds)
			return true, { type = "wait", waited = seconds }

		elseif cmdType == "set_walkspeed" then
			local value = cmd.value
			if not value then
				return false, "set_walkspeed requires 'value' (number)"
			end
			humanoid.WalkSpeed = value
			return true, { type = "set_walkspeed", walkSpeed = humanoid.WalkSpeed }

		elseif cmdType == "look_at" then
			local pos = cmd.position
			if not pos then
				return false, "look_at requires 'position' ({x, y, z})"
			end
			local rootPart = driver.target:FindFirstChild("HumanoidRootPart")
			if not rootPart then
				return false, "Character has no HumanoidRootPart"
			end
			local targetPos = Vector3.new(pos.x, rootPart.Position.Y, pos.z)
			rootPart.CFrame = CFrame.lookAt(rootPart.Position, targetPos)
			return true, {
				type = "look_at",
				lookVector = {
					x = rootPart.CFrame.LookVector.X,
					y = rootPart.CFrame.LookVector.Y,
					z = rootPart.CFrame.LookVector.Z,
				},
			}

		else
			return false, "Unknown command type: " .. tostring(cmdType) .. ". Supported: move_to, jump, wait, set_walkspeed, look_at"
		end

	elseif toolName == "studio-npc_driver_stop" then
		local driverId = args.driverId
		if not driverId then
			return false, "Missing required argument: driverId"
		end

		local driver = npcDrivers[driverId]
		if not driver then
			return false, "Unknown driverId: " .. tostring(driverId)
		end

		npcDrivers[driverId] = nil
		print("[MCP-Playtest] NPC driver stopped: " .. driverId)
		return true, { driverId = driverId, stopped = true }

	else
		return false, "Tool '" .. tostring(toolName) .. "' is not available during playtest. Available: studio-status, studio-logs_*, studio-playtest_stop, studio-virtualuser_*, studio-npc_driver_*"
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

cleanupVirtualInput()
cleanupNpcDrivers()
print("[MCP-Playtest] Playtest ended, bridge shutting down")
]==]
