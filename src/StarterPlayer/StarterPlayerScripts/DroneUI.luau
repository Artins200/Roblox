--!nonstrict
--[[
	DroneUI -- весь интерфейс игры создаётся кодом (никаких ассетов):
	прицел, здоровье, перегрев оружия, скорость/высота, счёт, волны,
	кнопки смены дрона и мобильное управление.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer

local ORANGE = Color3.fromRGB(255, 132, 40)
local AMBER = Color3.fromRGB(255, 196, 92)
local CYAN = Color3.fromRGB(96, 226, 255)
local RED = Color3.fromRGB(255, 74, 60)
local GREEN = Color3.fromRGB(110, 255, 170)
local DARK = Color3.fromRGB(18, 14, 14)

local FONT_BOLD = Enum.Font.GothamBlack
local FONT_MED = Enum.Font.GothamMedium

local function corner(parent, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 8)
	c.Parent = parent
	return c
end

local function stroke(parent, color, thickness, transparency)
	local s = Instance.new("UIStroke")
	s.Color = color or ORANGE
	s.Thickness = thickness or 1.5
	s.Transparency = transparency or 0.25
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent
	return s
end

local function gradient(parent, c1, c2, rotation)
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new(c1, c2)
	g.Rotation = rotation or 90
	g.Parent = parent
	return g
end

local function newLabel(parent, props)
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Font = FONT_MED
	t.TextColor3 = Color3.fromRGB(255, 240, 230)
	t.TextSize = 16
	t.TextXAlignment = Enum.TextXAlignment.Left
	for k, v in pairs(props or {}) do
		t[k] = v
	end
	t.Parent = parent
	return t
end

local function newPanel(parent, size, position, transparency)
	local f = Instance.new("Frame")
	f.Size = size
	f.Position = position
	f.BackgroundColor3 = DARK
	f.BackgroundTransparency = transparency or 0.35
	f.BorderSizePixel = 0
	f.Parent = parent
	corner(f, 10)
	stroke(f, ORANGE, 1.5, 0.55)
	return f
end

-- --------------------------------------------------------------------------- #
-- модуль
-- --------------------------------------------------------------------------- #
local DroneUI = {}
DroneUI.__index = DroneUI

function DroneUI.new(callbacks)
	local self = setmetatable({}, DroneUI)
	self.callbacks = callbacks or {}
	self.cache = {}
	self.virtual = { x = 0, y = 0, up = 0, yaw = 0, fire = false }

	local gui = Instance.new("ScreenGui")
	gui.Name = "DroneHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = 10
	gui.Parent = player:WaitForChild("PlayerGui")
	self.gui = gui

	-- ------------------------------------------------------------- виньетка урона
	local vignette = Instance.new("Frame")
	vignette.Size = UDim2.fromScale(1, 1)
	vignette.BackgroundColor3 = RED
	vignette.BackgroundTransparency = 1
	vignette.BorderSizePixel = 0
	vignette.ZIndex = 2
	vignette.Parent = gui
	self.vignette = vignette

	-- ------------------------------------------------------------- прицел
	local cross = Instance.new("Frame")
	cross.AnchorPoint = Vector2.new(0.5, 0.5)
	cross.Position = UDim2.fromScale(0.5, 0.5)
	cross.Size = UDim2.fromOffset(54, 54)
	cross.BackgroundTransparency = 1
	cross.Parent = gui
	self.cross = cross

	for i, cfg in ipairs({
		{ UDim2.fromOffset(2, 12), UDim2.fromOffset(20, 0), 0 },     -- left
		{ UDim2.fromOffset(2, 12), UDim2.fromOffset(32, 0), 0 },     -- right
		{ UDim2.fromOffset(12, 2), UDim2.fromOffset(0, 20), 0 },     -- top
		{ UDim2.fromOffset(12, 2), UDim2.fromOffset(0, 32), 0 },     -- bottom
	}) do
		local bar = Instance.new("Frame")
		bar.Size = cfg[1]
		bar.Position = cfg[2]
		bar.BackgroundColor3 = AMBER
		bar.BorderSizePixel = 0
		bar.Parent = cross
		corner(bar, 2)
	end
	local dot = Instance.new("Frame")
	dot.Size = UDim2.fromOffset(4, 4)
	dot.Position = UDim2.fromOffset(25, 25)
	dot.BackgroundColor3 = AMBER
	dot.BorderSizePixel = 0
	dot.Parent = cross
	corner(dot, 4)
	self.crossDot = dot

	-- ------------------------------------------------------------- верх: волна
	local wavePanel = newPanel(gui, UDim2.fromOffset(220, 44), UDim2.new(0.5, -110, 0, 18), 0.4)
	wavePanel.AnchorPoint = Vector2.new(0, 0)
	local waveLabel = newLabel(wavePanel, {
		Size = UDim2.fromScale(1, 0.62),
		Position = UDim2.fromScale(0, 0.04),
		Text = "ВОЛНА 1",
		Font = FONT_BOLD,
		TextSize = 20,
		TextColor3 = ORANGE,
		TextXAlignment = Enum.TextXAlignment.Center,
	})
	local waveSub = newLabel(wavePanel, {
		Size = UDim2.fromScale(1, 0.4),
		Position = UDim2.fromScale(0, 0.58),
		Text = "ЛАВОВЫЙ КАНЬОН",
		TextSize = 11,
		TextColor3 = Color3.fromRGB(200, 170, 150),
		TextXAlignment = Enum.TextXAlignment.Center,
	})
	self.waveLabel = waveLabel
	self.waveSub = waveSub

	-- ------------------------------------------------------------- левый верх: дрон
	local status = newPanel(gui, UDim2.fromOffset(292, 104), UDim2.fromOffset(18, 18), 0.4)
	local droneName = newLabel(status, {
		Position = UDim2.fromOffset(12, 8),
		Size = UDim2.fromOffset(200, 20),
		Text = "ДРОН",
		Font = FONT_BOLD,
		TextSize = 16,
		TextColor3 = ORANGE,
	})
	self.droneName = droneName

	local function makeBar(parent, y, width, color)
		local back = Instance.new("Frame")
		back.Position = UDim2.fromOffset(12, y)
		back.Size = UDim2.fromOffset(width, 12)
		back.BackgroundColor3 = Color3.fromRGB(40, 30, 28)
		back.BorderSizePixel = 0
		back.Parent = parent
		corner(back, 6)
		local fill = Instance.new("Frame")
		fill.Size = UDim2.fromScale(1, 1)
		fill.BackgroundColor3 = color
		fill.BorderSizePixel = 0
		fill.Parent = back
		corner(fill, 6)
		return back, fill
	end

	local healthBack, healthFill = makeBar(status, 34, 268, RED)
	gradient(healthFill, RED, Color3.fromRGB(255, 170, 80), 0)
	self.healthFill = healthFill
	local healthText = newLabel(status, {
		Position = UDim2.fromOffset(14, 33),
		Size = UDim2.fromOffset(260, 14),
		Text = "100 / 100",
		TextSize = 12,
		Font = FONT_BOLD,
		TextColor3 = Color3.fromRGB(255, 245, 240),
		TextXAlignment = Enum.TextXAlignment.Center,
	})
	self.healthText = healthText

	local heatLabel = newLabel(status, {
		Position = UDim2.fromOffset(12, 52),
		Size = UDim2.fromOffset(90, 14),
		Text = "ОРУЖИЕ",
		TextSize = 11,
		TextColor3 = Color3.fromRGB(220, 190, 170),
	})
	local _, heatFill = makeBar(status, 70, 268, AMBER)
	gradient(heatFill, AMBER, ORANGE, 0)
	heatFill.Size = UDim2.fromScale(0, 1)
	self.heatFill = heatFill
	local heatText = newLabel(status, {
		Position = UDim2.fromOffset(160, 88 - 2),
		Size = UDim2.fromOffset(118, 14),
		Text = "ГОТОВ",
		TextSize = 11,
		Font = FONT_BOLD,
		TextColor3 = CYAN,
		TextXAlignment = Enum.TextXAlignment.Right,
	})
	self.heatText = heatText

	-- ------------------------------------------------------------- правый верх: счёт
	local score = newPanel(gui, UDim2.fromOffset(210, 78), UDim2.new(1, -228, 0, 18), 0.4)
	local scoreLabel = newLabel(score, {
		Position = UDim2.fromOffset(14, 8),
		Size = UDim2.fromOffset(180, 24),
		Text = "СЧЁТ 0",
		Font = FONT_BOLD,
		TextSize = 18,
		TextColor3 = AMBER,
	})
	local killsLabel = newLabel(score, {
		Position = UDim2.fromOffset(14, 36),
		Size = UDim2.fromOffset(180, 20),
		Text = "СБИТО 0",
		TextSize = 13,
		TextColor3 = Color3.fromRGB(220, 200, 190),
	})
	self.scoreLabel = scoreLabel
	self.killsLabel = killsLabel

	-- ------------------------------------------------------------- низ: приборы
	local instr = Instance.new("Frame")
	instr.AnchorPoint = Vector2.new(0.5, 1)
	instr.Position = UDim2.new(0.5, 0, 1, -22)
	instr.Size = UDim2.fromOffset(330, 62)
	instr.BackgroundTransparency = 1
	instr.Parent = gui

	local speedLabel = newLabel(instr, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.fromOffset(200, 30),
		Text = "0",
		Font = FONT_BOLD,
		TextSize = 30,
		TextColor3 = Color3.fromRGB(255, 240, 225),
		TextXAlignment = Enum.TextXAlignment.Center,
	})
	local speedUnit = newLabel(instr, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(200, 16),
		Text = "СТУД/С",
		TextSize = 11,
		TextColor3 = Color3.fromRGB(200, 160, 130),
		TextXAlignment = Enum.TextXAlignment.Center,
	})
	local altLabel = newLabel(instr, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.72),
		Size = UDim2.fromOffset(200, 18),
		Text = "ВЫСОТА 0",
		TextSize = 13,
		Font = FONT_BOLD,
		TextColor3 = ORANGE,
		TextXAlignment = Enum.TextXAlignment.Center,
	})
	self.speedLabel = speedLabel
	self.altLabel = altLabel

	-- ------------------------------------------------------------- выбор дрона
	local picker = Instance.new("Frame")
	picker.Position = UDim2.new(0, 18, 1, -132)
	picker.Size = UDim2.fromOffset(180, 108)
	picker.BackgroundTransparency = 1
	picker.Parent = gui
	self.picker = picker

	local titles = { "1  РАЗВЕДЧИК", "2  ШТУРМОВИК" }
	local ids = { "scout", "gunship" }
	self.pickButtons = {}
	for i = 1, 2 do
		local b = Instance.new("TextButton")
		b.Size = UDim2.fromOffset(180, 34)
		b.Position = UDim2.fromOffset(0, (i - 1) * 40)
		b.BackgroundColor3 = DARK
		b.BackgroundTransparency = 0.4
		b.BorderSizePixel = 0
		b.Font = FONT_BOLD
		b.TextSize = 13
		b.TextColor3 = Color3.fromRGB(255, 235, 220)
		b.Text = titles[i]
		b.AutoButtonColor = false
		b.Parent = picker
		corner(b, 8)
		local s = stroke(b, ORANGE, 1.2, 0.6)
		b.MouseButton1Click:Connect(function()
			if self.callbacks.onSwitchDrone then
				self.callbacks.onSwitchDrone(ids[i])
			end
		end)
		self.pickButtons[i] = { button = b, stroke = s }
	end

	-- ------------------------------------------------------------- большая надпись
	local banner = newLabel(gui, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.34),
		Size = UDim2.fromOffset(760, 70),
		Text = "",
		Font = FONT_BOLD,
		TextSize = 46,
		TextColor3 = ORANGE,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextTransparency = 1,
	})
	local bannerStroke = Instance.new("UIStroke")
	bannerStroke.Color = Color3.fromRGB(20, 8, 0)
	bannerStroke.Thickness = 3
	bannerStroke.Transparency = 1
	bannerStroke.Parent = banner
	self.banner = banner
	self.bannerStroke = bannerStroke

	-- ------------------------------------------------------------- тосты
	local toasts = Instance.new("Frame")
	toasts.AnchorPoint = Vector2.new(0.5, 0)
	toasts.Position = UDim2.new(0.5, 0, 0, 96)
	toasts.Size = UDim2.fromOffset(460, 200)
	toasts.BackgroundTransparency = 1
	toasts.Parent = gui
	self.toasts = toasts

	-- ------------------------------------------------------------- подсказка управления
	local hint = newLabel(gui, {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 214, 1, -24),
		Size = UDim2.fromOffset(420, 78),
		Text = "WASD — крен и тангаж\nSPACE / SHIFT — тяга     Q / E — рыскание\nЛКМ — миниганы     X — бомба     F — вид от первого лица",
		TextSize = 12,
		TextColor3 = Color3.fromRGB(226, 200, 180),
		TextYAlignment = Enum.TextYAlignment.Bottom,
	})
	self.hint = hint
	task.delay(18, function()
		TweenService:Create(hint, TweenInfo.new(1.5), { TextTransparency = 0.65 }):Play()
	end)

	-- ------------------------------------------------------------- мобильное управление
	self:buildTouchControls(gui)

	return self
end

-- --------------------------------------------------------------------------- #
-- мобильные кнопки
-- --------------------------------------------------------------------------- #
function DroneUI:buildTouchControls(gui)
	if not UserInputService.TouchEnabled then
		return
	end
	local container = Instance.new("Frame")
	container.Size = UDim2.fromScale(1, 1)
	container.BackgroundTransparency = 1
	container.Parent = gui
	self.touch = container

	-- джойстик полёта
	local stick = Instance.new("Frame")
	stick.AnchorPoint = Vector2.new(0.5, 0.5)
	stick.Position = UDim2.new(0, 130, 1, -150)
	stick.Size = UDim2.fromOffset(150, 150)
	stick.BackgroundColor3 = DARK
	stick.BackgroundTransparency = 0.55
	stick.BorderSizePixel = 0
	stick.Parent = container
	corner(stick, 75)
	stroke(stick, ORANGE, 2, 0.5)

	local knob = Instance.new("Frame")
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.Position = UDim2.fromScale(0.5, 0.5)
	knob.Size = UDim2.fromOffset(62, 62)
	knob.BackgroundColor3 = ORANGE
	knob.BackgroundTransparency = 0.15
	knob.BorderSizePixel = 0
	knob.Parent = stick
	corner(knob, 31)

	local dragging = false
	local function updateStick(pos)
		local center = stick.AbsolutePosition + stick.AbsoluteSize / 2
		local delta = pos - center
		local radius = stick.AbsoluteSize.X / 2
		local mag = math.min(delta.Magnitude, radius)
		local dir = mag > 3 and delta.Unit or Vector2.zero
		self.virtual.x = dir.X * (mag / radius)
		self.virtual.y = -dir.Y * (mag / radius)
		knob.Position = UDim2.fromScale(0.5 + dir.X * 0.5 * (mag / radius),
			0.5 + dir.Y * 0.5 * (mag / radius))
	end

	stick.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch
			or input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = true
			updateStick(Vector2.new(input.Position.X, input.Position.Y))
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.Touch
			or input.UserInputType == Enum.UserInputType.MouseMovement) then
			updateStick(Vector2.new(input.Position.X, input.Position.Y))
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch
			or input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = false
			self.virtual.x = 0
			self.virtual.y = 0
			knob.Position = UDim2.fromScale(0.5, 0.5)
		end
	end)

	-- кнопки тяги и огня
	local function roundButton(text, position, size, color)
		local b = Instance.new("TextButton")
		b.AnchorPoint = Vector2.new(0.5, 0.5)
		b.Position = position
		b.Size = size
		b.BackgroundColor3 = DARK
		b.BackgroundTransparency = 0.4
		b.BorderSizePixel = 0
		b.Text = text
		b.Font = FONT_BOLD
		b.TextSize = 20
		b.TextColor3 = color
		b.AutoButtonColor = false
		b.Parent = container
		corner(b, 40)
		stroke(b, color, 2, 0.4)
		return b
	end

	local up = roundButton("▲", UDim2.new(1, -230, 1, -230), UDim2.fromOffset(66, 66), CYAN)
	local down = roundButton("▼", UDim2.new(1, -230, 1, -148), UDim2.fromOffset(66, 66), CYAN)
	local yawL = roundButton("⟲", UDim2.new(1, -306, 1, -230), UDim2.fromOffset(58, 58), AMBER)
	local yawR = roundButton("⟳", UDim2.new(1, -306, 1, -148), UDim2.fromOffset(58, 58), AMBER)
	local fire = roundButton("ОГОНЬ", UDim2.new(1, -110, 1, -186), UDim2.fromOffset(110, 110), RED)

	local function hold(button, onDown, onUp)
		button.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.Touch
				or input.UserInputType == Enum.UserInputType.MouseButton1 then
				onDown()
			end
		end)
		button.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.Touch
				or input.UserInputType == Enum.UserInputType.MouseButton1 then
				onUp()
			end
		end)
	end

	hold(up, function() self.virtual.up = 1 end, function() self.virtual.up = 0 end)
	hold(down, function() self.virtual.up = -1 end, function() self.virtual.up = 0 end)
	hold(yawL, function() self.virtual.yaw = -1 end, function() self.virtual.yaw = 0 end)
	hold(yawR, function() self.virtual.yaw = 1 end, function() self.virtual.yaw = 0 end)
	hold(fire, function() self.virtual.fire = true end, function() self.virtual.fire = false end)

	-- смена вида и бомба
	local camBtn = roundButton("ВИД", UDim2.new(1, -320, 0, 220), UDim2.fromOffset(64, 40), AMBER)
	camBtn.TextSize = 13
	camBtn.MouseButton1Click:Connect(function()
		self:callToggleCamera()
	end)
	local bombBtn = roundButton("БОМБА", UDim2.new(1, -320, 0, 274), UDim2.fromOffset(64, 40), ORANGE)
	bombBtn.TextSize = 13
	bombBtn.MouseButton1Click:Connect(function()
		self:callBomb()
	end)
end

-- --------------------------------------------------------------------------- #
-- API
-- --------------------------------------------------------------------------- #
function DroneUI:getVirtualInput()
	return self.virtual
end

function DroneUI:callToggleCamera()
	if self.callbacks.onToggleCamera then
		self.callbacks.onToggleCamera()
	end
end

function DroneUI:callBomb()
	if self.callbacks.onBomb then
		self.callbacks.onBomb()
	end
end

function DroneUI:setCameraMode(mode)
	if mode == "fpv" then
		self.cross.Visible = true
		self.crossDot.BackgroundColor3 = RED
	else
		self.cross.Visible = true
		self.crossDot.BackgroundColor3 = AMBER
	end
end

function DroneUI:setDrone(cfg)
	if not cfg then
		self.droneName.Text = "ДРОН УНИЧТОЖЕН"
		self.droneName.TextColor3 = RED
		return
	end
	self.droneName.Text = cfg.Title
	self.droneName.TextColor3 = cfg.Tint or ORANGE
	for i, data in ipairs(self.pickButtons) do
		local selected = (i == 1 and cfg.Id == "scout") or (i == 2 and cfg.Id == "gunship")
		data.button.BackgroundTransparency = selected and 0.15 or 0.5
		data.button.TextColor3 = selected and (cfg.Tint or ORANGE) or Color3.fromRGB(180, 165, 155)
		data.stroke.Color = selected and (cfg.Tint or ORANGE) or Color3.fromRGB(90, 70, 60)
	end
end

function DroneUI:banner(text, duration)
	local b = self.banner
	b.Text = text
	b.TextTransparency = 0
	b.TextSize = 52
	self.bannerStroke.Transparency = 0.1
	TweenService:Create(b, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ TextSize = 42 }):Play()
	self.bannerToken = (self.bannerToken or 0) + 1
	local token = self.bannerToken
	task.delay(duration or 3, function()
		if self.bannerToken ~= token then
			return
		end
		TweenService:Create(b, TweenInfo.new(0.6), { TextTransparency = 1 }):Play()
		TweenService:Create(self.bannerStroke, TweenInfo.new(0.6), { Transparency = 1 }):Play()
	end)
end

function DroneUI:toast(text, color)
	local label = newLabel(self.toasts, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.fromOffset(460, 26),
		Text = text,
		Font = FONT_BOLD,
		TextSize = 16,
		TextColor3 = color or Color3.fromRGB(255, 235, 220),
		TextTransparency = 0,
		TextXAlignment = Enum.TextXAlignment.Center,
	})
	-- сдвигаем существующие вниз
	for _, child in ipairs(self.toasts:GetChildren()) do
		if child ~= label and child:IsA("TextLabel") then
			child.Position = child.Position + UDim2.fromOffset(0, 26)
		end
	end
	task.delay(1.6, function()
		local info = TweenInfo.new(0.7)
		TweenService:Create(label, info, {
			TextTransparency = 1,
			Position = label.Position - UDim2.fromOffset(0, 14),
		}):Play()
		task.wait(0.75)
		label:Destroy()
	end)
end

function DroneUI:damageFlash(heal)
	if self.flashTween then
		self.flashTween:Cancel()
	end
	self.vignette.BackgroundColor3 = heal and GREEN or RED
	self.vignette.BackgroundTransparency = heal and 0.82 or 0.72
	self.flashTween = TweenService:Create(self.vignette, TweenInfo.new(0.55),
		{ BackgroundTransparency = 1 })
	self.flashTween:Play()
end

function DroneUI:update(s)
	local cache = self.cache

	-- здоровье
	local hp = math.max(0, math.floor(s.health))
	if cache.health ~= hp then
		cache.health = hp
		local frac = math.clamp(s.health / math.max(s.maxHealth, 1), 0, 1)
		self.healthFill.Size = UDim2.fromScale(frac, 1)
		self.healthFill.BackgroundColor3 = (frac < 0.3) and RED or ((frac < 0.6) and AMBER or Color3.fromRGB(120, 230, 140))
		self.healthText.Text = hp .. " / " .. math.floor(s.maxHealth)
	end

	-- перегрев
	local heatPct = math.clamp(s.heat, 0, 1)
	if math.abs((cache.heat or 0) - heatPct) > 0.01 or cache.overheated ~= s.overheated then
		cache.heat = heatPct
		self.heatFill.Size = UDim2.fromScale(heatPct, 1)
		local c = ORANGE
		if s.overheated then
			c = RED
			self.heatText.Text = "ПЕРЕГРЕВ"
			self.heatText.TextColor3 = RED
		elseif heatPct > 0.6 then
			c = AMBER
			self.heatText.Text = "ГОРЯЧО"
			self.heatText.TextColor3 = AMBER
		else
			self.heatText.Text = "ГОТОВ"
			self.heatText.TextColor3 = CYAN
		end
		self.heatFill.BackgroundColor3 = c
		cache.overheated = s.overheated
	end

	-- скорость/высота
	local spd = math.floor(s.speed)
	if cache.speed ~= spd then
		cache.speed = spd
		self.speedLabel.Text = tostring(spd)
	end
	local alt = math.floor(s.altitude)
	if cache.alt ~= alt then
		cache.alt = alt
		self.altLabel.Text = "ВЫСОТА " .. alt
		self.altLabel.TextColor3 = alt < 6 and RED or ORANGE
	end

	-- счёт
	local score = math.floor(s.score)
	if cache.score ~= score then
		cache.score = score
		self.scoreLabel.Text = "СЧЁТ " .. score
	end
	local kills = math.floor(s.kills)
	if cache.kills ~= kills then
		cache.kills = kills
		self.killsLabel.Text = "СБИТО " .. kills
	end
	local wave = math.floor(s.wave)
	if cache.wave ~= wave then
		cache.wave = wave
		self.waveLabel.Text = "ВОЛНА " .. wave
	end

	-- прицел дышит при перегреве
	if s.overheated then
		self.crossDot.BackgroundColor3 = RED
		self.crossDot.Size = UDim2.fromOffset(7, 7)
	else
		self.crossDot.BackgroundColor3 = AMBER
		self.crossDot.Size = UDim2.fromOffset(4, 4)
	end
end

return DroneUI
