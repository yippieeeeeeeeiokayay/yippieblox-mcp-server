-- ui/widget.lua
-- Creates a DockWidgetPluginGui for the MCP bridge status and controls.
-- Call Widget.create(plugin) to get a widget controller table.

local Widget = {}

local COLORS = {
	bg = Color3.fromRGB(30, 30, 30),
	bgDark = Color3.fromRGB(20, 20, 20),
	textDefault = Color3.fromRGB(200, 200, 200),
	textDim = Color3.fromRGB(140, 140, 140),
	connected = Color3.fromRGB(100, 255, 100),
	disconnected = Color3.fromRGB(255, 100, 100),
	buttonBg = Color3.fromRGB(50, 50, 50),
	buttonHover = Color3.fromRGB(70, 70, 70),
	inputBg = Color3.fromRGB(40, 40, 40),
}

local function createLabel(parent, props)
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.TextColor3 = props.color or COLORS.textDefault
	label.TextXAlignment = props.align or Enum.TextXAlignment.Left
	label.Font = props.font or Enum.Font.SourceSans
	label.TextSize = props.textSize or 14
	label.Text = props.text or ""
	label.Size = props.size or UDim2.new(1, -16, 0, 22)
	label.Position = props.position or UDim2.new(0, 8, 0, 0)
	label.TextTruncate = Enum.TextTruncate.AtEnd
	label.Parent = parent
	return label
end

local function createTextInput(parent, props)
	local box = Instance.new("TextBox")
	box.BackgroundColor3 = COLORS.inputBg
	box.BorderSizePixel = 0
	box.TextColor3 = COLORS.textDefault
	box.PlaceholderColor3 = COLORS.textDim
	box.Font = Enum.Font.SourceSans
	box.TextSize = 14
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.ClearTextOnFocus = false
	box.Text = props.text or ""
	box.PlaceholderText = props.placeholder or ""
	box.Size = props.size or UDim2.new(1, -16, 0, 26)
	box.Position = props.position or UDim2.new(0, 8, 0, 0)
	box.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = box

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 6)
	padding.PaddingRight = UDim.new(0, 6)
	padding.Parent = box

	return box
end

local function createButton(parent, props)
	local btn = Instance.new("TextButton")
	btn.BackgroundColor3 = COLORS.buttonBg
	btn.BorderSizePixel = 0
	btn.TextColor3 = COLORS.textDefault
	btn.Font = Enum.Font.SourceSansBold
	btn.TextSize = 14
	btn.Text = props.text or "Button"
	btn.Size = props.size or UDim2.new(0, 100, 0, 28)
	btn.Position = props.position or UDim2.new(0, 8, 0, 0)
	btn.AutoButtonColor = true
	btn.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = btn

	return btn
end

--- Create the dock widget and return a controller table.
--- @param pluginObj Plugin
function Widget.create(pluginObj)
	local widgetInfo = DockWidgetPluginGuiInfo.new(
		Enum.InitialDockState.Bottom,
		true,   -- initially enabled
		false,  -- override previous state
		400,    -- default width
		300,    -- default height
		250,    -- min width
		180     -- min height
	)

	local dock = pluginObj:CreateDockWidgetPluginGui("YippieBloxMCP", widgetInfo)
	dock.Title = "YippieBlox MCP"

	-- Main frame
	local frame = Instance.new("Frame")
	frame.Size = UDim2.new(1, 0, 1, 0)
	frame.BackgroundColor3 = COLORS.bg
	frame.BorderSizePixel = 0
	frame.Parent = dock

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 4)
	layout.Parent = frame

	local mainPadding = Instance.new("UIPadding")
	mainPadding.PaddingTop = UDim.new(0, 8)
	mainPadding.PaddingLeft = UDim.new(0, 4)
	mainPadding.PaddingRight = UDim.new(0, 4)
	mainPadding.Parent = frame

	-- Status row
	local statusLabel = createLabel(frame, {
		text = "Status: Disconnected",
		font = Enum.Font.SourceSansBold,
		textSize = 16,
		color = COLORS.disconnected,
		size = UDim2.new(1, -8, 0, 24),
	})
	statusLabel.LayoutOrder = 1

	-- Server URL label + input
	createLabel(frame, {
		text = "Server URL:",
		size = UDim2.new(1, -8, 0, 18),
		textSize = 12,
		color = COLORS.textDim,
	}).LayoutOrder = 2

	local urlInput = createTextInput(frame, {
		text = pluginObj:GetSetting("YippieBlox_ServerURL") or "http://localhost:3333",
		placeholder = "http://localhost:3333",
		size = UDim2.new(1, -8, 0, 26),
	})
	urlInput.LayoutOrder = 3

	-- Token label + input
	createLabel(frame, {
		text = "Auth Token:",
		size = UDim2.new(1, -8, 0, 18),
		textSize = 12,
		color = COLORS.textDim,
	}).LayoutOrder = 4

	local tokenInput = createTextInput(frame, {
		text = pluginObj:GetSetting("YippieBlox_Token") or "",
		placeholder = "Paste token from server output",
		size = UDim2.new(1, -8, 0, 26),
	})
	tokenInput.LayoutOrder = 5

	-- Buttons row
	local buttonRow = Instance.new("Frame")
	buttonRow.Size = UDim2.new(1, -8, 0, 32)
	buttonRow.BackgroundTransparency = 1
	buttonRow.LayoutOrder = 6
	buttonRow.Parent = frame

	local btnLayout = Instance.new("UIListLayout")
	btnLayout.FillDirection = Enum.FillDirection.Horizontal
	btnLayout.Padding = UDim.new(0, 8)
	btnLayout.Parent = buttonRow

	local connectBtn = createButton(buttonRow, { text = "Connect" })
	local clearBtn = createButton(buttonRow, { text = "Clear Trace" })

	-- Command trace header
	createLabel(frame, {
		text = "Command Trace:",
		size = UDim2.new(1, -8, 0, 18),
		textSize = 12,
		color = COLORS.textDim,
	}).LayoutOrder = 7

	-- Scrolling trace area
	local scrollFrame = Instance.new("ScrollingFrame")
	scrollFrame.Size = UDim2.new(1, -8, 1, -230)
	scrollFrame.BackgroundColor3 = COLORS.bgDark
	scrollFrame.BorderSizePixel = 0
	scrollFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
	scrollFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scrollFrame.ScrollBarThickness = 6
	scrollFrame.LayoutOrder = 8
	scrollFrame.Parent = frame

	local scrollCorner = Instance.new("UICorner")
	scrollCorner.CornerRadius = UDim.new(0, 4)
	scrollCorner.Parent = scrollFrame

	local scrollLayout = Instance.new("UIListLayout")
	scrollLayout.SortOrder = Enum.SortOrder.LayoutOrder
	scrollLayout.Parent = scrollFrame

	local scrollPadding = Instance.new("UIPadding")
	scrollPadding.PaddingTop = UDim.new(0, 4)
	scrollPadding.PaddingLeft = UDim.new(0, 4)
	scrollPadding.PaddingRight = UDim.new(0, 4)
	scrollPadding.Parent = scrollFrame

	-- Track trace entries for bounded cleanup
	local traceLabels = {}
	local MAX_TRACE_LABELS = 500

	-- ─── Controller API ───────────────────────────────────────

	local controller = {}

	function controller:setStatus(text, isConnected)
		statusLabel.Text = "Status: " .. text
		statusLabel.TextColor3 = if isConnected then COLORS.connected else COLORS.disconnected
	end

	function controller:addTrace(toolName, success, elapsed, details)
		local status = if success then "OK" else "FAIL"
		local elapsedStr = string.format("%.1fs", elapsed or 0)
		local detailStr = ""
		if details and type(details) == "string" and #details > 0 then
			detailStr = " | " .. string.sub(details, 1, 60)
		end

		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(1, 0, 0, 18)
		label.BackgroundTransparency = 1
		label.TextColor3 = if success then COLORS.textDim else COLORS.disconnected
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Font = Enum.Font.SourceSans
		label.TextSize = 12
		label.TextTruncate = Enum.TextTruncate.AtEnd
		label.Text = string.format("%s %s (%s)%s", toolName, status, elapsedStr, detailStr)
		label.LayoutOrder = #traceLabels + 1
		label.Parent = scrollFrame

		table.insert(traceLabels, label)

		-- Bounded cleanup
		while #traceLabels > MAX_TRACE_LABELS do
			local old = table.remove(traceLabels, 1)
			old:Destroy()
		end

		-- Auto-scroll to bottom
		scrollFrame.CanvasPosition = Vector2.new(0, scrollFrame.AbsoluteCanvasSize.Y)
	end

	function controller:clearTrace()
		for _, label in ipairs(traceLabels) do
			label:Destroy()
		end
		traceLabels = {}
	end

	function controller:getServerUrl()
		return urlInput.Text
	end

	function controller:getToken()
		return tokenInput.Text
	end

	function controller:saveSettings()
		pluginObj:SetSetting("YippieBlox_ServerURL", urlInput.Text)
		pluginObj:SetSetting("YippieBlox_Token", tokenInput.Text)
	end

	function controller:onConnect(callback)
		connectBtn.MouseButton1Click:Connect(function()
			controller:saveSettings()
			callback(urlInput.Text, tokenInput.Text)
		end)
	end

	function controller:onClear(callback)
		clearBtn.MouseButton1Click:Connect(function()
			callback()
		end)
	end

	function controller:setConnectButtonText(text)
		connectBtn.Text = text
	end

	return controller
end

return Widget
