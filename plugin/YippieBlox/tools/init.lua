-- tools/init.lua
-- Tool dispatcher: routes tool calls to the appropriate handler module.

local RunScript = require(script.run_script)
local Checkpoint = require(script.checkpoint)
local Playtest = require(script.playtest)
local Logs = require(script.logs)
local VirtualUserTools = require(script.virtualuser)
local NpcDriver = require(script.npc_driver)
local Capture = require(script.capture)

local ToolRouter = {}

local handlers = {
	-- status is handled inline (no module needed — just returns connection state)
	["studio-status"] = function(_args, ctx)
		local RunService = game:GetService("RunService")
		return true, {
			connected = true,
			features = ctx.features,
			playtest = {
				active = RunService:IsRunning(),
			},
		}
	end,

	-- Script execution
	["studio-run_script"] = RunScript.execute,

	-- Checkpoint / undo
	["studio-checkpoint_begin"] = Checkpoint.beginRecording,
	["studio-checkpoint_end"] = Checkpoint.endRecording,
	["studio-checkpoint_undo"] = Checkpoint.undo,

	-- Playtest control
	["studio-playtest_play"] = Playtest.play,
	["studio-playtest_run"] = Playtest.run,
	["studio-playtest_stop"] = Playtest.stop,
	["studio-test_script"] = Playtest.testScript,

	-- Log capture
	["studio-logs_subscribe"] = Logs.subscribe,
	["studio-logs_unsubscribe"] = Logs.unsubscribe,
	["studio-logs_get"] = Logs.get,

	-- VirtualUser input simulation
	["studio-virtualuser_attach"] = VirtualUserTools.attach,
	["studio-virtualuser_key"] = VirtualUserTools.key,
	["studio-virtualuser_mouse_button"] = VirtualUserTools.mouseButton,
	["studio-virtualuser_move_mouse"] = VirtualUserTools.moveMouse,

	-- NPC driver
	["studio-npc_driver_start"] = NpcDriver.start,
	["studio-npc_driver_command"] = NpcDriver.command,
	["studio-npc_driver_stop"] = NpcDriver.stop,

	-- Capture
	["studio-capture_screenshot"] = Capture.screenshot,
	["studio-capture_video_start"] = Capture.videoStart,
	["studio-capture_video_stop"] = Capture.videoStop,
}

--- Dispatch a tool call to the appropriate handler.
--- @param toolName string
--- @param arguments table
--- @param ctx table -- { features, bridge }
--- @return boolean success
--- @return any resultOrError
function ToolRouter.dispatch(toolName, arguments, ctx)
	local handler = handlers[toolName]
	if not handler then
		return false, "Unknown tool: " .. tostring(toolName)
	end

	-- All handlers are pcall-wrapped for safety
	local ok, result1, result2 = pcall(handler, arguments or {}, ctx)
	if not ok then
		return false, "Tool handler error: " .. tostring(result1)
	end

	-- Handlers return (success: bool, data: any)
	return result1, result2
end

--- Get the list of supported tool names.
function ToolRouter.toolNames()
	local names = {}
	for name in pairs(handlers) do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

return ToolRouter
