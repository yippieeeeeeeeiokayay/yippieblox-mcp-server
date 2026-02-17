-- tools/virtualuser.lua
-- Character control during Play mode playtests.
-- The actual handlers run in the playtest bridge (server-side Script).
-- These stubs return errors if a request is routed here instead.

local VirtualUserTools = {}

local PLAYTEST_MSG = "This tool only works during a Play mode playtest (F5). Start one with studio-playtest_play first, then retry."

function VirtualUserTools.attach(_args, _ctx)
	return false, "studio-virtualuser_attach has been removed. Use studio-virtualuser_key, studio-virtualuser_mouse_button, and studio-virtualuser_move_mouse directly during a Play mode playtest."
end

function VirtualUserTools.key(_args, _ctx)
	return false, PLAYTEST_MSG
end

function VirtualUserTools.mouseButton(_args, _ctx)
	return false, PLAYTEST_MSG
end

function VirtualUserTools.moveMouse(_args, _ctx)
	return false, PLAYTEST_MSG
end

return VirtualUserTools
