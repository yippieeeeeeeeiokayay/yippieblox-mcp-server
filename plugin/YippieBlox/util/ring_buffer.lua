-- ring_buffer.lua
-- Bounded ring buffer for log entries, command trace, etc.

local RingBuffer = {}
RingBuffer.__index = RingBuffer

function RingBuffer.new(capacity)
	capacity = capacity or 500
	return setmetatable({
		_entries = {},
		_capacity = capacity,
	}, RingBuffer)
end

function RingBuffer:push(entry)
	table.insert(self._entries, entry)
	while #self._entries > self._capacity do
		table.remove(self._entries, 1)
	end
end

function RingBuffer:getAll()
	return self._entries
end

function RingBuffer:getRecent(count)
	count = count or 50
	local start = math.max(1, #self._entries - count + 1)
	local result = {}
	for i = start, #self._entries do
		table.insert(result, self._entries[i])
	end
	return result
end

function RingBuffer:getSince(seq)
	local result = {}
	for _, entry in ipairs(self._entries) do
		if entry.seq and entry.seq > seq then
			table.insert(result, entry)
		end
	end
	return result
end

function RingBuffer:clear()
	self._entries = {}
end

function RingBuffer:size()
	return #self._entries
end

return RingBuffer
