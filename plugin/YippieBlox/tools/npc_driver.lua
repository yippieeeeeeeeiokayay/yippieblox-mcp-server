-- tools/npc_driver.lua
-- NPC automation during Play mode playtests.
-- The actual handlers run in the playtest bridge (server-side Script).
-- These stubs return errors if a request is routed here instead.

local NpcDriver = {}

local PLAYTEST_MSG = "This tool only works during a Play mode playtest (F5). Start one with studio-playtest_play first, then retry."

function NpcDriver.start(_args, _ctx)
	return false, PLAYTEST_MSG
end

function NpcDriver.command(_args, _ctx)
	return false, PLAYTEST_MSG
end

function NpcDriver.stop(_args, _ctx)
	return false, PLAYTEST_MSG
end

return NpcDriver
