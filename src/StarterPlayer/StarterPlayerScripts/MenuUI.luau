--!nonstrict
--[[
	MenuUI -- меню игры: стартовый экран, выбор стороны, голосование за режим,
	экран итогов, верхняя панель с таймером и таблица счёта (Tab).

	Всё собирается кодом, никаких ассетов.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("DroneConfig"))
local GameData = require(game:GetService("ReplicatedStorage"):WaitForChild("GameData"))

local MenuUI = {}
MenuUI.__index = MenuUI

local BG = Color3.fromRGB(10, 10, 14)
local PANEL = Color3.fromRGB(18, 19, 26)
local ACCENT = Color3.fromRGB(255, 120, 52)
local ACCENT2 = Color3.fromRGB(120, 225, 255)
local TEXT = Color3.fromRGB(238, 238, 244)
local MUTED = Color3.fromRGB(150, 152, 168)

-- --------------------------------------------------------------------------- --
-- помощники
-- --------------------------------------------------------------------------- --
local function corner(parent, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 10)
	c.Parent = parent
	return c
end

local function stroke(parent, color, thickness, transparency)
	local s = Instance.new("UIStroke")
	s.Color = color or ACCENT
	s.Thickness = thickness or 2
	s.Transparency = transparency or 0
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent
	return s
end

local function label(parent, text, size, color, font, scaled)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = size
	l.Text = text
	l.TextColor3 = color or TEXT
	l.Font = font or Enum.Font.GothamBold
	l.TextScaled = scaled ~= false
	l.TextStrokeTransparency = 0.6
	l.Parent = parent
	return l
end

local function button(parent, text, size, color)
	local b = Instance.new("TextButton")
	b.Size = size
	b.BackgroundColor3 = color or Color3.fromRGB(30, 32, 42)
	b.Text = text
	b.TextColor3 = TEXT
	b.Font = Enum.Font.GothamBlack
	b.TextScaled = true
	b.AutoButtonColor = true
	b.Parent = parent
	corner(b, 10)
	stroke(b, ACCENT, 2, 0.35)
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 8)
	pad.PaddingRight = UDim.new(0, 8)
	pad.Parent = b
	return b
end

local function formatTime(sec)
	sec = math.max(0, math.floor(sec or 0))
	return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end

local function modeById(id)
	for _, m in ipairs(GameData.Modes) do
		if m.Id == id then
			return m
		end
	end
	return GameData.Modes[1]
end

local function mapById(id)
	for _, m in ipairs(GameData.Maps) do
		if m.Id == id then
			return m
		end
	end
	return GameData.Maps[1]
end

-- --------------------------------------------------------------------------- --
-- создание
-- --------------------------------------------------------------------------- --
function MenuUI.new(callbacks)
	local self = setmetatable({}, MenuUI)
	self.callbacks = callbacks or {}
	self.voteButtons = {}
	self.modeCards = {}
	self.roleCards = {}
	self.selectedRole = "auto"
	self.snapshot = nil
	self.mine = nil
	self.phase = "Menu"

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "DroneMenu"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 40
	gui.Enabled = true
	gui.Parent = playerGui
	self.gui = gui

	-- ------------------------------------------------------------- фон меню
	local backdrop = Instance.new("Frame")
	backdrop.Name = "Backdrop"
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.BackgroundColor3 = BG
	backdrop.BackgroundTransparency = 0.15
	backdrop.BorderSizePixel = 0
	backdrop.Visible = true
	backdrop.Parent = gui
	self.backdrop = backdrop

	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(6, 8, 16)),
		ColorSequenceKeypoint.new(0.55, Color3.fromRGB(26, 14, 22)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(60, 22, 14)),
	})
	gradient.Parent = backdrop

	-- неоновые линии для стиля
	for i = 1, 5 do
		local line = Instance.new("Frame")
		line.BackgroundColor3 = (i % 2 == 0) and ACCENT or ACCENT2
		line.BackgroundTransparency = 0.72
		line.BorderSizePixel = 0
		line.Size = UDim2.fromOffset(900, 2)
		line.Position = UDim2.fromScale(0.5, 0.16 + i * 0.13)
		line.AnchorPoint = Vector2.new(0.5, 0.5)
		line.Rotation = -8 + i * 3
		line.Parent = backdrop
	end

	-- ------------------------------------------------------------- заголовок
	local title = label(backdrop, "ДРОНЫ", UDim2.fromScale(1, 0.14), TEXT,
		Enum.Font.GothamBlack)
	title.Position = UDim2.fromScale(0, 0.09)
	title.TextScaled = true
	local tGrad = Instance.new("UIGradient")
	tGrad.Rotation = 90
	tGrad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 240, 210)),
		ColorSequenceKeypoint.new(1, ACCENT),
	})
	tGrad.Parent = title

	local subtitle = label(backdrop, "АРЕНА НАД БЕЗДНОЙ  •  КООПЕРАТИВНЫЕ РЕЖИМЫ",
		UDim2.fromScale(0.8, 0.035), MUTED, Enum.Font.GothamMedium)
	subtitle.Position = UDim2.fromScale(0.1, 0.225)

	-- ------------------------------------------------------------- карточки режимов
	local cardsFrame = Instance.new("Frame")
	cardsFrame.Name = "ModeCards"
	cardsFrame.BackgroundTransparency = 1
	cardsFrame.Size = UDim2.fromScale(0.86, 0.19)
	cardsFrame.Position = UDim2.fromScale(0.07, 0.28)
	cardsFrame.Parent = backdrop
	self.cardsFrame = cardsFrame

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.Padding = UDim.new(0, 10)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Parent = cardsFrame

	for index, mode in ipairs(GameData.Modes) do
		local card = Instance.new("TextButton")
		card.Name = mode.Id
		card.LayoutOrder = index
		card.Size = UDim2.fromScale(0.235, 1)
		card.BackgroundColor3 = PANEL
		card.BackgroundTransparency = 0.1
		card.Text = ""
		card.AutoButtonColor = false
		card.Parent = cardsFrame
		corner(card, 12)

		local cardStroke = stroke(card, mode.Color, 2, 0.4)
		local top = Instance.new("Frame")
		top.Size = UDim2.new(1, 0, 0, 4)
		top.BackgroundColor3 = mode.Color
		top.BorderSizePixel = 0
		top.Parent = card

		local name = label(card, mode.Title, UDim2.new(1, -16, 0, 32), TEXT,
			Enum.Font.GothamBlack)
		name.Position = UDim2.fromOffset(8, 12)

		local desc = label(card, mode.Desc, UDim2.new(1, -20, 1, -86), MUTED,
			Enum.Font.GothamMedium)
		desc.Position = UDim2.fromOffset(10, 46)
		desc.TextWrapped = true
		desc.TextYAlignment = Enum.TextYAlignment.Top

		local votes = label(card, "0", UDim2.new(0.5, 0, 0, 40), mode.Color,
			Enum.Font.GothamBlack)
		votes.Position = UDim2.new(0.25, 0, 1, -48)

		local voteBarBg = Instance.new("Frame")
		voteBarBg.Size = UDim2.new(0.8, 0, 0, 6)
		voteBarBg.Position = UDim2.new(0.1, 0, 1, -10)
		voteBarBg.BackgroundColor3 = Color3.fromRGB(40, 42, 54)
		voteBarBg.BorderSizePixel = 0
		voteBarBg.Parent = card
		corner(voteBarBg, 3)

		local voteBar = Instance.new("Frame")
		voteBar.Size = UDim2.fromScale(0, 1)
		voteBar.BackgroundColor3 = mode.Color
		voteBar.BorderSizePixel = 0
		voteBar.Parent = voteBarBg
		corner(voteBar, 3)

		self.modeCards[mode.Id] = {
			button = card,
			stroke = cardStroke,
			votesText = votes,
			bar = voteBar,
			barBg = voteBarBg,
			mode = mode,
		}

		card.MouseButton1Click:Connect(function()
			if self.callbacks.onVote then
				self.callbacks.onVote(mode.Id)
			end
		end)
	end

	local voteHint = label(backdrop, "НАЖМИТЕ НА РЕЖИМ, ЧТОБЫ ПРОГОЛОСОВАТЬ",
		UDim2.fromScale(0.6, 0.025), MUTED, Enum.Font.GothamMedium)
	voteHint.Position = UDim2.fromScale(0.2, 0.482)
	self.voteHint = voteHint

	-- ------------------------------------------------------------- кнопка старта
	local startBtn = button(backdrop, "НАЧАТЬ ИГРУ", UDim2.fromScale(0.34, 0.085), ACCENT)
	startBtn.Position = UDim2.fromScale(0.33, 0.55)
	startBtn.TextColor3 = Color3.fromRGB(24, 10, 6)
	stroke(startBtn, Color3.fromRGB(255, 200, 150), 3, 0.1)
	self.startBtn = startBtn
	startBtn.MouseButton1Click:Connect(function()
		self:showRolePicker(true)
	end)

	local status = label(backdrop, "", UDim2.fromScale(0.7, 0.03), MUTED,
		Enum.Font.GothamMedium)
	status.Position = UDim2.fromScale(0.15, 0.652)
	self.statusLabel = status

	local hint = label(backdrop,
		"WASD — полёт   ЛКМ — огонь   X — бомба   F — вид   B — стройка   TAB — счёт",
		UDim2.fromScale(0.8, 0.026), Color3.fromRGB(110, 112, 128), Enum.Font.GothamMedium)
	hint.Position = UDim2.fromScale(0.1, 0.94)

	-- ------------------------------------------------------------- выбор роли
	local roleFrame = Instance.new("Frame")
	roleFrame.Name = "RolePicker"
	roleFrame.Size = UDim2.fromScale(1, 1)
	roleFrame.BackgroundColor3 = BG
	roleFrame.BackgroundTransparency = 0.25
	roleFrame.BorderSizePixel = 0
	roleFrame.Visible = false
	roleFrame.Parent = gui
	self.roleFrame = roleFrame

	local roleTitle = label(roleFrame, "ЗА КОГО ХОТИТЕ ИГРАТЬ?",
		UDim2.fromScale(0.9, 0.12), TEXT, Enum.Font.GothamBlack)
	roleTitle.Position = UDim2.fromScale(0.05, 0.2)

	local roleCards = Instance.new("Frame")
	roleCards.BackgroundTransparency = 1
	roleCards.Size = UDim2.fromScale(0.84, 0.24)
	roleCards.Position = UDim2.fromScale(0.08, 0.36)
	roleCards.Parent = roleFrame
	local roleLayout = Instance.new("UIListLayout")
	roleLayout.FillDirection = Enum.FillDirection.Horizontal
	roleLayout.Padding = UDim.new(0, 12)
	roleLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	roleLayout.Parent = roleCards

	for index, role in ipairs(Config.Roles) do
		local card = Instance.new("TextButton")
		card.Name = role.Id
		card.Size = UDim2.fromScale(0.235, 1)
		card.BackgroundColor3 = PANEL
		card.Text = ""
		card.AutoButtonColor = false
		card.LayoutOrder = index
		card.Parent = roleCards
		corner(card, 12)
		local s = stroke(card, ACCENT2, 2, 0.6)

		local title2 = label(card, role.Title, UDim2.new(1, -16, 0, 34), TEXT,
			Enum.Font.GothamBlack)
		title2.Position = UDim2.fromOffset(8, 10)
		local desc2 = label(card, role.Desc, UDim2.new(1, -20, 1, -54), MUTED,
			Enum.Font.GothamMedium)
		desc2.Position = UDim2.fromOffset(10, 48)
		desc2.TextWrapped = true
		desc2.TextYAlignment = Enum.TextYAlignment.Top

		self.roleCards[role.Id] = { button = card, stroke = s, role = role }
		card.MouseButton1Click:Connect(function()
			self:selectRole(role.Id)
		end)
	end

	local goBtn = button(roleFrame, "В БОЙ", UDim2.fromScale(0.28, 0.08), ACCENT)
	goBtn.Position = UDim2.fromScale(0.36, 0.66)
	goBtn.TextColor3 = Color3.fromRGB(24, 10, 6)
	goBtn.MouseButton1Click:Connect(function()
		if self.callbacks.onJoin then
			self.callbacks.onJoin(self.selectedRole)
		end
		self:showRolePicker(false)
	end)

	local backBtn = button(roleFrame, "НАЗАД", UDim2.fromScale(0.16, 0.06),
		Color3.fromRGB(30, 32, 42))
	backBtn.Position = UDim2.fromScale(0.42, 0.77)
	backBtn.MouseButton1Click:Connect(function()
		self:showRolePicker(false)
	end)

	self:selectRole("auto")

	-- ------------------------------------------------------------- верхняя панель
	local top = Instance.new("Frame")
	top.Name = "TopBar"
	top.Size = UDim2.fromScale(0.5, 0.075)
	top.Position = UDim2.fromScale(0.25, 0.012)
	top.BackgroundColor3 = Color3.fromRGB(12, 12, 18)
	top.BackgroundTransparency = 0.35
	top.BorderSizePixel = 0
	top.Parent = gui
	corner(top, 12)
	stroke(top, ACCENT, 1.5, 0.55)
	self.topBar = top

	self.topPhase = label(top, "ГОЛОСОВАНИЕ", UDim2.fromScale(0.5, 0.45), ACCENT,
		Enum.Font.GothamBlack)
	self.topPhase.Position = UDim2.fromScale(0.03, 0.06)
	self.topTimer = label(top, "0:25", UDim2.fromScale(0.28, 0.45), TEXT,
		Enum.Font.GothamBlack)
	self.topTimer.Position = UDim2.fromScale(0.69, 0.06)
	self.topInfo = label(top, "", UDim2.fromScale(0.94, 0.3), MUTED, Enum.Font.GothamMedium)
	self.topInfo.Position = UDim2.fromScale(0.03, 0.56)

	-- ------------------------------------------------------------- итоги раунда
	local result = Instance.new("Frame")
	result.Name = "Result"
	result.Size = UDim2.fromScale(1, 0.28)
	result.Position = UDim2.fromScale(0, 0.36)
	result.BackgroundColor3 = Color3.fromRGB(10, 10, 14)
	result.BackgroundTransparency = 0.25
	result.BorderSizePixel = 0
	result.Visible = false
	result.Parent = gui
	self.resultFrame = result
	local rGrad = Instance.new("UIGradient")
	rGrad.Rotation = 90
	rGrad.Color = ColorSequence.new(Color3.fromRGB(60, 20, 12), Color3.fromRGB(12, 12, 16))
	rGrad.Parent = result

	self.resultText = label(result, "ПОБЕДА", UDim2.fromScale(0.9, 0.5), TEXT,
		Enum.Font.GothamBlack)
	self.resultText.Position = UDim2.fromScale(0.05, 0.1)
	self.resultSub = label(result, "", UDim2.fromScale(0.9, 0.22), MUTED,
		Enum.Font.GothamMedium)
	self.resultSub.Position = UDim2.fromScale(0.05, 0.66)

	-- ------------------------------------------------------------- таблица счёта
	local score = Instance.new("Frame")
	score.Name = "Scoreboard"
	score.Size = UDim2.fromScale(0.6, 0.6)
	score.Position = UDim2.fromScale(0.2, 0.18)
	score.BackgroundColor3 = Color3.fromRGB(10, 10, 16)
	score.BackgroundTransparency = 0.08
	score.BorderSizePixel = 0
	score.Visible = false
	score.Parent = gui
	corner(score, 14)
	stroke(score, ACCENT2, 2, 0.4)
	self.scoreFrame = score

	local scoreTitle = label(score, "ТАБЛИЦА", UDim2.new(1, -20, 0, 34), ACCENT2,
		Enum.Font.GothamBlack)
	scoreTitle.Position = UDim2.fromOffset(10, 8)

	local header = label(score, "ИГРОК              РОЛЬ        К   С   ОЧКИ",
		UDim2.new(1, -20, 0, 22), MUTED, Enum.Font.Code)
	header.Position = UDim2.fromOffset(10, 44)

	local rows = Instance.new("Frame")
	rows.BackgroundTransparency = 1
	rows.Size = UDim2.new(1, -20, 1, -76)
	rows.Position = UDim2.fromOffset(10, 70)
	rows.Parent = score
	local rowsLayout = Instance.new("UIListLayout")
	rowsLayout.Padding = UDim.new(0, 3)
	rowsLayout.Parent = rows
	self.scoreRows = rows

	return self
end

-- --------------------------------------------------------------------------- --
function MenuUI:selectRole(roleId)
	self.selectedRole = roleId
	for id, card in pairs(self.roleCards) do
		local active = (id == roleId)
		card.stroke.Color = active and ACCENT or ACCENT2
		card.stroke.Thickness = active and 3 or 2
		card.button.BackgroundColor3 = active and Color3.fromRGB(40, 26, 18)
			or Color3.fromRGB(18, 19, 26)
	end
end

function MenuUI:showRolePicker(value)
	self.roleFrame.Visible = value
	self.backdrop.Visible = not value
end

function MenuUI:votingVisible(value)
	self.cardsFrame.Visible = value
	self.voteHint.Visible = value
end

-- --------------------------------------------------------------------------- --
function MenuUI:update(snap, mine)
	if not snap then
		return
	end
	self.snapshot = snap
	self.mine = mine
	local mode = modeById(snap.mode)
	local map = mapById(snap.mapId)

	-- верхняя панель
	local phaseName = "МЕНЮ"
	if snap.phase == "Vote" then
		phaseName = "ГОЛОСОВАНИЕ"
	elseif snap.phase == "Round" then
		phaseName = mode.Title
	elseif snap.phase == "End" then
		phaseName = "ИТОГИ"
	end
	self.topPhase.Text = phaseName
	self.topTimer.Text = formatTime(snap.timeLeft)
	self.topTimer.TextColor3 = (snap.timeLeft or 0) <= 10 and Color3.fromRGB(255, 120, 110) or TEXT
	self.topInfo.Text = "КАРТА: " .. map.Title .. "    •    ИГРОКОВ: " .. tostring(#snap.players)

	-- карточки режимов
	local total = math.max(1, snap.voteTotal or 0)
	for modeId, card in pairs(self.modeCards) do
		local count = (snap.votes and snap.votes[modeId]) or 0
		card.votesText.Text = tostring(count)
		card.bar.Size = UDim2.fromScale(math.clamp(count / total, 0, 1), 1)
		-- подсветка своего голоса
		local voted = false
		for _, p in ipairs(snap.players or {}) do
			if p.userId == Players.LocalPlayer.UserId and p.vote == modeId then
				voted = true
			end
		end
		card.stroke.Color = voted and Color3.fromRGB(255, 255, 255) or card.mode.Color
		card.stroke.Thickness = voted and 3 or 2
	end

	-- что показываем
	local inRound = (snap.phase == "Round")
	local playing = inRound and mine and mine.role and mine.role ~= "spectator"
	local waiting = inRound and not playing

	if playing then
		self.backdrop.Visible = false
		self.roleFrame.Visible = false
	else
		self.backdrop.Visible = not self.roleFrame.Visible
		self:showRolePicker(self.roleFrame.Visible)
	end

	-- итоги
	if snap.phase == "End" and snap.result and snap.result ~= "" then
		self.resultFrame.Visible = true
		self.resultText.Text = snap.result
		self.resultSub.Text = "СЛЕДУЮЩЕЕ ГОЛОСОВАНИЕ ЧЕРЕЗ " .. formatTime(snap.timeLeft) ..
			"   •   НОВАЯ КАРТА БУДЕТ СЛУЧАЙНОЙ"
	else
		self.resultFrame.Visible = false
	end

	-- статус под кнопкой
	if waiting then
		self.statusLabel.Text = "РАУНД ИДЁТ: " .. mode.Title .. "  •  НАЖМИТЕ «НАЧАТЬ ИГРУ», ЧТОБЫ ВОЙТИ"
		self.startBtn.Text = "ВОЙТИ В РАУНД"
	elseif snap.phase == "Vote" then
		self.statusLabel.Text = "ВЫБЕРИТЕ РЕЖИМ ГОЛОСОМ  •  КАРТА: " .. map.Title ..
			"  •  ГОЛОСОВ: " .. tostring(snap.voteTotal or 0)
		self.startBtn.Text = "НАЧАТЬ ИГРУ"
	else
		self.statusLabel.Text = "ИГРОКОВ В ИГРЕ: " .. tostring(#(snap.players or {})) ..
			"  •  РЕЖИМ: " .. mode.Title
		self.startBtn.Text = "НАЧАТЬ ИГРУ"
	end

	self:votingVisible(snap.phase == "Vote")

	-- таблица счёта
	if self.scoreFrame.Visible then
		self:renderScore(snap)
	end
end

function MenuUI:renderScore(snap)
	for _, child in ipairs(self.scoreRows:GetChildren()) do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	local sorted = table.clone(snap.players or {})
	table.sort(sorted, function(a, b)
		if (a.kills or 0) ~= (b.kills or 0) then
			return (a.kills or 0) > (b.kills or 0)
		end
		return (a.score or 0) > (b.score or 0)
	end)
	local roleName = {
		drone = "ДРОН",
		survivor = "ВЫЖИВШИЙ",
		spectator = "—",
	}
	for index, p in ipairs(sorted) do
		if index > 12 then
			break
		end
		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, 0, 0, 26)
		row.BackgroundColor3 = (index % 2 == 0) and Color3.fromRGB(20, 22, 30)
			or Color3.fromRGB(15, 16, 22)
		row.BorderSizePixel = 0
		row.Parent = self.scoreRows
		corner(row, 6)
		local text = string.format("%-18s %-10s %2d  %2d  %5d", string.sub(p.name, 1, 18),
			roleName[p.role] or "—", p.kills or 0, p.deaths or 0, p.score or 0)
		local l = label(row, text, UDim2.new(1, -12, 1, 0), (p.role == "drone") and ACCENT2 or TEXT,
			Enum.Font.Code)
		l.Position = UDim2.fromOffset(6, 0)
		l.TextXAlignment = Enum.TextXAlignment.Left
		l.TextScaled = false
		l.TextSize = 15
	end
end

function MenuUI:toggleScoreboard()
	self.scoreFrame.Visible = not self.scoreFrame.Visible
	if self.scoreFrame.Visible and self.snapshot then
		self:renderScore(self.snapshot)
	end
	return self.scoreFrame.Visible
end

function MenuUI:setScoreboard(value)
	self.scoreFrame.Visible = value
	if value and self.snapshot then
		self:renderScore(self.snapshot)
	end
end

function MenuUI:setVisible(value)
	self.gui.Enabled = value
end

return MenuUI
