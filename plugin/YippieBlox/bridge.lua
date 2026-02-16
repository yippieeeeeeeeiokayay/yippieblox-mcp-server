-- bridge.lua
-- HTTP bridge client for communicating with the Rust MCP server.
-- Uses HttpService:RequestAsync for all HTTP calls to localhost.

local HttpService = game:GetService("HttpService")

local Bridge = {}
Bridge.__index = Bridge

function Bridge.new(baseUrl, token)
	return setmetatable({
		baseUrl = baseUrl,
		token = token,
		clientId = nil,
		connected = false,
		lastError = nil,
		lastPollTime = 0,
	}, Bridge)
end

function Bridge:_request(method, path, body)
	local url = self.baseUrl .. path
	if self.clientId then
		local sep = if string.find(path, "?", 1, true) then "&" else "?"
		url = url .. sep .. "clientId=" .. self.clientId
	end

	local headers = {
		["Content-Type"] = "application/json",
	}
	if self.token and self.token ~= "" then
		headers["Authorization"] = "Bearer " .. self.token
	end

	local requestOptions = {
		Url = url,
		Method = method,
		Headers = headers,
	}
	if body then
		requestOptions.Body = HttpService:JSONEncode(body)
	end

	local ok, response = pcall(function()
		return HttpService:RequestAsync(requestOptions)
	end)

	if not ok then
		self.lastError = tostring(response)
		return false, nil, tostring(response)
	end

	if response.StatusCode >= 200 and response.StatusCode < 300 then
		local decodeOk, decoded = pcall(function()
			return HttpService:JSONDecode(response.Body)
		end)
		if decodeOk then
			self.lastError = nil
			return true, decoded, nil
		else
			return true, response.Body, nil
		end
	else
		local errMsg = "HTTP " .. tostring(response.StatusCode) .. ": " .. tostring(response.Body)
		self.lastError = errMsg
		return false, nil, errMsg
	end
end

function Bridge:register()
	local ok, data, err = self:_request("POST", "/register", {
		plugin_version = "0.1.0",
	})
	if ok and data then
		self.clientId = data.client_id
		self.connected = true
		return true, data.client_id
	end
	self.connected = false
	return false, err
end

function Bridge:pull()
	self.lastPollTime = os.clock()
	local ok, data, _err = self:_request("GET", "/pull")
	if ok and data and type(data) == "table" then
		return data
	end
	return {}
end

function Bridge:pushResponse(requestId, success, result, errorMsg)
	self:_request("POST", "/push", {
		responses = {
			{
				request_id = requestId,
				success = success,
				result = result,
				error = errorMsg,
			},
		},
		events = {},
	})
end

function Bridge:pushEvent(eventType, data)
	self:_request("POST", "/push", {
		responses = {},
		events = {
			{
				event_type = eventType,
				data = data,
			},
		},
	})
end

function Bridge:isConnected()
	return self.connected and self.clientId ~= nil
end

return Bridge
