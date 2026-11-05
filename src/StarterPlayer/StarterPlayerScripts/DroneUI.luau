--!nonstrict
--[[
	DroneUI -- HUD игры: здоровье, миниган/перегрев, патроны выжившего,
	скорость и высота, прицел, хитмаркер, лента убийств, баннеры, вспышки
	урона, выбор дрона, подсказки строительства и сенсорное управление.

	Собирается целиком кодом -- ни одной картинки.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local DroneUI = {}
DroneUI.__index = DroneUI

local ACCENT = Color3.fromRGB(255, 138, 60)
local CYAN = Color3.fromRGB(120, 225, 255)
local RED = Color3.fromRGB(255, 92, 86)
local GREEN = Color3.fromRGB(126, 240, 160)
local AMBER = Color3.fromRGB(255, 200, 90)
local PANEL = Color3.fromRGB(12, 12, 18)
local TEXT = Color3.fromRGB(240, 240, 246)
local MUTED = Color3.fromRGB(150, 152, 168)

-- --------------------------------------------------------------------------- --
local function corner(parent, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 8)
	c.Parent = parent
	return c
end

local function stroke(parent, color, thickness, transparency)
	local s = Instance.new("UIStroke")
	s.Color = color or ACCENT
	s.Thickness = thickness or 2
	s.Transparency = transparency or 0.2
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent
	return s
end

local function label(parent, text, size, position, color, font, scaled)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = size
	l.Position = position or UDim2.fromScale(0, 0)
	l.Text = text
	l.TextColor3 = color or TEXT
	l.Font = font or Enum.Font.GothamBold
	l.TextScaled = scaled ~= false
	l.TextStrokeTransparency = 0.65
	l.Parent = parent
	return l
end

local function bar(parent, size, position, color)
	local holder = Instance.new("Frame")
	holder.Size = size
	holder.Position = position
	holder.BackgroundColor3 = Color3.fromRGB(26, 28, 36)
	holder.BackgroundTransparency = 0.2
	holder.BorderSizePixel = 0
	holder.Parent = parent
	corner(holder, 6)

	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = color
	fill.BorderSizePixel = 0
	fill.Parent = holder
	corner(fill, 6)

	local grad = Instance.new("UIGradient")
	grad.Rotation = 0
	grad.Color = ColorSequence.new(color, Color3.fromRGB(
		math.floor(color.R * 255 * 0.55),
		math.floor(color.G * 255 * 0.55),
		math.floor(color.B * 255 * 0.55)))
	grad.Parent = fill

	return fill, holder
end

-- --------------------------------------------------------------------------- --
function DroneUI.new(callbacks)
	local self = setmetatable({}, DroneUI)
	self.callbacks = callbacks or {}
	self.drone = nil
	self.role = "drone"
	self.virtual = { x = 0, y = 0, yaw = 0, up = 0, fire = false }
	self.heat = 0
	self.hitmarkerUntil = 0
	self.bannerToken = 0
	self.feedLines = {}

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "DroneHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 30
	gui.Enabled = true
	gui.Parent = playerGui
	self.gui = gui

	-- ------------------------------------------------------------- прицел
	local cross = Instance.new("Frame")
	cross.Name = "Crosshair"
	cross.AnchorPoint = Vector2.new(0.5, 0.5)
	cross.Position = UDim2.fromScale(0.5, 0.5)
	cross.Size = UDim2.fromOffset(120, 120)
	cross.BackgroundTransparency = 1
	cross.Parent = gui
	self.cross = cross

	local dot = Instance.new("Frame")
	dot.Size = UDim2.fromOffset(4, 4)
	dot.Position = UDim2.fromScale(0.5, 0.5)
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.BackgroundColor3 = CYAN
	dot.BorderSizePixel = 0
	dot.Parent = cross
	corner(dot, 2)

	self.crossTicks = {}
	for i = 1, 4 do
		local tick = Instance.new("Frame")
		tick.BackgroundColor3 = TEXT
		tick.BorderSizePixel = 0
		tick.AnchorPoint = Vector2.new(0.5, 0.5)
		tick.BackgroundTransparency = 0.15
		if i == 1 then
			tick.Size = UDim2.fromOffset(2, 14)
			tick.Position = UDim2.new(0.5, 0, 0.5, -20)
		elseif i == 2 then
			tick.Size = UDim2.fromOffset(2, 14)
			tick.Position = UDim2.new(0.5, 0, 0.5, 20)
		elseif i == 3 then
			tick.Size = UDim2.fromOffset(14, 2)
			tick.Position = UDim2.new(0.5, -20, 0.5, 0)
		else
			tick.Size = UDim2.fromOffset(14, 2)
			tick.Position = UDim2.new(0.5, 20, 0.5, 0)
		end
		tick.Parent = cross
		table.insert(self.crossTicks, tick)
	end

	-- хитмаркер
	local hit = Instance.new("Frame")
	hit.AnchorPoint = Vector2.new(0.5, 0.5)
	hit.Position = UDim2.fromScale(0.5, 0.5)
	hit.Size = UDim2.fromOffset(46, 46)
	hit.BackgroundTransparency = 1
	hit.Parent = gui
	self.hitFrame = hit
	self.hitTicks = {}
	for i = 1, 4 do
		local t = Instance.new("Frame")
		t.BackgroundColor3 = Color3.fromRGB(255, 245, 220)
		t.BorderSizePixel = 0
		t.AnchorPoint = Vector2.new(0.5, 0.5)
		t.Size = UDim2.fromOffset(2, 10)
		t.BackgroundTransparency = 1
		local ax = (i % 2 == 1) and -1 or 1
		local ay = (i <= 2) and -1 or 1
		t.Position = UDim2.new(0.5, ax * 14, 0.5, ay * 14)
		t.Rotation = (i % 2 == 1) and 45 or -45
		t.Parent = hit
		table.insert(self.hitTicks, t)
	end

	-- ------------------------------------------------------------- здоровье
	local healthPanel = Instance.new("Frame")
	healthPanel.Name = "Health"
	healthPanel.Size = UDim2.fromScale(0.26, 0.13)
	healthPanel.Position = UDim2.fromScale(0.018, 0.83)
	healthPanel.BackgroundColor3 = PANEL
	healthPanel.BackgroundTransparency = 0.25
	healthPanel.BorderSizePixel = 0
	healthPanel.Parent = gui
	corner(healthPanel, 12)
	stroke(healthPanel, RED, 1.5, 0.55)
	self.healthPanel = healthPanel

	self.roleChip = label(healthPanel, "ДРОН", UDim2.new(1, -20, 0, 20),
		UDim2.fromOffset(10, 8), CYAN, Enum.Font.GothamBlack)
	self.roleChip.TextXAlignment = Enum.TextXAlignment.Left

	self.healthFill, self.healthHolder = bar(healthPanel, UDim2.new(1, -20, 0, 16),
		UDim2.fromOffset(10, 30), GREEN)
	self.healthText = label(healthPanel, "100", UDim2.new(1, -20, 0, 22),
		UDim2.fromOffset(10, 50), TEXT, Enum.Font.GothamBlack)
	self.healthText.TextXAlignment = Enum.TextXAlignment.Left

	self.droneTitle = label(healthPanel, "РАЗВЕДЧИК", UDim2.new(1, -20, 0, 18),
		UDim2.new(0, 10, 1, -22), MUTED, Enum.Font.GothamMedium)
	self.droneTitle.TextXAlignment = Enum.TextXAlignment.Left

	-- ------------------------------------------------------------- оружие
	local weaponPanel = Instance.new("Frame")
	weaponPanel.Name = "Weapon"
	weaponPanel.Size = UDim2.fromScale(0.26, 0.13)
	weaponPanel.Position = UDim2.fromScale(0.722, 0.83)
	weaponPanel.BackgroundColor3 = PANEL
	weaponPanel.BackgroundTransparency = 0.25
	weaponPanel.BorderSizePixel = 0
	weaponPanel.Parent = gui
	corner(weaponPanel, 12)
	stroke(weaponPanel, ACCENT, 1.5, 0.55)
	self.weaponPanel = weaponPanel

	self.weaponName = label(weaponPanel, "МИНИГАН", UDim2.new(1, -20, 0, 20),
		UDim2.fromOffset(10, 8), TEXT, Enum.Font.GothamBlack)
	self.weaponName.TextXAlignment = Enum.TextXAlignment.Left

	self.heatFill = bar(weaponPanel, UDim2.new(1, -20, 0, 16), UDim2.fromOffset(10, 30), ACCENT)
	self.heatText = label(weaponPanel, "0%", UDim2.new(1, -20, 0, 22),
		UDim2.fromOffset(10, 50), TEXT, Enum.Font.GothamBlack)
	self.heatText.TextXAlignment = Enum.TextXAlignment.Left

	self.ammoText = label(weaponPanel, "", UDim2.new(1, -20, 0, 22),
		UDim2.new(0, 10, 1, -24), MUTED, Enum.Font.GothamBlack)
	self.ammoText.TextXAlignment = Enum.TextXAlignment.Right

	self.buildHint = label(weaponPanel, "", UDim2.new(1, -20, 0, 20),
		UDim2.new(0, 10, 1, -24), GREEN, Enum.Font.GothamMedium)
	self.buildHint.TextXAlignment = Enum.TextXAlignment.Left

	-- ------------------------------------------------------------- телеметрия
	local telemetry = Instance.new("Frame")
	telemetry.Name = "Telemetry"
	telemetry.Size = UDim2.fromScale(0.17, 0.1)
	telemetry.Position = UDim2.fromScale(0.815, 0.7)
	telemetry.BackgroundColor3 = PANEL
	telemetry.BackgroundTransparency = 0.35
	telemetry.BorderSizePixel = 0
	telemetry.Parent = gui
	corner(telemetry, 10)
	stroke(telemetry, CYAN, 1.2, 0.6)

	self.speedText = label(telemetry, "0", UDim2.new(0.5, -8, 0, 26),
		UDim2.fromOffset(8, 6), TEXT, Enum.Font.GothamBlack)
	self.speedText.TextXAlignment = Enum.TextXAlignment.Left
	self.speedUnit = label(telemetry, "СКОРОСТЬ", UDim2.new(0.5, -8, 0, 14),
		UDim2.new(0.5, 0, 0, 10), MUTED, Enum.Font.GothamMedium)
	self.speedUnit.TextXAlignment = Enum.TextXAlignment.Left
	self.altText = label(telemetry, "0", UDim2.new(0.5, -8, 0, 26),
		UDim2.new(0, 8, 0, 40), TEXT, Enum.Font.GothamBlack)
	self.altText.TextXAlignment = Enum.TextXAlignment.Left
	self.altUnit = label(telemetry, "ВЫСОТА", UDim2.new(0.5, -8, 0, 14),
		UDim2.new(0.5, 0, 0, 44), MUTED, Enum.Font.GothamMedium)
	self.altUnit.TextXAlignment = Enum.TextXAlignment.Left

	-- ------------------------------------------------------------- баннер
	self.banner = label(gui, "", UDim2.fromScale(0.7, 0.09), UDim2.fromScale(0.15, 0.14),
		TEXT, Enum.Font.GothamBlack)
	self.banner.TextTransparency = 1
	self.banner.TextStrokeTransparency = 1

	self.modeLine = label(gui, "", UDim2.fromScale(0.6, 0.035),
		UDim2.fromScale(0.2, 0.235), MUTED, Enum.Font.GothamMedium)
	self.modeLine.TextTransparency = 1

	-- ------------------------------------------------------------- лента убийств
	local feedFrame = Instance.new("Frame")
	feedFrame.Name = "Feed"
	feedFrame.Size = UDim2.fromScale(0.3, 0.2)
	feedFrame.Position = UDim2.fromScale(0.685, 0.02)
	feedFrame.BackgroundTransparency = 1
	feedFrame.Parent = gui
	self.feedFrame = feedFrame
	local feedLayout = Instance.new("UIListLayout")
	feedLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	feedLayout.VerticalAlignment = Enum.VerticalAlignment.Top
	feedLayout.Padding = UDim.new(0, 4)
	feedLayout.Parent = feedFrame

	-- ------------------------------------------------------------- вспышка урона
	self.vignette = {}
	for i = 1, 4 do
		local side = Instance.new("Frame")
		side.BackgroundColor3 = RED
		side.BorderSizePixel = 0
		side.BackgroundTransparency = 1
		side.ZIndex = 2
		if i == 1 or i == 2 then
			side.Size = UDim2.fromScale(1, 0.16)
			side.Position = UDim2.fromScale(0, (i == 1) and 0 or 0.84)
		else
			side.Size = UDim2.fromScale(0.16, 1)
			side.Position = UDim2.fromScale((i == 3) and 0 or 0.84, 0)
		end
		local grad = Instance.new("UIGradient")
		grad.Rotation = (i == 1) and 90 or ((i == 2) and 270 or ((i == 3) and 0 or 180))
		grad.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.1),
			NumberSequenceKeypoint.new(1, 1),
		})
		grad.Parent = side
		side.Parent = gui
		table.insert(self.vignette, side)
	end

	-- ------------------------------------------------------------- выбор дрона
	local picker = Instance.new("Frame")
	picker.Name = "DronePicker"
	picker.Size = UDim2.fromScale(0.26, 0.055)
	picker.Position = UDim2.fromScale(0.37, 0.93)
	picker.BackgroundTransparency = 1
	picker.Parent = gui
	local pickerLayout = Instance.new("UIListLayout")
	pickerLayout.FillDirection = Enum.FillDirection.Horizontal
	pickerLayout.Padding = UDim.new(0, 8)
	pickerLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	pickerLayout.Parent = picker
	self.pickerButtons = {}
	self.pickerFrame = picker

	local drones = { { id = "scout", title = "1  РАЗВЕДЧИК" }, { id = "gunship", title = "2  ШТУРМОВИК" } }
	for _, info in ipairs(drones) do
		local b = Instance.new("TextButton")
		b.Size = UDim2.fromScale(0.46, 1)
		b.BackgroundColor3 = PANEL
		b.BackgroundTransparency = 0.25
		b.Text = info.title
		b.TextColor3 = TEXT
		b.Font = Enum.Font.GothamBold
		b.TextScaled = true
		b.Parent = picker
		corner(b, 8)
		stroke(b, CYAN, 1.5, 0.6)
		b.MouseButton1Click:Connect(function()
			if self.callbacks.onSwitchDrone then
				self.callbacks.onSwitchDrone(info.id)
			end
		end)
		self.pickerButtons[info.id] = b
	end

	-- ------------------------------------------------------------- сенсор
	self.touchEnabled = UserInputService.TouchEnabled
	if self.touchEnabled then
		self:buildTouchControls(gui)
	end

	-- эмуляция «патронов» для выжившего: строка
	self.ammoValue = 30
	self.ammoMax = 30

	return self
end

-- --------------------------------------------------------------------------- --
-- сенсорное управление
-- --------------------------------------------------------------------------- --
function DroneUI:makeStick(parent, position, onMove)
	local base = Instance.new("Frame")
	base.AnchorPoint = Vector2.new(0.5, 0.5)
	base.Position = position
	base.Size = UDim2.fromOffset(170, 170)
	base.BackgroundColor3 = Color3.fromRGB(18, 18, 26)
	base.BackgroundTransparency = 0.45
	base.BorderSizePixel = 0
	base.Parent = parent
	corner(base, 85)
	stroke(base, CYAN, 2, 0.5)

	local knob = Instance.new("Frame")
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.Position = UDim2.fromScale(0.5, 0.5)
	knob.Size = UDim2.fromOffset(66, 66)
	knob.BackgroundColor3 = CYAN
	knob.BackgroundTransparency = 0.15
	knob.BorderSizePixel = 0
	knob.Parent = base
	corner(knob, 33)

	local active = false
	local center = Vector2.zero

	local function update(input)
		local pos = Vector2.new(input.Position.X, input.Position.Y)
		local delta = pos - center
		local radius = 85
		if delta.Magnitude > radius then
			delta = delta.Unit * radius
		end
		knob.Position = UDim2.fromScale(0.5 + delta.X / 170, 0.5 + delta.Y / 170)
		onMove(delta.X / radius, delta.Y / radius)
	end

	base.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch
			or input.UserInputType == Enum.UserInputType.MouseButton1 then
			active = true
			local abs = base.AbsolutePosition
			center = Vector2.new(abs.X + base.AbsoluteSize.X / 2, abs.Y + base.AbsoluteSize.Y / 2)
			update(input)
		end
	end)
	base.InputChanged:Connect(function(input)
		if active and (input.UserInputType == Enum.UserInputType.Touch
			or input.UserInputType == Enum.UserInputType.MouseMovement) then
			update(input)
		end
	end)
	base.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch
			or input.UserInputType == Enum.UserInputType.MouseButton1 then
			active = false
			knob.Position = UDim2.fromScale(0.5, 0.5)
			onMove(0, 0)
		end
	end)
	return base
end

function DroneUI:buildTouchControls(gui)
	local self2 = self
	self:makeStick(gui, UDim2.new(0, 130, 1, -180), function(x, y)
		self2.virtual.x = x
		self2.virtual.y = -y
	end)
	self:makeStick(gui, UDim2.new(1, -130, 1, -180), function(x, y)
		self2.virtual.yaw = x
		self2.virtual.up = -y
	end)

	local fire = Instance.new("TextButton")
	fire.Size = UDim2.fromOffset(120, 120)
	fire.AnchorPoint = Vector2.new(0.5, 0.5)
	fire.Position = UDim2.new(1, -250, 1, -160)
	fire.BackgroundColor3 = ACCENT
	fire.BackgroundTransparency = 0.25
	fire.Text = "ОГОНЬ"
	fire.TextColor3 = Color3.fromRGB(24, 10, 6)
	fire.Font = Enum.Font.GothamBlack
	fire.TextScaled = true
	fire.Parent = gui
	corner(fire, 60)
	stroke(fire, Color3.fromRGB(255, 210, 160), 3, 0.2)

	fire.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch then
			self.virtual.fire = true
		end
	end)
	fire.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch then
			self.virtual.fire = false
		end
	end)

	local function smallButton(text, position, color, callback)
		local b = Instance.new("TextButton")
		b.Size = UDim2.fromOffset(82, 82)
		b.AnchorPoint = Vector2.new(0.5, 0.5)
		b.Position = position
		b.BackgroundColor3 = color
		b.BackgroundTransparency = 0.3
		b.Text = text
		b.TextColor3 = TEXT
		b.Font = Enum.Font.GothamBlack
		b.TextScaled = true
		b.Parent = gui
		corner(b, 41)
		stroke(b, TEXT, 2, 0.4)
		b.MouseButton1Click:Connect(callback)
		return b
	end

	self.touchBomb = smallButton("БОМБА", UDim2.new(1, -260, 1, -300), Color3.fromRGB(60, 30, 20),
		function()
			self:callBomb()
		end)
	self.touchBuild = smallButton("СТРОЙ", UDim2.new(1, -360, 1, -120), Color3.fromRGB(24, 60, 40),
		function()
			self:callBuild()
		end)
	self.touchCamera = smallButton("ВИД", UDim2.new(0, 250, 1, -110), Color3.fromRGB(28, 30, 42),
		function()
			self:callToggleCamera()
		end)
end

-- --------------------------------------------------------------------------- --
-- API
-- --------------------------------------------------------------------------- --
function DroneUI:setVisible(value)
	self.gui.Enabled = value
end

function DroneUI:setRole(role)
	self.role = role or "drone"
	local survivor = self.role == "survivor"
	self.roleChip.Text = survivor and "ВЫЖИВШИЙ" or "ДРОН"
	self.roleChip.TextColor3 = survivor and AMBER or CYAN
	self.weaponName.Text = survivor and "ВИНТОВКА" or "МИНИГАН"
	self.pickerFrame.Visible = not survivor
	if self.touchBomb then
		self.touchBomb.Visible = (not survivor) and self.touchEnabled or false
	end
	if self.touchBuild then
		self.touchBuild.Visible = survivor and self.touchEnabled or false
	end
	self.altText.Visible = not survivor
	self.altUnit.Visible = not survivor
end

function DroneUI:setDrone(cfg)
	self.drone = cfg
	if cfg then
		self.droneTitle.Text = cfg.Title
		for id, btn in pairs(self.pickerButtons) do
			local active = (id == cfg.Id)
			btn.BackgroundColor3 = active and Color3.fromRGB(30, 40, 52) or PANEL
			btn.TextColor3 = active and CYAN or MUTED
		end
	end
end

function DroneUI:setMode(text)
	self.modeLine.Text = text or ""
	self.modeLine.TextTransparency = text and 0.25 or 1
end

function DroneUI:banner(text, duration)
	self.bannerToken += 1
	local token = self.bannerToken
	self.banner.Text = text
	self.banner.TextTransparency = 0
	self.banner.TextStrokeTransparency = 0.4
	self.banner.Size = UDim2.fromScale(0.7, 0.06)
	TweenService:Create(self.banner, TweenInfo.new(0.25, Enum.EasingStyle.Back), {
		Size = UDim2.fromScale(0.7, 0.09),
	}):Play()
	task.delay(duration or 3, function()
		if self.bannerToken == token then
			TweenService:Create(self.banner, TweenInfo.new(0.4), {
				TextTransparency = 1,
				TextStrokeTransparency = 1,
			}):Play()
		end
	end)
end

function DroneUI:toast(text, color)
	local line = label(self.feedFrame, text, UDim2.fromScale(1, 0), UDim2.fromScale(0, 0),
		color or TEXT, Enum.Font.GothamMedium)
	line.AutomaticSize = Enum.AutomaticSize.Y
	line.Size = UDim2.fromScale(1, 0)
	line.TextYAlignment = Enum.TextYAlignment.Top
	TweenService:Create(line, TweenInfo.new(0.25), { TextTransparency = 0.2 }):Play()
	task.delay(3.2, function()
		TweenService:Create(line, TweenInfo.new(0.5), {
			TextTransparency = 1,
			TextStrokeTransparency = 1,
		}):Play()
		task.delay(0.5, function()
			line:Destroy()
		end)
	end)
end

function DroneUI:feed(text, color)
	self:toast(text, color)
end

function DroneUI:damageFlash(heal)
	local color = heal and GREEN or RED
	for _, side in ipairs(self.vignette) do
		side.BackgroundColor3 = color
		side.BackgroundTransparency = 0.35
		TweenService:Create(side, TweenInfo.new(0.45), { BackgroundTransparency = 1 }):Play()
	end
end

function DroneUI:hitmarker()
	for _, tick in ipairs(self.hitTicks) do
		tick.BackgroundTransparency = 0.05
		TweenService:Create(tick, TweenInfo.new(0.22), { BackgroundTransparency = 1 }):Play()
	end
end

function DroneUI:getVirtualInput()
	return self.virtual
end

function DroneUI:callBomb()
	if self.callbacks.onBomb then
		self.callbacks.onBomb()
	end
end

function DroneUI:callToggleCamera()
	if self.callbacks.onToggleCamera then
		self.callbacks.onToggleCamera()
	end
end

function DroneUI:callBuild()
	if self.callbacks.onBuildToggle then
		self.callbacks.onBuildToggle()
	end
end

-- --------------------------------------------------------------------------- --
function DroneUI:update(s)
	if not s then
		return
	end
	local hp = math.clamp(s.health or 0, 0, s.maxHealth or 100)
	local frac = hp / math.max(1, s.maxHealth or 100)
	self.healthFill.Size = UDim2.fromScale(frac, 1)
	self.healthFill.BackgroundColor3 = (frac < 0.3) and RED or ((frac < 0.6) and AMBER or GREEN)
	self.healthText.Text = string.format("%d / %d", math.floor(hp), math.floor(s.maxHealth or 100))

	if self.role == "survivor" then
		local ammo = s.ammo or 0
		local mag = s.magazine or 30
		self.heatFill.Size = UDim2.fromScale(ammo / math.max(1, mag), 1)
		self.heatFill.BackgroundColor3 = s.reloading and AMBER or CYAN
		self.heatText.Text = s.reloading and "ПЕРЕЗАРЯДКА"
			or string.format("%d / %d", math.floor(ammo), math.floor(mag))
		self.ammoText.Text = s.buildMode and
			string.format("ДОСКИ %d/%d   [%s]", s.buildCount or 0, s.buildMax or 0,
				s.plankTitle or "") or "[B] СТРОЙКА   [V] НОЖ"
		self.buildHint.Text = s.buildMode and "ЛКМ — поставить   R — повернуть   1-3 — тип" or ""
		self.altText.Text = ""
		self.speedText.Text = ""
	else
		local heat = math.clamp(s.heat or 0, 0, 1)
		self.heat = heat
		self.heatFill.Size = UDim2.fromScale(heat, 1)
		self.heatFill.BackgroundColor3 = heat > 0.85 and RED
			or (s.overheated and AMBER or ACCENT)
		self.heatText.Text = s.overheated and "ПЕРЕГРЕВ"
			or string.format("НАГРЕВ %d%%", math.floor(heat * 100))
		self.ammoText.Text = s.bombLabel or "∞"
		self.buildHint.Text = ""
		local speed = s.speed or 0
		self.speedText.Text = tostring(math.floor(speed))
		self.altText.Text = tostring(math.floor(s.altitude or 0))
		-- прицел «дышит» от нагрева
		local spread = 18 + heat * 16
		for i, tick in ipairs(self.crossTicks) do
			local x = (i == 3) and -spread or ((i == 4) and spread or 0)
			local y = (i == 1) and -spread or ((i == 2) and spread or 0)
			tick.Position = UDim2.new(0.5, x, 0.5, y)
		end
	end
end

return DroneUI
