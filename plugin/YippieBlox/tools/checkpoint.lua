-- tools/checkpoint.lua
-- Undo/redo checkpoint management via ChangeHistoryService.

local ChangeHistoryService = game:GetService("ChangeHistoryService")

local Checkpoint = {}

-- Map of checkpointId -> recording handle
local recordings = {}
local nextId = 1

function Checkpoint.beginRecording(args, _ctx)
	local name = args.name or "MCP Checkpoint"

	local recording = ChangeHistoryService:TryBeginRecording(name)
	if not recording then
		return false, "Failed to begin recording. A recording may already be in progress, or Studio is in playtest mode."
	end

	local checkpointId = "cp_" .. tostring(nextId)
	nextId = nextId + 1
	recordings[checkpointId] = recording

	print("[MCP] Checkpoint started: " .. name .. " (id: " .. checkpointId .. ")")
	return true, {
		checkpointId = checkpointId,
		name = name,
	}
end

function Checkpoint.endRecording(args, _ctx)
	local checkpointId = args.checkpointId
	if not checkpointId then
		return false, "Missing 'checkpointId' argument"
	end

	local recording = recordings[checkpointId]
	if not recording then
		return false, "Unknown checkpointId: " .. tostring(checkpointId)
	end

	local commitMessage = args.commitMessage or nil
	ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
	recordings[checkpointId] = nil

	print("[MCP] Checkpoint committed: " .. checkpointId)
	return true, {
		ok = true,
		checkpointId = checkpointId,
		commitMessage = commitMessage,
	}
end

function Checkpoint.undo(args, _ctx)
	local checkpointId = args.checkpointId

	-- If a specific checkpoint has an active recording, cancel it first
	if checkpointId and recordings[checkpointId] then
		ChangeHistoryService:FinishRecording(recordings[checkpointId], Enum.FinishRecordingOperation.Cancel)
		recordings[checkpointId] = nil
		print("[MCP] Checkpoint cancelled: " .. checkpointId)
		return true, {
			ok = true,
			undoneCheckpointId = checkpointId,
			action = "cancelled_recording",
		}
	end

	-- Otherwise, perform a standard undo
	ChangeHistoryService:Undo()
	print("[MCP] Undo performed")
	return true, {
		ok = true,
		action = "undo",
	}
end

return Checkpoint
