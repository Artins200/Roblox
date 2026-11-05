--!nonstrict
--[[
	DroneServer -- авторитетный сервер игры «ДРОНЫ».

	Держит:
	  * цикл: МЕНЮ -> ГОЛОСОВАНИЕ ЗА РЕЖИМ -> РАУНД -> ИТОГИ -> ...
	  * выдачу ролей (дрон / выживший) по предпочтению игрока;
	  * загрузку карты из ServerStorage.Maps и переключение света/тумана;
	  * спавн дронов с передачей сетевого владения клиенту;
	  * оружие выживших, строительство из досок, урон, смерти, респавн;
	  * ИИ-ботов, чтобы режимы жили даже с одним игроком;
	  * очки, таблицу лидеров и экран итогов.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local Debris = game:GetService("Debris")
local Teams = game:GetService("Teams")

local Config = require(ReplicatedStorage:WaitForChild("DroneConfig"))
local GameData = require(ReplicatedStorage:WaitForChild("GameData"))

local R = Config.Round
local INF = Config.Infantry

Players.CharacterAutoLoads = false

-- --------------------------------------------------------------------------- --
-- Ремоуты
-- --------------------------------------------------------------------------- --
local remotes = Instance.new("Folder")
remotes.Name = "DroneRemotes"
remotes.Parent = ReplicatedStorage

local function newRemote(name, cls)
	local r = Instance.new(cls or "RemoteEvent")
	r.Name = name
	r.Parent = remotes
	return r
end

local Rem = {
	Sync = newRemote("Sync"),               -- сервер -> все: состояние игры
	Join = newRemote("Join"),               -- клиент -> сервер: я в игре, роль
	Vote = newRemote("Vote"),               -- клиент -> сервер: голос за режим
	SetRole = newRemote("SetRole"),         -- смена роли на ходу
	SetDrone = newRemote("SetDrone"),       -- сервер -> клиент: твой дрон
	DroneLost = newRemote("DroneLost"),
	Fire = newRemote("Fire"),               -- миниган дрона
	FireFX = newRemote("FireFX"),
	Bomb = newRemote("Bomb"),
	BombFX = newRemote("BombFX"),
	ExplosionFX = newRemote("ExplosionFX"),
	Banner = newRemote("Banner"),
	Crash = newRemote("Crash"),
	DamageFX = newRemote("DamageFX"),
	RequestDrone = newRemote("RequestDrone"),
	GunFire = newRemote("GunFire"),         -- винтовка выжившего
	GunFX = newRemote("GunFX"),
	Melee = newRemote("Melee"),
	MeleeFX = newRemote("MeleeFX"),
	Build = newRemote("Build"),
	Placed = newRemote("Placed"),
	Health = newRemote("Health"),
	Hitmark = newRemote("Hitmark"),
	Feed = newRemote("Feed"),
	PickupBeacon = newRemote("PickupBeacon"),
}

-- --------------------------------------------------------------------------- --
-- Состояние игры
-- --------------------------------------------------------------------------- --
local Game = {
	Phase = "Menu",        -- Menu | Vote | Round | End
	Mode = "free",
	MapId = "lava",
	TimeLeft = 0,
	Serial = 0,
	Votes = {},            -- userId -> modeId
	Winner = nil,
	ResultText = "",
	Beacons = {},
}

local PState = {}          -- userId -> состояние игрока
local drones = {}          -- userId -> { model, cfg, health, alive, guns }
local survivors = {}       -- userId -> { character, humanoid }
local bots = {}            -- список ботов
local builtParts = {}      -- userId -> { parts }

-- forward-объявления: функции, нужные друг другу и Heartbeat'у
local chooseDroneId, teamAlive, aliveSurvivors, aliveDrones, spawnBotAt
local spawnDrone, registerKill

-- --------------------------------------------------------------------------- --
-- Мелкие помощники
-- --------------------------------------------------------------------------- --
local function now()
	return os.clock()
end

local function log(...)
	print("[ДРОНЫ]", ...)
end

local function ps(player)
	local s = PState[player.UserId]
	if not s then
		s = {
			ready = false,
			rolePref = "auto",
			role = nil,          -- drone | survivor
			kills = 0,
			deaths = 0,
			score = 0,
			team = nil,
			droneId = nil,
			lastFire = 0,
			lastMelee = 0,
			lastBuild = 0,
			ammo = INF.Rifle.Magazine,
			reloading = false,
			joinedAt = now(),
		}
		PState[player.UserId] = s
	end
	return s
end

local function readyPlayers()
	local list = {}
	for _, p in ipairs(Players:GetPlayers()) do
		if PState[p.UserId] and PState[p.UserId].ready then
			table.insert(list, p)
		end
	end
	return list
end

local function playerByUserId(id)
	for _, p in ipairs(Players:GetPlayers()) do
		if p.UserId == id then
			return p
		end
	end
	return nil
end

local function announce(text, duration)
	Rem.Banner:FireAllClients(text, duration or 3.5)
end

local function feed(text, color)
	Rem.Feed:FireAllClients(text, color)
end

local function findWithAttribute(scope, attr)
	for _, d in ipairs(scope:GetDescendants()) do
		if d:GetAttribute(attr) then
			return d
		end
	end
	return nil
end

-- нормализованное имя детали ("Minigan One" -> "miniganone")
local function normName(name)
	return (string.gsub(string.lower(name), "[%s_%-]", ""))
end

local function findNamed(root, wanted)
	local w = normName(wanted)
	for _, d in ipairs(root:GetDescendants()) do
		if normName(d.Name) == w then
			return d
		end
	end
	return nil
end

-- --------------------------------------------------------------------------- --
-- Снимок состояния для клиента
-- --------------------------------------------------------------------------- --
local function buildSnapshot()
	local votes = {}
	local total = 0
	for _, modeId in pairs(Game.Votes) do
		votes[modeId] = (votes[modeId] or 0) + 1
		total += 1
	end
	local players = {}
	local readyCount = 0
	for _, p in ipairs(Players:GetPlayers()) do
		local s = ps(p)
		if s.ready then
			readyCount += 1
		end
		table.insert(players, {
			name = p.DisplayName,
			userId = p.UserId,
			ready = s.ready,
			role = s.role,
			team = s.team,
			kills = s.kills,
			deaths = s.deaths,
			score = s.score,
			vote = Game.Votes[p.UserId],
		})
	end
	return {
		phase = Game.Phase,
		mode = Game.Mode,
		mapId = Game.MapId,
		timeLeft = math.max(0, math.floor(Game.TimeLeft)),
		votes = votes,
		voteTotal = total,
		players = players,
		ready = readyCount,
		winner = Game.Winner,
		result = Game.ResultText,
		serial = Game.Serial,
	}
end

local function broadcast()
	local snap = buildSnapshot()
	for _, p in ipairs(Players:GetPlayers()) do
		local mine = {
			role = ps(p).role,
			alive = (drones[p.UserId] and drones[p.UserId].alive)
				or (survivors[p.UserId] ~= nil),
			droneId = ps(p).droneId,
			ammo = ps(p).ammo,
			rolePref = ps(p).rolePref,
			ready = ps(p).ready,
		}
		Rem.Sync:FireClient(p, snap, mine)
	end
end

-- --------------------------------------------------------------------------- --
-- Карты: загрузка, свет, точки спавна
-- --------------------------------------------------------------------------- --
local MapTheme = {
	lava = {
		brightness = 2.2, clock = 8.4,
		ambient = Color3.fromRGB(76, 46, 38), outdoor = Color3.fromRGB(104, 60, 44),
		fogColor = Color3.fromRGB(158, 70, 38), fogStart = 180, fogEnd = 2100,
		shiftTop = Color3.fromRGB(255, 148, 70), shiftBottom = Color3.fromRGB(64, 14, 0),
		atmColor = Color3.fromRGB(255, 152, 104), atmDecay = Color3.fromRGB(118, 54, 38),
		atmDensity = 0.44, haze = 1.7, glare = 0.45,
		bloom = 1.35, bloomSize = 28, bloomThreshold = 1.05,
		gravity = 196.2,
	},
	desert = {
		brightness = 3.0, clock = 16.2,
		ambient = Color3.fromRGB(180, 150, 112), outdoor = Color3.fromRGB(210, 180, 138),
		fogColor = Color3.fromRGB(238, 206, 156), fogStart = 320, fogEnd = 2600,
		shiftTop = Color3.fromRGB(255, 226, 168), shiftBottom = Color3.fromRGB(150, 116, 78),
		atmColor = Color3.fromRGB(255, 224, 176), atmDecay = Color3.fromRGB(180, 148, 110),
		atmDensity = 0.34, haze = 2.4, glare = 0.6,
		bloom = 0.9, bloomSize = 22, bloomThreshold = 1.4,
		gravity = 196.2,
	},
	ice = {
		brightness = 2.6, clock = 7.1,
		ambient = Color3.fromRGB(150, 180, 210), outdoor = Color3.fromRGB(190, 216, 238),
		fogColor = Color3.fromRGB(206, 232, 248), fogStart = 240, fogEnd = 2300,
		shiftTop = Color3.fromRGB(220, 244, 255), shiftBottom = Color3.fromRGB(120, 160, 200),
		atmColor = Color3.fromRGB(226, 244, 255), atmDecay = Color3.fromRGB(150, 186, 220),
		atmDensity = 0.38, haze = 1.9, glare = 0.3,
		bloom = 1.1, bloomSize = 26, bloomThreshold = 1.2,
		gravity = 196.2,
	},
	space = {
		brightness = 0.9, clock = 0.2,
		ambient = Color3.fromRGB(30, 30, 52), outdoor = Color3.fromRGB(46, 44, 72),
		fogColor = Color3.fromRGB(16, 14, 32), fogStart = 900, fogEnd = 5200,
		shiftTop = Color3.fromRGB(120, 110, 255), shiftBottom = Color3.fromRGB(10, 8, 24),
		atmColor = Color3.fromRGB(120, 130, 255), atmDecay = Color3.fromRGB(40, 40, 90),
		atmDensity = 0.2, haze = 0.4, glare = 0.2,
		bloom = 1.8, bloomSize = 32, bloomThreshold = 0.95,
		gravity = 196.2,
	},
}

local function applyTheme(mapId)
	local t = MapTheme[mapId] or MapTheme.lava
	Lighting.Brightness = t.brightness
	Lighting.ClockTime = t.clock
	Lighting.Ambient = t.ambient
	Lighting.OutdoorAmbient = t.outdoor
	Lighting.FogColor = t.fogColor
	Lighting.FogStart = t.fogStart
	Lighting.FogEnd = t.fogEnd
	Lighting.ColorShift_Top = t.shiftTop
	Lighting.ColorShift_Bottom = t.shiftBottom
	Workspace.Gravity = t.gravity

	local atm = Lighting:FindFirstChildOfClass("Atmosphere")
	if atm then
		atm.Color = t.atmColor
		atm.Decay = t.atmDecay
		atm.Density = t.atmDensity
		atm.Haze = t.haze
		atm.Glare = t.glare
	end
	local bloom = Lighting:FindFirstChild("Bloom") or Lighting:FindFirstChildOfClass("BloomEffect")
	if bloom then
		bloom.Intensity = t.bloom
		bloom.Size = t.bloomSize
		bloom.Threshold = t.bloomThreshold
	end
end

local mapsFolder = ServerStorage:WaitForChild("Maps")

local function clearTransient()
	for _, b in ipairs(bots) do
		if b.model and b.model.Parent then
			b.model:Destroy()
		end
	end
	bots = {}
	for userId, list in pairs(builtParts) do
		for _, part in ipairs(list) do
			if part and part.Parent then
				part:Destroy()
			end
		end
	end
	builtParts = {}
	for _, beacon in ipairs(Game.Beacons) do
		if beacon and beacon.Parent then
			beacon:Destroy()
		end
	end
	Game.Beacons = {}
end

local function unloadMap()
	clearTransient()
	local old = Workspace:FindFirstChild("CurrentMap")
	if old then
		old:Destroy()
	end
end

local function loadMap(mapId)
	unloadMap()
	local template = mapsFolder:FindFirstChild(mapId)
	if not template then
		template = mapsFolder:GetChildren()[1]
	end
	if not template then
		log("ОШИБКА: в ServerStorage.Maps нет карт!")
		return nil
	end
	local model = template:Clone()
	model.Name = "CurrentMap"
	model.Parent = Workspace
	Game.MapId = template.Name
	applyTheme(template.Name)
	return model
end

local function mapFolder(name)
	local model = Workspace:FindFirstChild("CurrentMap")
	if not model then
		return nil
	end
	return model:FindFirstChild(name)
end

local SPAWN_PREFIX = {
	SpawnPads = "DroneSpawn",
	SurvivorSpawns = "SurvivorSpawn",
	BotSpawns = "BotSpawn",
}

local function pickSpawn(folderName, fallback)
	local folder = mapFolder(folderName)
	local all, matched = {}, {}
	local prefix = SPAWN_PREFIX[folderName]
	if folder then
		for _, c in ipairs(folder:GetChildren()) do
			if c:IsA("BasePart") then
				table.insert(all, c)
				if prefix and string.sub(c.Name, 1, #prefix) == prefix then
					table.insert(matched, c)
				end
			end
		end
	end
	local list = (#matched > 0) and matched or all
	if #list == 0 then
		return CFrame.new(fallback or Vector3.new(0, 140, 0))
	end
	return list[math.random(1, #list)].CFrame
end

-- --------------------------------------------------------------------------- --
-- Дроны
-- --------------------------------------------------------------------------- --
local function destroyDrone(player, reason)
	local d = drones[player.UserId]
	if not d then
		return
	end
	drones[player.UserId] = nil
	local s = ps(player)
	s.role = nil
	if d.model and d.model.Parent then
		local pos = d.model:GetPivot().Position
		Rem.ExplosionFX:FireAllClients(pos, 22, d.cfg.Tint)
		d.model:Destroy()
	end
	Rem.SetDrone:FireClient(player, nil, nil)
	Rem.DroneLost:FireClient(player, reason or "destroyed")
	broadcast()
end

local function killDrone(player, reason)
	local d = drones[player.UserId]
	if not d or not d.alive then
		return
	end
	d.alive = false
	local s = ps(player)
	s.deaths += 1
	feed(string.format("%s уничтожен (%s)", player.DisplayName, reason or "урон"),
		Color3.fromRGB(255, 120, 110))
	local mode = Game.Mode
	local serial = Game.Serial
	destroyDrone(player, reason)

	-- в командных и свободных режимах дрон возвращается в бой
	if mode == "teams" or mode == "free" or mode == "survivors" then
		task.delay(Config.DroneRespawn, function()
			if Game.Serial ~= serial or Game.Phase ~= "Round" then
				return
			end
			local st = ps(player)
			if player.Parent and st.ready and st.role == nil and st.outRound ~= serial then
				spawnDrone(player, chooseDroneId(st))
			end
		end)
	end
end

local function droneHealth(player)
	local d = drones[player.UserId]
	return d and d.health or 0
end

local function damageDrone(player, amount, attackerName, attacker)
	local d = drones[player.UserId]
	if not d or not d.alive or amount <= 0 then
		return
	end
	d.health = math.max(0, d.health - amount)
	Rem.DamageFX:FireClient(player, amount, attackerName)
	if d.health <= 0 then
		if attacker and attacker ~= player then
			registerKill(attacker, player.DisplayName)
		end
		killDrone(player, attackerName or "сбит")
		return
	end
	if d.model then
		d.model:SetAttribute("Health", d.health)
		Rem.Health:FireClient(player, d.health, d.cfg.Health)
	end
end

local function prepareDroneModel(model)
	local primary = model.PrimaryPart
	if not primary then
		local bestVol = -1
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") then
				local v = d.Size.X * d.Size.Y * d.Size.Z
				if v > bestVol then
					bestVol = v
					primary = d
				end
			end
		end
		model.PrimaryPart = primary
	end
	if not primary then
		return nil
	end
	local parts = {}
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = true
			d.CanQuery = true
			d.CanTouch = true
			d.Massless = false
			table.insert(parts, d)
		end
	end
	for _, part in ipairs(parts) do
		if part ~= primary then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = primary
			weld.Part1 = part
			weld.Parent = part
		end
	end
	for _, part in ipairs(parts) do
		part.Anchored = false
	end
	-- камера дрона не должна ни с чем сталкиваться
	local camPart = findNamed(model, "camera")
	if camPart and camPart:IsA("BasePart") then
		camPart.CanCollide = false
		camPart.CanQuery = false
		camPart.CanTouch = false
	end
	return primary, parts
end

function spawnDrone(player, droneId)
	local cfg = Config.getDrone(droneId)
	local template = ServerStorage:FindFirstChild(cfg.Template)
	if not template then
		log("нет шаблона дрона", cfg.Template)
		return nil
	end
	destroyDrone(player, "switch")

	local model = template:Clone()
	model.Name = "Drone_" .. player.Name
	model:SetAttribute("IsDrone", true)
	model:SetAttribute("OwnerUserId", player.UserId)
	model:SetAttribute("OwnerName", player.DisplayName)
	model:SetAttribute("DroneId", cfg.Id)
	model:SetAttribute("Health", cfg.Health)
	model:SetAttribute("MaxHealth", cfg.Health)

	local primary = prepareDroneModel(model)
	if not primary then
		model:Destroy()
		return nil
	end
	model.Parent = Workspace
	local spawnCF = pickSpawn("SpawnPads", Vector3.new(0, 150, 0)) + Vector3.new(0, 7, 0)
	model:PivotTo(spawnCF)

	-- сетевые права: физику дрона считает клиент пилота
	local ok, err = pcall(function()
		primary:SetNetworkOwner(player)
	end)
	if not ok then
		log("SetNetworkOwner не сработал:", err)
	end

	local gunNames = { "minigan one", "minigan two" }
	local guns = {}
	for _, n in ipairs(gunNames) do
		local g = findNamed(model, n)
		if g and g:IsA("BasePart") then
			table.insert(guns, g)
		end
	end
	if #guns == 0 then
		guns = { primary }
	end

	drones[player.UserId] = {
		model = model,
		primary = primary,
		cfg = cfg,
		health = cfg.Health,
		alive = true,
		guns = guns,
		spawnedAt = now(),
	}
	local s = ps(player)
	s.role = "drone"
	s.droneId = cfg.Id
	Rem.SetDrone:FireClient(player, model, cfg.Id, cfg.Health)
	Rem.Health:FireClient(player, cfg.Health, cfg.Health)
	broadcast()
	return model
end

-- --------------------------------------------------------------------------- --
-- Выжившие
-- --------------------------------------------------------------------------- --
local guardSpawn = Workspace:FindFirstChild("GuardSpawn")
if not guardSpawn then
	guardSpawn = Instance.new("SpawnLocation")
	guardSpawn.Name = "GuardSpawn"
	guardSpawn.Size = Vector3.new(6, 1, 6)
	guardSpawn.Transparency = 1
	guardSpawn.CanCollide = false
	guardSpawn.Anchored = true
	guardSpawn.CFrame = CFrame.new(0, 300, 0)
	guardSpawn.Neutral = true
	guardSpawn.Parent = Workspace
end

local function releaseSurvivor(player)
	local s = survivors[player.UserId]
	survivors[player.UserId] = nil
	if s and s.character and s.character.Parent then
		s.character:Destroy()
	end
end

local function spawnSurvivor(player, spawnCF)
	destroyDrone(player, "switch")
	local s = ps(player)
	s.role = "survivor"
	s.ammo = INF.Rifle.Magazine
	s.reloading = false

	local old = player.Character
	if old then
		old:Destroy()
	end
	pcall(function()
		player.Character = nil
	end)

	local ok, err = pcall(function()
		player:LoadCharacter()
	end)
	if not ok then
		log("LoadCharacter:", err)
	end
	local char = player.Character
	local waited = 0
	while not char and waited < 3 do
		task.wait(0.1)
		waited += 0.1
		char = player.Character
	end
	if not char then
		return nil
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not hum then
		return nil
	end

	hum.MaxHealth = INF.Health
	hum.Health = INF.Health
	hum.WalkSpeed = INF.WalkSpeed
	hum.JumpPower = INF.JumpPower
	hum.UseJumpPower = true
	hum.BreakJointsOnDeath = true
	char:PivotTo(spawnCF + Vector3.new(0, 4, 0))

	char:SetAttribute("Survivor", true)
	char:SetAttribute("OwnerUserId", player.UserId)

	survivors[player.UserId] = { character = char, humanoid = hum }
	Rem.Health:FireClient(player, hum.Health, hum.MaxHealth)

	hum.Died:Connect(function()
		local st = ps(player)
		st.deaths += 1
		st.outRound = Game.Serial
		feed(string.format("%s выбыл", player.DisplayName), Color3.fromRGB(255, 150, 150))
		survivors[player.UserId] = nil
		st.role = "spectator"
		Rem.DroneLost:FireClient(player, "dead")
		broadcast()
		task.delay(3, function()
			if player.Parent and player.Character then
				player.Character:Destroy()
				pcall(function()
					player.Character = nil
				end)
			end
		end)
	end)

	hum.HealthChanged:Connect(function(h)
		Rem.Health:FireClient(player, h, hum.MaxHealth)
	end)

	broadcast()
	return char
end

-- --------------------------------------------------------------------------- --
-- Урон: единая точка входа
-- --------------------------------------------------------------------------- --
local W = Config.Weapons
local BUILD = Config.Building

Rem.Reload = newRemote("Reload")

local damageDroneById  -- forward

function registerKill(attacker, victimName)
	if not attacker then
		return
	end
	local s = ps(attacker)
	s.kills += 1
	s.score += 100
	if s.team then
		Game.TeamScore = Game.TeamScore or {}
		Game.TeamScore[s.team] = (Game.TeamScore[s.team] or 0) + 1
	end
	feed(string.format("%s ⟶ %s", attacker.DisplayName, victimName),
		Color3.fromRGB(255, 236, 180))
end

local function damageBuiltPart(part, amount, attacker)
	local hp = part:GetAttribute("Health") or BUILD.Health
	hp -= amount
	part:SetAttribute("Health", hp)
	if hp <= 0 then
		local owner = part:GetAttribute("OwnerUserId")
		Rem.ExplosionFX:FireAllClients(part.Position, 6, Color3.fromRGB(180, 140, 90))
		part:Destroy()
		if owner then
			local list = builtParts[owner]
			if list then
				for i = #list, 1, -1 do
					if list[i] == part or not list[i].Parent then
						table.remove(list, i)
					end
				end
			end
		end
	else
		part.Color = Color3.fromRGB(120, 80, 50)
	end
end

local function damageBot(bot, amount, attacker)
	bot.health -= amount
	if bot.health <= 0 then
		local pos = bot.model and bot.model:GetPivot().Position or Vector3.new()
		Rem.ExplosionFX:FireAllClients(pos, 14, Color3.fromRGB(255, 170, 90))
		if bot.model then
			bot.model:Destroy()
		end
		bot.dead = true
		for i = #bots, 1, -1 do
			if bots[i] == bot then
				table.remove(bots, i)
			end
		end
		local s = bot.killedBy and ps(bot.killedBy)
		if s then
			s.kills += 1
			s.score += Config.Bots[bot.kind == "flyer" and "Flyer" or "Walker"].Score
			if s.team and Game.TeamScore then
				Game.TeamScore[s.team] = (Game.TeamScore[s.team] or 0) + 1
			end
			if bot.killedBy then
				feed(bot.killedBy.DisplayName .. " сбил " ..
					(bot.kind == "flyer" and "дрона-бота" or "бота"), Color3.fromRGB(255, 236, 180))
			end
		end
	else
		bot.killedBy = attacker
	end
end

-- наносит урон тому, во что попал луч; возвращает true, если кто-то получил урон
local function applyHit(hit, amount, attacker, origin)
	if not hit then
		return false
	end
	local part = hit
	if not part:IsA("BasePart") then
		part = hit.Parent
	end
	if not part or not part:IsA("BasePart") then
		return false
	end
	if part:GetAttribute("Built") then
		damageBuiltPart(part, amount, attacker)
		return true
	end
	local model = part:FindFirstAncestorOfClass("Model")
	local char = part:FindFirstAncestorOfClass("Model")
	if char then
		local hum = char:FindFirstChildOfClass("Humanoid")
		if hum then
			-- в прятках дрон не «ранит», а «находит»: одного попадания достаточно
			if Game.Mode == "hide" and attacker and drones[attacker.UserId] then
				hum.Health = 0
				feed(attacker.DisplayName .. " нашёл " .. char.Name, Color3.fromRGB(255, 200, 120))
				Rem.Hitmark:FireClient(attacker)
				return true
			end
			hum:TakeDamage(amount)
			if attacker then
				Rem.Hitmark:FireClient(attacker)
				if hum.Health <= 0 then
					registerKill(attacker, char.Name)
				end
			end
			return true
		end
	end
	if model and model:GetAttribute("IsDrone") then
		local ownerId = model:GetAttribute("OwnerUserId")
		local owner = ownerId and playerByUserId(ownerId)
		if owner and owner ~= attacker then
			local victimCfg = Config.getDrone(model:GetAttribute("DroneId"))
			damageDrone(owner, amount / (victimCfg.Armor or 1),
				attacker and attacker.DisplayName or "дрон", attacker)
			if attacker then
				Rem.Hitmark:FireClient(attacker)
			end
			return true
		elseif owner == attacker then
			return false
		end
		return false
	end
	if model and model:GetAttribute("Bot") then
		for _, b in ipairs(bots) do
			if b.model == model then
				damageBot(b, amount, attacker)
				if attacker then
					Rem.Hitmark:FireClient(attacker)
				end
				return true
			end
		end
	end
	return true
end

local function filteredRaycast(origin, dir, dist, ignore)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclusions = {}
	for _, inst in ipairs(ignore or {}) do
		if inst then
			table.insert(exclusions, inst)
		end
	end
	local fx = Workspace:FindFirstChild("ClientFX")
	if fx then
		table.insert(exclusions, fx)
	end
	params.FilterDescendantsInstances = exclusions
	return Workspace:Raycast(origin, dir * dist, params)
end

-- --------------------------------------------------------------------------- --
-- ИИ-боты
-- --------------------------------------------------------------------------- --
local function buildBotModel(kind)
	local model = Instance.new("Model")
	model.Name = kind == "flyer" and "FlyerBot" or "WalkerBot"
	model:SetAttribute("Bot", true)

	local hullColor = kind == "flyer" and Color3.fromRGB(90, 96, 120) or Color3.fromRGB(104, 100, 96)
	local core = Instance.new("Part")
	core.Name = "Core"
	core.Size = kind == "flyer" and Vector3.new(9, 3.4, 12) or Vector3.new(6, 7, 6)
	core.Color = hullColor
	core.Material = Enum.Material.Metal
	core.Anchored = true
	core.CanCollide = false
	core.Parent = model

	local eye = Instance.new("Part")
	eye.Name = "Eye"
	eye.Size = Vector3.new(2.2, 2.2, 2.2)
	eye.Shape = Enum.PartType.Ball
	eye.Color = Color3.fromRGB(255, 90, 70)
	eye.Material = Enum.Material.Neon
	eye.Anchored = true
	eye.CanCollide = false
	eye.CFrame = core.CFrame * CFrame.new(0, 0, -core.Size.Z / 2)
	eye.Parent = model
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 80, 60)
	light.Brightness = 3
	light.Range = 26
	light.Parent = eye

	local wings = {}
	if kind == "flyer" then
		for i = 1, 2 do
			local sign = i == 1 and -1 or 1
			local wing = Instance.new("Part")
			wing.Name = "Wing"
			wing.Size = Vector3.new(16, 0.8, 5)
			wing.Color = hullColor
			wing.Material = Enum.Material.DiamondPlate
			wing.Anchored = true
			wing.CanCollide = false
			wing.CFrame = core.CFrame * CFrame.new(sign * 11, 0, 0)
			wing.Parent = model
			local tip = Instance.new("Part")
			tip.Name = "Tip"
			tip.Size = Vector3.new(1.4, 1.4, 1.4)
			tip.Color = Color3.fromRGB(120, 220, 255)
			tip.Material = Enum.Material.Neon
			tip.Anchored = true
			tip.CanCollide = false
			tip.CFrame = wing.CFrame * CFrame.new(sign * 7, 0, 0)
			tip.Parent = model
			table.insert(wings, wing)
			table.insert(wings, tip)
		end
	end

	local allParts = { core, eye }
	for _, w in ipairs(wings) do
		table.insert(allParts, w)
	end
	for _, part in ipairs(allParts) do
		if part ~= core then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = core
			weld.Part1 = part
			weld.Parent = part
		end
	end
	for _, part in ipairs(allParts) do
		part.Anchored = false
	end
	return model, core
end

local function botTarget(bot)
	local best, bestDist = nil, math.huge
	local pos = bot.model and bot.model:GetPivot().Position
	if not pos then
		return nil
	end
	for _, p in ipairs(Players:GetPlayers()) do
		local s = ps(p)
		if bot.team and s.team == bot.team then
			continue
		end
		local target = nil
		local d = drones[p.UserId]
		if d and d.alive and d.model then
			target = d.model:GetPivot().Position
		elseif survivors[p.UserId] and survivors[p.UserId].character then
			target = survivors[p.UserId].character:GetPivot().Position
		end
		if target then
			local dist = (target - pos).Magnitude
			if dist < bestDist then
				best, bestDist = p, dist
			end
		end
	end
	if best then
		local d = drones[best.UserId]
		if d and d.model then
			return best, d.model:GetPivot().Position
		end
		local sv = survivors[best.UserId]
		if sv and sv.character then
			return best, sv.character:GetPivot().Position
		end
	end
	return nil
end

local function spawnBot(kind, spawnCF)
	local cfg = kind == "flyer" and Config.Bots.Flyer or Config.Bots.Walker
	local model, core = buildBotModel(kind)
	model:PivotTo(spawnCF)
	model.Parent = Workspace

	local att = Instance.new("Attachment")
	att.Name = "BotRoot"
	att.Parent = core

	local align = Instance.new("AlignOrientation")
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = att
	align.RigidityEnabled = true
	align.MaxTorque = 300000
	align.Parent = core

	local pos = Instance.new("AlignPosition")
	pos.Mode = Enum.PositionAlignmentMode.OneAttachment
	pos.Attachment0 = att
	pos.ApplyAtCenterOfMass = true
	pos.MaxForce = 900000
	pos.Responsiveness = 28
	pos.MaxVelocity = cfg.Speed
	pos.RigidityEnabled = false
	pos.Position = spawnCF.Position
	pos.Parent = core

	local bot = {
		kind = kind,
		model = model,
		core = core,
		align = align,
		pos = pos,
		health = cfg.Health,
		nextShot = now() + math.random(10, 30) / 10,
		deathAt = now() + 240,
		cfg = cfg,
	}
	table.insert(bots, bot)
	return bot
end

local function updateBots(dt)
	for i = #bots, 1, -1 do
		local bot = bots[i]
		if bot.dead or not bot.model or not bot.model.Parent then
			table.remove(bots, i)
		else
			local target, targetPos = botTarget(bot)
			local myPos = bot.model:GetPivot().Position
			local hover = bot.kind == "flyer" and 18 or 5
			if target and targetPos then
				local dir = (targetPos - myPos)
				local dist = dir.Magnitude
				local want = targetPos + Vector3.new(0, hover, 0)
				if dist > (bot.kind == "flyer" and 60 or 26) then
					bot.pos.Position = want
					bot.align.CFrame = CFrame.lookAt(myPos, Vector3.new(targetPos.X, myPos.Y, targetPos.Z))
				else
					bot.pos.Position = myPos
					bot.align.CFrame = CFrame.lookAt(myPos, targetPos)
				end
				-- стрельба
				if now() >= bot.nextShot and dist <= bot.cfg.Range then
					bot.nextShot = now() + bot.cfg.FireInterval * (0.8 + math.random() * 0.6)
					local origin = myPos
					local aim = (targetPos - origin).Unit
					local spread = Vector3.new(math.random() - 0.5, math.random() - 0.5,
						math.random() - 0.5) * 0.06
					local dir2 = (aim + spread).Unit
					local hit = filteredRaycast(origin, dir2, bot.cfg.Range, { bot.model })
					local endpoint = hit and hit.Position or (origin + dir2 * bot.cfg.Range)
					Rem.FireFX:FireAllClients(origin, endpoint, Color3.fromRGB(255, 110, 90))
					if hit then
						local victim = nil
						local ownerId = nil
						local m = hit.Instance:FindFirstAncestorOfClass("Model")
						if m then
							ownerId = m:GetAttribute("OwnerUserId")
						end
						if ownerId then
							victim = playerByUserId(ownerId)
						end
						if victim then
							local s = ps(victim)
							if droneHealth(victim) > 0 then
								damageDrone(victim, bot.cfg.Damage, "бот")
							elseif survivors[victim.UserId] then
								local sv = survivors[victim.UserId]
								sv.humanoid:TakeDamage(bot.cfg.Damage)
								Rem.DamageFX:FireClient(victim, bot.cfg.Damage, "бот")
							end
							if s and s.role == "drone" then
								-- попадание по нам: тряска/вспышка уже ушли через DamageFX
							end
						end
					end
				end
			else
				bot.pos.Position = myPos + Vector3.new(0, math.sin(now() * 0.7 + i) * 3, 0)
			end
			-- таймаут: боты не живут вечно
			if now() > bot.deathAt then
				if bot.model then
					bot.model:Destroy()
				end
				bot.dead = true
				table.remove(bots, i)
			end
		end
	end
end

-- --------------------------------------------------------------------------- --
-- Оружие дрона: миниган и бомба
-- --------------------------------------------------------------------------- --
Rem.Fire.OnServerEvent:Connect(function(player, dir)
	local d = drones[player.UserId]
	if not d or not d.alive or not d.model or not d.primary.Parent then
		return
	end
	if typeof(dir) ~= "Vector3" or dir.Magnitude < 0.01 then
		return
	end
	local s = ps(player)
	if now() - s.lastFire < W.Minigun.Interval * 0.9 then
		return
	end
	s.lastFire = now()

	local origin = d.primary.Position
	local aim = dir.Unit
	local spread = W.Minigun.Spread / 57.3
	local jitter = Vector3.new(math.random() - 0.5, math.random() - 0.5,
		math.random() - 0.5) * spread
	local rayDir = (aim + jitter).Unit
	local hit = filteredRaycast(origin, rayDir, W.Minigun.Range, { d.model })
	local endpoint = hit and hit.Position or (origin + rayDir * W.Minigun.Range)
	Rem.FireFX:FireAllClients(origin, endpoint, W.Minigun.Tracer)
	if hit then
		applyHit(hit.Instance, W.Minigun.Damage, player, origin)
	end
end)

local function explodeAt(position, damage, radius, attacker)
	Rem.ExplosionFX:FireAllClients(position, radius, Color3.fromRGB(255, 160, 70))
	for _, p in ipairs(Players:GetPlayers()) do
		local d = drones[p.UserId]
		if d and d.alive and d.model then
			local dist = (d.model:GetPivot().Position - position).Magnitude
			if dist <= radius and p ~= attacker then
				damageDrone(p, damage * (1 - dist / radius), "бомба")
			end
		end
		local sv = survivors[p.UserId]
		if sv and sv.character then
			local dist = (sv.character:GetPivot().Position - position).Magnitude
			if dist <= radius then
				sv.humanoid:TakeDamage(Config.Infantry.DroneBombDamageToSurvivor * (1 - dist / radius))
				Rem.DamageFX:FireClient(p, 40, "бомба")
			end
		end
	end
	for i = #bots, 1, -1 do
		local bot = bots[i]
		if bot.model and bot.model.Parent then
			local dist = (bot.model:GetPivot().Position - position).Magnitude
			if dist <= radius then
				damageBot(bot, damage, attacker)
			end
		end
	end
	local model = Workspace:FindFirstChild("CurrentMap")
	if model then
		local geo = model:FindFirstChild("Geometry")
		if geo then
			for _, part in ipairs(geo:GetDescendants()) do
				if part:IsA("BasePart") and part:GetAttribute("Built") then
					local dist = (part.Position - position).Magnitude
					if dist <= radius then
						damageBuiltPart(part, damage, attacker)
					end
				end
			end
		end
	end
	for _, list in pairs(builtParts) do
		for i = #list, 1, -1 do
			local part = list[i]
			if part.Parent and (part.Position - position).Magnitude <= radius then
				damageBuiltPart(part, damage, attacker)
			end
		end
	end
end

Rem.Bomb.OnServerEvent:Connect(function(player)
	local d = drones[player.UserId]
	if not d or not d.alive or not d.cfg.Bomb or not d.model then
		return
	end
	local s = ps(player)
	if s.lastBomb and now() - s.lastBomb < W.Bomb.Cooldown then
		return
	end
	s.lastBomb = now()

	local startPos = d.primary.Position + Vector3.new(0, -6, 0)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { d.model }
	local down = Workspace:Raycast(startPos, Vector3.new(0, -600, 0), params)
	local impact = down and down.Position or (startPos - Vector3.new(0, 400, 0))

	local bomb = Instance.new("Part")
	bomb.Name = "Bomb"
	bomb.Shape = Enum.PartType.Ball
	bomb.Size = Vector3.new(3, 3, 3)
	bomb.Color = d.cfg.Tint
	bomb.Material = Enum.Material.Neon
	bomb.Anchored = true
	bomb.CanCollide = false
	bomb.CFrame = CFrame.new(startPos)
	bomb.Parent = Workspace
	Rem.BombFX:FireAllClients(startPos)

	task.spawn(function()
		local dist = (impact - startPos).Magnitude
		local duration = math.clamp(dist / 220, 0.25, 2.6)
		local t = 0
		while t < duration and bomb.Parent do
			t += task.wait()
			bomb.CFrame = CFrame.new(startPos:Lerp(impact, math.clamp(t / duration, 0, 1)))
		end
		if bomb.Parent then
			bomb:Destroy()
		end
		explodeAt(impact, W.Bomb.Damage, W.Bomb.Radius, player)
	end)
end)

-- --------------------------------------------------------------------------- --
-- Оружие выживших
-- --------------------------------------------------------------------------- --
local function survivorRoot(player)
	local sv = survivors[player.UserId]
	if not sv or not sv.character or not sv.humanoid or sv.humanoid.Health <= 0 then
		return nil
	end
	return sv.humanoid.RootPart, sv.humanoid
end

Rem.GunFire.OnServerEvent:Connect(function(player, dir)
	local root, hum = survivorRoot(player)
	if not root or typeof(dir) ~= "Vector3" then
		return
	end
	local s = ps(player)
	if s.reloading or now() - s.lastFire < INF.Rifle.Interval * 0.9 then
		return
	end
	if (s.ammo or 0) <= 0 then
		return
	end
	s.lastFire = now()
	s.ammo -= 1
	if s.ammo <= 0 then
		s.reloading = true
		task.delay(INF.Rifle.Reload, function()
			s.ammo = INF.Rifle.Magazine
			s.reloading = false
			broadcast()
		end)
	end

	local origin = root.Position + Vector3.new(0, 1.6, 0)
	local spread = INF.Rifle.Spread / 57.3
	local aim = dir.Unit
	local jitter = Vector3.new(math.random() - 0.5, math.random() - 0.5,
		math.random() - 0.5) * spread
	local rayDir = (aim + jitter).Unit
	local hit = filteredRaycast(origin, rayDir, INF.Rifle.Range, { player.Character })
	local endpoint = hit and hit.Position or (origin + rayDir * INF.Rifle.Range)
	Rem.FireFX:FireAllClients(origin, endpoint, Color3.fromRGB(255, 240, 190))
	if hit then
		applyHit(hit.Instance, INF.Rifle.Damage * INF.SurvivorDamageToDrone, player, origin)
	end
end)

Rem.Reload.OnServerEvent:Connect(function(player)
	local s = ps(player)
	if s.reloading then
		return
	end
	s.reloading = true
	task.delay(INF.Rifle.Reload, function()
		s.ammo = INF.Rifle.Magazine
		s.reloading = false
		broadcast()
	end)
end)

Rem.Melee.OnServerEvent:Connect(function(player)
	local root, hum = survivorRoot(player)
	if not root then
		return
	end
	local s = ps(player)
	if now() - s.lastMelee < INF.Melee.Cooldown then
		return
	end
	s.lastMelee = now()
	local origin = root.Position + Vector3.new(0, 1.2, 0)
	local dir = root.CFrame.LookVector
	Rem.MeleeFX:FireAllClients(player.UserId, origin, dir)
	local hit = filteredRaycast(origin, dir, INF.Melee.Range, { player.Character })
	if hit then
		applyHit(hit.Instance, INF.Melee.Damage, player, origin)
	end
end)

-- --------------------------------------------------------------------------- --
-- Строительство из досок
-- --------------------------------------------------------------------------- --
Rem.Build.OnServerEvent:Connect(function(player, plankId, targetCF)
	local root, hum = survivorRoot(player)
	if not root or typeof(targetCF) ~= "CFrame" then
		return
	end
	local s = ps(player)
	if now() - s.lastBuild < BUILD.Cooldown then
		return
	end
	if (targetCF.Position - root.Position).Magnitude > BUILD.Range then
		return
	end
	if targetCF.Position.Y < Config.KillY + 10 then
		return
	end
	s.lastBuild = now()

	local plank = Config.getPlank(tostring(plankId))
	local list = builtParts[player.UserId]
	if not list then
		list = {}
		builtParts[player.UserId] = list
	end
	if #list >= BUILD.MaxParts then
		local oldest = table.remove(list, 1)
		if oldest and oldest.Parent then
			oldest:Destroy()
		end
	end

	local part = Instance.new("Part")
	part.Name = "Plank"
	part.Size = plank.Size
	part.CFrame = targetCF
	part.Anchored = true
	part.Color = plank.Color
	part.Material = BUILD.Material
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part:SetAttribute("Built", true)
	part:SetAttribute("Health", BUILD.Health)
	part:SetAttribute("OwnerUserId", player.UserId)
	part.Parent = Workspace
	table.insert(list, part)
	Rem.Placed:FireAllClients(part, plank.Color)
end)

Rem.Crash.OnServerEvent:Connect(function(player, amount)
	if typeof(amount) ~= "number" then
		return
	end
	local d = drones[player.UserId]
	if not d or not d.alive then
		return
	end
	damageDrone(player, math.clamp(amount, 0, 40), "crash")
end)

Rem.RequestDrone.OnServerEvent:Connect(function(player, droneId)
	if typeof(droneId) ~= "string" then
		return
	end
	local s = ps(player)
	if s.role ~= "drone" then
		return
	end
	for _, d in ipairs(Config.Drones) do
		if d.Id == droneId then
			spawnDrone(player, droneId)
			return
		end
	end
end)

-- --------------------------------------------------------------------------- --
-- Маяки для соло-пряток
-- --------------------------------------------------------------------------- --
local function spawnBeacons(count)
	for i = 1, count do
		local cf = pickSpawn("BotSpawns", Vector3.new(0, 30, 0))
		local beacon = Instance.new("Part")
		beacon.Name = "Beacon" .. i
		beacon.Shape = Enum.PartType.Ball
		beacon.Size = Vector3.new(6, 6, 6)
		beacon.Color = Color3.fromRGB(150, 255, 190)
		beacon.Material = Enum.Material.Neon
		beacon.Anchored = true
		beacon.CanCollide = false
		beacon.CanQuery = false
		beacon.CFrame = cf + Vector3.new(0, 6, 0)
		local light = Instance.new("PointLight")
		light.Color = Color3.fromRGB(150, 255, 190)
		light.Brightness = 4
		light.Range = 40
		light.Parent = beacon
		beacon.Parent = Workspace
		table.insert(Game.Beacons, beacon)
	end
end

-- --------------------------------------------------------------------------- --
-- Единый Heartbeat: маяки, боты, бездна
-- --------------------------------------------------------------------------- --
local botTimer = 0

local function topUpBots(dt)
	botTimer += dt
	if botTimer < 5 or Game.Phase ~= "Round" then
		return
	end
	botTimer = 0
	local mode = Game.Mode
	if #bots >= Config.Bots.MaxAlive then
		return
	end
	if mode == "teams" then
		local red, blue = teamAlive("red"), teamAlive("blue")
		if red < blue then
			spawnBotAt("flyer", "red")
		elseif blue < red then
			spawnBotAt("flyer", "blue")
		elseif #bots < 2 then
			spawnBotAt("flyer", (math.random(2) == 1) and "red" or "blue")
		end
	elseif mode == "free" then
		if #bots < 4 then
			spawnBotAt("flyer", nil)
		end
	elseif mode == "survivors" then
		local target = math.max(3, aliveSurvivors() + 2)
		if #bots < target then
			spawnBotAt((math.random(2) == 1) and "walker" or "flyer", nil)
		end
	end
end

RunService.Heartbeat:Connect(function(dt)
	updateBots(dt)
	topUpBots(dt)

	-- бездна и лава
	for userId, d in pairs(drones) do
		if d.alive and d.primary and d.primary.Parent and d.primary.Position.Y < Config.KillY then
			local p = playerByUserId(userId)
			if p then
				killDrone(p, "бездна")
			end
		end
	end

	-- сбор маяков
	if #Game.Beacons > 0 then
		for i = #Game.Beacons, 1, -1 do
			local beacon = Game.Beacons[i]
			if not beacon.Parent then
				table.remove(Game.Beacons, i)
			else
				for userId, d in pairs(drones) do
					if d.alive and d.primary and (d.primary.Position - beacon.Position).Magnitude < Config.BeaconRadius then
						local p = playerByUserId(userId)
						beacon:Destroy()
						table.remove(Game.Beacons, i)
						Rem.ExplosionFX:FireAllClients(beacon.Position, 10, Color3.fromRGB(150, 255, 190))
						if p then
							feed(string.format("%s нашёл маяк! Осталось: %d", p.DisplayName,
								#Game.Beacons), Color3.fromRGB(150, 255, 190))
						end
						break
					end
				end
			end
		end
	end
end)

-- --------------------------------------------------------------------------- --
-- Подсчёт живых
-- --------------------------------------------------------------------------- --
function aliveDrones()
	local n = 0
	for _, d in pairs(drones) do
		if d.alive then
			n += 1
		end
	end
	return n
end

function aliveSurvivors()
	local n = 0
	for _, sv in pairs(survivors) do
		if sv.character and sv.character.Parent and sv.humanoid and sv.humanoid.Health > 0 then
			n += 1
		end
	end
	return n
end

function teamAlive(team)
	local n = 0
	for _, p in ipairs(Players:GetPlayers()) do
		local s = ps(p)
		if s.ready and s.team == team then
			local d = drones[p.UserId]
			if d and d.alive then
				n += 1
			end
		end
	end
	return n
end

function chooseDroneId(s)
	if s and s.droneId then
		for _, d in ipairs(Config.Drones) do
			if d.Id == s.droneId then
				return d.Id
			end
		end
	end
	return Config.Drones[math.random(1, #Config.Drones)].Id
end

-- --------------------------------------------------------------------------- --
-- Раздача ролей
-- --------------------------------------------------------------------------- --
local function assignRoles(mode, list)
	for _, p in ipairs(list) do
		local s = ps(p)
		s.role = nil
		s.team = nil
		s.outRound = nil
	end
	if #list == 0 then
		return
	end

	if mode.Id == "free" then
		for _, p in ipairs(list) do
			ps(p).role = "drone"
		end
	elseif mode.Id == "hide" then
		local droneCount = math.max(1, math.floor(#list / 6))
		if #list >= 2 then
			droneCount = math.max(1, droneCount)
		end
		local sorted = table.clone(list)
		table.sort(sorted, function(a, b)
			local aw = ps(a).rolePref == "drone" and 0 or 1
			local bw = ps(b).rolePref == "drone" and 0 or 1
			return aw < bw
		end)
		for i, p in ipairs(sorted) do
			ps(p).role = (i <= droneCount) and "drone" or "survivor"
		end
	elseif mode.Id == "teams" then
		for i, p in ipairs(list) do
			local s = ps(p)
			s.role = "drone"
			s.team = (i % 2 == 1) and "red" or "blue"
		end
	elseif mode.Id == "survivors" then
		local droneCount = 0
		for _, p in ipairs(list) do
			if ps(p).rolePref == "drone" then
				droneCount += 1
			end
		end
		if #list >= 2 and droneCount == 0 then
			droneCount = 1
		elseif #list == 1 then
			droneCount = (ps(list[1]).rolePref == "survivor") and 0 or 1
		end
		local assigned = 0
		-- сначала тем, кто просил дрона
		for _, p in ipairs(list) do
			if assigned < droneCount and ps(p).rolePref == "drone" then
				ps(p).role = "drone"
				assigned += 1
			end
		end
		for _, p in ipairs(list) do
			local s = ps(p)
			if not s.role then
				if assigned < droneCount then
					s.role = "drone"
					assigned += 1
				else
					s.role = "survivor"
				end
			end
		end
	end

	-- наблюдатели для невыбравших
	for _, p in ipairs(list) do
		local s = ps(p)
		if not s.role then
			s.role = "spectator"
		end
	end
end

-- --------------------------------------------------------------------------- --
-- Спавн всех и наполнение ботами
-- --------------------------------------------------------------------------- --
local function spawnEveryone(mode)
	for _, p in ipairs(Players:GetPlayers()) do
		local s = ps(p)
		if s.ready then
			if s.role == "drone" then
				spawnDrone(p, chooseDroneId(s))
			elseif s.role == "survivor" then
				spawnSurvivor(p, pickSpawn("SurvivorSpawns", Vector3.new(0, 10, 0)))
			else
				s.role = "spectator"
				destroyDrone(p, "spectator")
				releaseSurvivor(p)
			end
		else
			s.role = "spectator"
		end
	end
end

function spawnBotAt(kind, team)
	local cf = pickSpawn("BotSpawns", Vector3.new(0, 40, 0))
	local bot = spawnBot(kind, cf + Vector3.new(0, 12, 0))
	bot.team = team
	return bot
end

local function fillBots(mode)
	local players = readyPlayers()
	local n = #players
	if mode.Id == "hide" then
		if n <= 1 then
			spawnBeacons(Config.BeaconCount)
			announce("ОДИН ДРОН И " .. Config.BeaconCount .. " МАЯКОВ: НАЙДИ ВСЕ", 5)
		end
	elseif mode.Id == "teams" then
		local red, blue = teamAlive("red"), teamAlive("blue")
		local guard = 0
		while red ~= blue and guard < 6 do
			guard += 1
			if red < blue then
				spawnBotAt("flyer", "red")
				red += 1
			else
				spawnBotAt("flyer", "blue")
				blue += 1
			end
		end
	elseif mode.Id == "free" then
		for i = 1, math.clamp(3 - n, 1, 3) do
			spawnBotAt("flyer", nil)
		end
	elseif mode.Id == "survivors" then
		local dcount = aliveDrones()
		if dcount == 0 then
			for i = 1, 2 do
				spawnBotAt("flyer", nil)
			end
		end
		local walkers = math.max(2, aliveSurvivors())
		for i = 1, walkers do
			spawnBotAt("walker", nil)
		end
	end
end

-- --------------------------------------------------------------------------- --
-- Условия победы
-- --------------------------------------------------------------------------- --
local function checkWin(mode)
	if mode.Id == "hide" then
		local hiders = aliveSurvivors()
		local beaconsLeft = #Game.Beacons
		local droneAlive = aliveDrones()
		if droneAlive == 0 and (hiders > 0 or beaconsLeft > 0) then
			return true, "ПРЯЧУЩИЕСЯ ВЫЖИЛИ"
		end
		if hiders == 0 and beaconsLeft == 0 then
			return true, "ДРОНЫ НАШЛИ ВСЕХ"
		end
	elseif mode.Id == "teams" then
		local red = (Game.TeamScore and Game.TeamScore.red) or 0
		local blue = (Game.TeamScore and Game.TeamScore.blue) or 0
		if red >= R.WinScore then
			return true, "КРАСНЫЕ ПОБЕДИЛИ"
		end
		if blue >= R.WinScore then
			return true, "СИНИЕ ПОБЕДИЛИ"
		end
	elseif mode.Id == "survivors" then
		local hiders = aliveSurvivors()
		local dronesAlive = aliveDrones()
		if hiders == 0 and dronesAlive > 0 then
			return true, "ДРОНЫ ВЫИГРАЛИ"
		end
		if dronesAlive == 0 and hiders > 0 then
			return true, "ВЫЖИВШИЕ ОТБИЛИСЬ"
		end
	end
	return false
end

local function timeUpResult(mode)
	if mode.Id == "hide" then
		if #Game.Beacons > 0 then
			return "ПРЯЧУЩИЕСЯ ВЫЖИЛИ"
		end
		return "ВРЕМЯ ВЫШЛО"
	elseif mode.Id == "teams" then
		local red = (Game.TeamScore and Game.TeamScore.red) or 0
		local blue = (Game.TeamScore and Game.TeamScore.blue) or 0
		if red > blue then
			return "КРАСНЫЕ ПОБЕДИЛИ"
		elseif blue > red then
			return "СИНИЕ ПОБЕДИЛИ"
		end
		return "НИЧЬЯ"
	elseif mode.Id == "survivors" then
		if aliveSurvivors() > 0 then
			return "ВЫЖИВШИЕ ПОБЕДИЛИ"
		end
		return "ДРОНЫ ВЫИГРАЛИ"
	end
	return "ЗАЕЗД ОКОНЧЕН"
end

-- --------------------------------------------------------------------------- --
-- Фазы игры
-- --------------------------------------------------------------------------- --
local startVote  -- forward

local function finishRound(text, serial)
	if Game.Serial ~= serial then
		return
	end
	Game.Winner = text
	Game.ResultText = text
	Game.Phase = "End"
	Game.TimeLeft = R.EndDelay
	broadcast()
	announce(text, 5)
	feed("ИТОГ: " .. text, Color3.fromRGB(255, 236, 180))

	-- всем показать результат, затем -- новая карта и голосование
	task.delay(R.EndDelay, function()
		if Game.Serial == serial then
			startVote()
		end
	end)
end

local function startRound(modeId, mapId)
	local ready = readyPlayers()
	if #ready == 0 then
		Game.Phase = "Vote"
		Game.TimeLeft = R.VoteTime
		Game.Votes = {}
		broadcast()
		return
	end

	local mode = GameData.getMode(modeId)
	Game.Mode = mode.Id
	Game.Serial += 1
	local serial = Game.Serial
	Game.Winner = nil
	Game.ResultText = ""
	Game.TeamScore = { red = 0, blue = 0 }
	Game.Votes = {}

	loadMap(mapId)
	assignRoles(mode, ready)
	spawnEveryone(mode)
	fillBots(mode)

	Game.Phase = "Round"
	Game.TimeLeft = mode.Timer or R.RoundTime
	broadcast()
	announce(GameData.getMap(Game.MapId).Title .. "  •  " .. mode.Title, 5)
	log("раунд", mode.Id, "на карте", Game.MapId, "игроков", #ready)

	local roundStart = now()
	while Game.Serial == serial and Game.Phase == "Round" do
		task.wait(0.4)
		local done, text = checkWin(mode)
		if done then
			finishRound(text, serial)
			return
		end
	end
end

local function votesWinner()
	local counts = {}
	local best, bestCount = nil, -1
	for _, modeId in pairs(Game.Votes) do
		counts[modeId] = (counts[modeId] or 0) + 1
	end
	local list = {}
	for modeId, c in pairs(counts) do
		table.insert(list, modeId)
		if c > bestCount then
			best, bestCount = modeId, c
		end
	end
	if not best then
		return GameData.randomMode().Id
	end
	-- ничья -- случайный из лидеров
	local leaders = {}
	for _, modeId in ipairs(list) do
		if counts[modeId] == bestCount then
			table.insert(leaders, modeId)
		end
	end
	return leaders[math.random(1, #leaders)]
end

function startVote()
	Game.Phase = "Vote"
	Game.Serial += 1
	Game.Votes = {}
	Game.Winner = nil
	Game.ResultText = ""
	Game.TimeLeft = R.VoteTime
	Game.TeamScore = { red = 0, blue = 0 }

	for _, p in ipairs(Players:GetPlayers()) do
		local s = ps(p)
		s.role = "spectator"
		destroyDrone(p, "vote")
		releaseSurvivor(p)
		if p.Character then
			p.Character:Destroy()
			pcall(function()
				p.Character = nil
			end)
		end
	end
	unloadMap()
	broadcast()
	log("голосование")
end

-- --------------------------------------------------------------------------- --
-- Ремоуты игрока
-- --------------------------------------------------------------------------- --
local function joinMidRound(player)
	local s = ps(player)
	if s.outRound == Game.Serial then
		Rem.Banner:FireClient(player, "ВЫ ВЫБЫЛИ В ЭТОМ РАУНДЕ", 3)
		return
	end
	local mode = GameData.getMode(Game.Mode)
	if mode.Id == "free" then
		s.role = "drone"
	elseif mode.Id == "hide" then
		s.role = (s.rolePref == "drone" and aliveDrones() == 0) and "drone" or "survivor"
	elseif mode.Id == "teams" then
		s.role = "drone"
		s.team = (teamAlive("red") <= teamAlive("blue")) and "red" or "blue"
	elseif mode.Id == "survivors" then
		s.role = (s.rolePref == "survivor") and "survivor" or "drone"
	end
	if s.role == "drone" then
		spawnDrone(player, chooseDroneId(s))
	elseif s.role == "survivor" then
		spawnSurvivor(player, pickSpawn("SurvivorSpawns", Vector3.new(0, 10, 0)))
	end
	broadcast()
end

local function validateRolePref(rolePref)
	if typeof(rolePref) ~= "string" then
		return "auto"
	end
	for _, r in ipairs(Config.Roles) do
		if r.Id == rolePref then
			if rolePref == "random" then
				return (math.random(2) == 1) and "drone" or "survivor"
			end
			return rolePref
		end
	end
	return "auto"
end

Rem.Join.OnServerEvent:Connect(function(player, rolePref)
	local s = ps(player)
	s.rolePref = validateRolePref(rolePref)
	s.ready = true
	feed(string.format("%s в игре", player.DisplayName), Color3.fromRGB(150, 255, 190))
	if Game.Phase == "Round" and (not s.role or s.role == "spectator") then
		joinMidRound(player)
	end
	broadcast()
end)

Rem.SetRole.OnServerEvent:Connect(function(player, rolePref)
	local s = ps(player)
	s.rolePref = validateRolePref(rolePref)
	if Game.Phase == "Round" then
		destroyDrone(player, "switch")
		releaseSurvivor(player)
		s.role = nil
		joinMidRound(player)
	end
	broadcast()
end)

Rem.Vote.OnServerEvent:Connect(function(player, modeId)
	if Game.Phase ~= "Vote" then
		return
	end
	if typeof(modeId) ~= "string" then
		return
	end
	local valid = false
	for _, m in ipairs(GameData.Modes) do
		if m.Id == modeId then
			valid = true
		end
	end
	if not valid then
		return
	end
	Game.Votes[player.UserId] = modeId
	broadcast()
end)

-- --------------------------------------------------------------------------- --
-- Жизненный цикл игроков
-- --------------------------------------------------------------------------- --
local function onPlayerAdded(player)
	local s = ps(player)
	s.ready = false
	player.CharacterAdded:Connect(function(char)
		-- страховка: если режим не про выживших, персонаж не нужен
		local st = ps(player)
		if st.role ~= "survivor" then
			task.defer(function()
				if char.Parent and ps(player).role ~= "survivor" then
					char:Destroy()
					pcall(function()
						player.Character = nil
					end)
				end
			end)
		end
	end)
	task.delay(0.6, function()
		if player.Parent then
			broadcast()
		end
	end)
	log("игрок", player.Name, "зашёл")
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, p in ipairs(Players:GetPlayers()) do
	onPlayerAdded(p)
end

Players.PlayerRemoving:Connect(function(player)
	destroyDrone(player, "выход")
	releaseSurvivor(player)
	Game.Votes[player.UserId] = nil
	PState[player.UserId] = nil
	broadcast()
end)

-- --------------------------------------------------------------------------- --
-- Часы игры
-- --------------------------------------------------------------------------- --
task.spawn(function()
	while true do
		task.wait(1)
		if Game.Phase == "Vote" or Game.Phase == "Round" or Game.Phase == "End" then
			Game.TimeLeft = math.max(0, Game.TimeLeft - 1)
			broadcast()
			if Game.Phase == "Vote" and Game.TimeLeft <= 0 then
				local map = GameData.randomMap()
				local modeId = votesWinner()
				-- раунд живёт в своём потоке, иначе он остановит эти часы
				task.spawn(function()
					startRound(modeId, map.Id)
				end)
			end
		end
	end
end)

log("сервер готов, режимы:", #GameData.Modes, "карты:", #GameData.Maps)
task.delay(4, function()
	startVote()
end)
