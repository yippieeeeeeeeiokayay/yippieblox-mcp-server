-- tools/logs.lua
-- Log capture via LogService.MessageOut + GetLogHistory.

local LogService = game:GetService("LogService")

local RingBuffer = require(script.Parent.Parent.util.ring_buffer)

local Logs = {}

-- Module-level state
local subscribed = false
local logConnection = nil
local logBuffer = RingBuffer.new(500)
local seq = 0
local bridgeRef = nil  -- set when subscribe is called with ctx.bridge

-- Map Roblox MessageType enum to string level names
local MESSAGE_TYPE_MAP = {
	[Enum.MessageType.MessageOutput] = "output",
	[Enum.MessageType.MessageInfo] = "info",
	[Enum.MessageType.MessageWarning] = "warning",
	[Enum.MessageType.MessageError] = "error",
}

local function addLog(message, messageType, timestamp)
	-- Filter our own messages to avoid infinite loops
	if string.sub(message, 1, 5) == "[MCP]" then
		return
	end

	seq = seq + 1
	local level = MESSAGE_TYPE_MAP[messageType] or "output"

	local entry = {
		seq = seq,
		ts = timestamp or os.clock(),
		level = level,
		message = message,
	}

	logBuffer:push(entry)

	-- Stream to bridge if connected
	if bridgeRef then
		task.spawn(function()
			bridgeRef:pushEvent("studio.log", entry)
		end)
	end
end

function Logs.subscribe(args, ctx)
	if subscribed then
		return true, {
			already_subscribed = true,
			buffered_count = logBuffer:size(),
		}
	end

	-- Store bridge reference for streaming
	if ctx and ctx.bridge then
		bridgeRef = ctx.bridge
	end

	-- Backfill from LogService history
	local includeHistory = args.includeHistory
	if includeHistory == nil then
		includeHistory = true
	end

	local history = {}
	if includeHistory then
		local ok, logHistory = pcall(function()
			return LogService:GetLogHistory()
		end)
		if ok and logHistory then
			local maxHistory = args.maxHistory or 200
			local startIdx = math.max(1, #logHistory - maxHistory + 1)
			for i = startIdx, #logHistory do
				local entry = logHistory[i]
				addLog(entry.message, entry.messageType, entry.timestamp)
			end
			history = logBuffer:getAll()
		end
	end

	-- Subscribe to new messages
	logConnection = LogService.MessageOut:Connect(function(message, messageType)
		addLog(message, messageType, os.clock())
	end)

	subscribed = true
	print("[MCP] Log subscription started (history: " .. tostring(#history) .. " entries)")

	return true, {
		ok = true,
		history = history,
	}
end

function Logs.unsubscribe(_args, _ctx)
	if logConnection then
		logConnection:Disconnect()
		logConnection = nil
	end
	subscribed = false
	bridgeRef = nil

	print("[MCP] Log subscription stopped")
	return true, { ok = true }
end

function Logs.get(args, _ctx)
	local sinceSeq = args.sinceSeq or 0
	local limit = args.limit or 200

	local entries
	if sinceSeq > 0 then
		entries = logBuffer:getSince(sinceSeq)
	else
		entries = logBuffer:getRecent(limit)
	end

	-- Apply level filter if specified
	local levels = args.levels
	if levels and type(levels) == "table" and #levels > 0 then
		local levelSet = {}
		for _, l in ipairs(levels) do
			levelSet[l] = true
		end
		local filtered = {}
		for _, entry in ipairs(entries) do
			if levelSet[entry.level] then
				table.insert(filtered, entry)
			end
		end
		entries = filtered
	end

	-- Apply limit
	if #entries > limit then
		local trimmed = {}
		local start = #entries - limit + 1
		for i = start, #entries do
			table.insert(trimmed, entries[i])
		end
		entries = trimmed
	end

	local nextSeq = seq

	return true, {
		entries = entries,
		nextSeq = nextSeq,
		subscribed = subscribed,
	}
end

return Logs
