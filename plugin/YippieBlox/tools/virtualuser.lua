-- tools/virtualuser.lua
-- Input simulation via VirtualInputManager / VirtualUser.
-- Requires LocalUserSecurity — feature-detected at runtime.

local RunService = game:GetService("RunService")

local VirtualUserTools = {}

-- Module state
local virtualInputManager = nil
local attached = false

-- Try to get the input simulation service
local function getVIM()
	if virtualInputManager then
		return virtualInputManager
	end

	-- Try VirtualInputManager first (newer API)
	local ok, vim = pcall(function()
		return game:GetService("VirtualInputManager")
	end)
	if ok and vim then
		virtualInputManager = vim
		return vim
	end

	-- Try VirtualUser (older API)
	local ok2, vu = pcall(function()
		return game:GetService("VirtualUser")
	end)
	if ok2 and vu then
		virtualInputManager = vu
		return vu
	end

	return nil
end

function VirtualUserTools.attach(args, _ctx)
	local vim = getVIM()
	if not vim then
		return false, "VirtualInputManager/VirtualUser not available. This API requires LocalUserSecurity and may not be accessible in all Studio plugin contexts."
	end

	-- CaptureController if available (VirtualUser API)
	if vim.CaptureController then
		local ok, err = pcall(function()
			vim:CaptureController()
		end)
		if not ok then
			print("[MCP] Warning: CaptureController() failed: " .. tostring(err))
		end
	end

	attached = true
	local target = args.target or "playtest"

	print("[MCP] VirtualUser attached (target: " .. target .. ")")
	return true, {
		ok = true,
		service = vim.ClassName or "VirtualInputManager",
		target = target,
	}
end

function VirtualUserTools.key(args, _ctx)
	if not attached then
		return false, "VirtualUser not attached. Call studio.virtualuser_attach first."
	end

	local vim = getVIM()
	if not vim then
		return false, "VirtualInputManager not available"
	end

	if not RunService:IsRunning() then
		return false, "VirtualUser input only works during a playtest session"
	end

	local keyCode = args.keyCode
	if not keyCode or type(keyCode) ~= "string" then
		return false, "Missing or invalid 'keyCode' argument"
	end

	local action = args.action or "type"

	-- Resolve key code string to Enum.KeyCode
	local enumKey = Enum.KeyCode[keyCode]
	if not enumKey then
		return false, "Unknown KeyCode: '" .. keyCode .. "'. Use Roblox KeyCode names like 'W', 'Space', 'Return', 'LeftShift', etc."
	end

	local ok, err

	-- Use VirtualInputManager:SendKeyEvent if available (newer API)
	if vim.SendKeyEvent then
		if action == "type" then
			ok, err = pcall(function()
				vim:SendKeyEvent(true, enumKey, false, game)
			end)
			if ok then
				task.wait(0.05)
				pcall(function()
					vim:SendKeyEvent(false, enumKey, false, game)
				end)
			end
		elseif action == "down" then
			ok, err = pcall(function()
				vim:SendKeyEvent(true, enumKey, false, game)
			end)
		elseif action == "up" then
			ok, err = pcall(function()
				vim:SendKeyEvent(false, enumKey, false, game)
			end)
		else
			return false, "Invalid action: '" .. action .. "'. Use 'type', 'down', or 'up'."
		end
	-- Fallback: VirtualUser TypeKey/SetKeyDown/SetKeyUp
	elseif vim.TypeKey then
		if action == "type" then
			ok, err = pcall(function()
				vim:TypeKey(enumKey)
			end)
		elseif action == "down" then
			ok, err = pcall(function()
				vim:SetKeyDown(enumKey)
			end)
		elseif action == "up" then
			ok, err = pcall(function()
				vim:SetKeyUp(enumKey)
			end)
		else
			return false, "Invalid action: '" .. action .. "'. Use 'type', 'down', or 'up'."
		end
	else
		return false, "No supported key input method found on " .. tostring(vim.ClassName)
	end

	if not ok then
		return false, "Key input failed: " .. tostring(err)
	end

	return true, { ok = true, keyCode = keyCode, action = action }
end

function VirtualUserTools.mouseButton(args, _ctx)
	if not attached then
		return false, "VirtualUser not attached. Call studio.virtualuser_attach first."
	end

	local vim = getVIM()
	if not vim then
		return false, "VirtualInputManager not available"
	end

	if not RunService:IsRunning() then
		return false, "VirtualUser input only works during a playtest session"
	end

	local button = args.button or 1
	local action = args.action or "click"
	local pos = args.position or { x = 0, y = 0 }
	local x = pos.x or 0
	local y = pos.y or 0

	local ok, err

	if vim.SendMouseButtonEvent then
		-- VirtualInputManager API: button is 0-indexed (0=left, 1=right)
		local btnIndex = button - 1

		if action == "click" then
			ok, err = pcall(function()
				vim:SendMouseButtonEvent(x, y, btnIndex, true, game, 0)
			end)
			if ok then
				task.wait(0.05)
				pcall(function()
					vim:SendMouseButtonEvent(x, y, btnIndex, false, game, 0)
				end)
			end
		elseif action == "down" then
			ok, err = pcall(function()
				vim:SendMouseButtonEvent(x, y, btnIndex, true, game, 0)
			end)
		elseif action == "up" then
			ok, err = pcall(function()
				vim:SendMouseButtonEvent(x, y, btnIndex, false, game, 0)
			end)
		else
			return false, "Invalid action: '" .. action .. "'. Use 'click', 'down', or 'up'."
		end
	-- Fallback: VirtualUser Button1Down/Up/Click
	elseif button == 1 and vim.ClickButton1 then
		local position = Vector2.new(x, y)
		if action == "click" then
			ok, err = pcall(function() vim:ClickButton1(position) end)
		elseif action == "down" then
			ok, err = pcall(function() vim:Button1Down(position) end)
		elseif action == "up" then
			ok, err = pcall(function() vim:Button1Up(position) end)
		end
	elseif button == 2 and vim.ClickButton2 then
		local position = Vector2.new(x, y)
		if action == "click" then
			ok, err = pcall(function() vim:ClickButton2(position) end)
		elseif action == "down" then
			ok, err = pcall(function() vim:Button2Down(position) end)
		elseif action == "up" then
			ok, err = pcall(function() vim:Button2Up(position) end)
		end
	else
		return false, "Mouse button simulation not supported"
	end

	if not ok then
		return false, "Mouse button input failed: " .. tostring(err)
	end

	return true, { ok = true, button = button, action = action, position = { x = x, y = y } }
end

function VirtualUserTools.moveMouse(args, _ctx)
	if not attached then
		return false, "VirtualUser not attached. Call studio.virtualuser_attach first."
	end

	local vim = getVIM()
	if not vim then
		return false, "VirtualInputManager not available"
	end

	local pos = args.position or {}
	local x = pos.x or 0
	local y = pos.y or 0

	local ok, err

	if vim.SendMouseMoveEvent then
		ok, err = pcall(function()
			vim:SendMouseMoveEvent(x, y, game)
		end)
	elseif vim.MoveMouse then
		ok, err = pcall(function()
			vim:MoveMouse(Vector2.new(x, y))
		end)
	else
		return false, "Mouse move not supported on " .. tostring(vim.ClassName)
	end

	if not ok then
		return false, "Mouse move failed: " .. tostring(err)
	end

	return true, { ok = true, position = { x = x, y = y } }
end

return VirtualUserTools
