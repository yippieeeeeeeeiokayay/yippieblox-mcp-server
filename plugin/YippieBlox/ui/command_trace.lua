-- ui/command_trace.lua
-- Ring buffer that stores tool call trace entries for display in the widget.

local RingBuffer = require(script.Parent.Parent.util.ring_buffer)

local CommandTrace = {}
CommandTrace.__index = CommandTrace

function CommandTrace.new(capacity)
	return setmetatable({
		_buffer = RingBuffer.new(capacity or 500),
	}, CommandTrace)
end

function CommandTrace:add(toolName, success, elapsed, details)
	self._buffer:push({
		tool_name = toolName,
		success = success,
		elapsed = elapsed,
		details = details,
		timestamp = os.clock(),
	})
end

function CommandTrace:getRecent(count)
	return self._buffer:getRecent(count)
end

function CommandTrace:getAll()
	return self._buffer:getAll()
end

function CommandTrace:clear()
	self._buffer:clear()
end

function CommandTrace:size()
	return self._buffer:size()
end

--- Format a trace entry as a single line for display.
function CommandTrace.formatEntry(entry)
	local status = if entry.success then "OK" else "FAIL"
	local elapsed = string.format("%.1fs", entry.elapsed or 0)
	local ts = string.format("%.1f", entry.timestamp or 0)
	local details = ""
	if entry.details and type(entry.details) == "string" and #entry.details > 0 then
		details = " | " .. string.sub(entry.details, 1, 80)
	end
	return string.format("[%s] %s %s (%s)%s", ts, entry.tool_name or "?", status, elapsed, details)
end

return CommandTrace
