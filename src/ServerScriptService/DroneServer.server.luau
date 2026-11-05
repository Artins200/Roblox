--!nonstrict
--[[
	DroneServer -- серверная часть «Беспилотник: Лавовый каньон».

	Сервер отвечает за:
	  * сборку дрона из модели игрока (сварка всех деталей в один узел),
	  * передачу сетевого владения игроку (физику считает клиент),
	  * оружие, урон, смерть и возрождение,
	  * волны врагов-перехватчиков и лавовые турели,
	  * бонусы, счёт, лидерборд.
]]

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")

local Config = require(ReplicatedStorage:WaitForChild("DroneConfig"))

Players.CharacterAutoLoads = false

-- ---------------------------------------------------------------------------
-- Состояние
-- ---------------------------------------------------------------------------
local playerData = {}    -- [Player] = данные дрона
local droneOwners = {}   -- [Model] = Player
local enemies = {}       -- активные перехватчики
local turrets = {}       -- лавовые турели
local projectiles = {}   -- снаряды врагов
local pickups = {}       -- бонусы
local waveNumber = 0

-- forward declarations
local damageEnemy, damageTurret, explode, spawnDrone, killPlayer, damageDrone

-- ---------------------------------------------------------------------------
-- Remotes
-- ---------------------------------------------------------------------------
local remotes = Instance.new("Folder")
remotes.Name = "DroneRemotes"
remotes.Parent = ReplicatedStorage

local function newRemote(name)
	local r = Instance.new("RemoteEvent")
	r.Name = name
	r.Parent = remotes
	return r
end

local SetDrone = newRemote("SetDrone")
local DroneLost = newRemote("DroneLost")
local FireRemote = newRemote("Fire")
local FireFX = newRemote("FireFX")
local BombRemote = newRemote("Bomb")
local BombFX = newRemote("BombFX")
local ExplosionFX = newRemote("ExplosionFX")
local Banner = newRemote("Banner")
local CrashRemote = newRemote("Crash")
local DamageFX = newRemote("DamageFX")
local RequestDrone = newRemote("RequestDrone")

-- ---------------------------------------------------------------------------
-- Утилиты
-- ---------------------------------------------------------------------------
local function norm(s)
	return (s:lower():gsub("[%s_%-]", ""))
end

local function findNamed(root, name)
	local n = norm(name)
	for _, d in ipairs(root:GetDescendants()) do
		if norm(d.Name) == n then
			return d
		end
	end
	return nil
end

local function clamp(v, lo, hi)
	return math.max(lo, math.min(hi, v))
end

local function spreadDirection(dir, degrees)
	if degrees <= 0 then
		return dir.Unit
	end
	local up = math.abs(dir.Y) > 0.98 and Vector3.new(1, 0, 0) or Vector3.new(0, 1, 0)
	local right = dir:Cross(up).Unit
	local realUp = right:Cross(dir.Unit).Unit
	local ang = math.rad(degrees) * math.sqrt(math.random())
	local roll = math.random() * math.pi * 2
	local offset = (right * math.cos(roll) + realUp * math.sin(roll)) * math.tan(ang)
	return (dir.Unit + offset).Unit
end

-- ---------------------------------------------------------------------------
-- Мир: точки спавна, турели, бонусы
-- ---------------------------------------------------------------------------
local gameplay = Workspace:WaitForChild("Gameplay")
local spawnPads = gameplay:WaitForChild("SpawnPads")
local turretMounts = gameplay:WaitForChild("TurretMounts")
local pickupAnchors = gameplay:WaitForChild("PickupAnchors")

local spawnList = {}
for _, pad in ipairs(spawnPads:GetChildren()) do
	if pad:IsA("BasePart") then
		table.insert(spawnList, pad)
	end
end
table.sort(spawnList, function(a, b) return a.Name < b.Name end)

local function getSpawnCFrame(player)
	if #spawnList == 0 then
		return CFrame.new(0, 70, 0)
	end
	local idx = 1
	for i, p in ipairs(Players:GetPlayers()) do
		if p == player then
			idx = i
			break
		end
	end
	local pad = spawnList[((idx - 1) % #spawnList) + 1]
	return CFrame.new(pad.Position + Vector3.new(0, 16, 0))
end

local fxFolder = Instance.new("Folder")
fxFolder.Name = "ServerFX"
fxFolder.Parent = Workspace

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.FilterDescendantsInstances = { fxFolder }

local projectileParams = RaycastParams.new()
projectileParams.FilterType = Enum.RaycastFilterType.Exclude
projectileParams.FilterDescendantsInstances = { fxFolder }

-- ---------------------------------------------------------------------------
-- Лидерборд / счёт
-- ---------------------------------------------------------------------------
local function setupLeaderstats(player)
	if player:FindFirstChild("leaderstats") then
		return
	end
	local stats = Instance.new("Folder")
	stats.Name = "leaderstats"
	local score = Instance.new("IntValue")
	score.Name = "Счёт"
	score.Parent = stats
	local kills = Instance.new("IntValue")
	kills.Name = "Убийства"
	kills.Parent = stats
	stats.Parent = player
end

local function addScore(player, amount)
	if not player or not player.Parent then
		return
	end
	local stats = player:FindFirstChild("leaderstats")
	local score = stats and stats:FindFirstChild("Счёт")
	if score then
		score.Value += amount
	end
	player:SetAttribute("Score", (player:GetAttribute("Score") or 0) + amount)
end

local function addKill(player)
	if not player or not player.Parent then
		return
	end
	local stats = player:FindFirstChild("leaderstats")
	local kills = stats and stats:FindFirstChild("Убийства")
	if kills then
		kills.Value += 1
	end
	player:SetAttribute("Kills", (player:GetAttribute("Kills") or 0) + 1)
end

-- ---------------------------------------------------------------------------
-- Эффекты
-- ---------------------------------------------------------------------------
function explode(position, radius, color)
	ExplosionFX:FireAllClients(position, radius, color or Color3.fromRGB(255, 140, 40))
end

local function announce(text, duration)
	Banner:FireAllClients(text, duration or 3)
	for _, p in ipairs(Players:GetPlayers()) do
		p:SetAttribute("Wave", waveNumber)
	end
end

-- ---------------------------------------------------------------------------
-- Дрон: сборка / уничтожение
-- ---------------------------------------------------------------------------
local function weldAssembly(model, primary)
	-- все детали пока Anchored = true, поэтому ничего не разваливается
	for _, p in ipairs(model:GetDescendants()) do
		if p:IsA("BasePart") and p ~= primary then
			if not p:FindFirstChildOfClass("WeldConstraint") then
				local weld = Instance.new("WeldConstraint")
				weld.Name = "AssemblyWeld"
				weld.Part0 = primary
				weld.Part1 = p
				weld.Parent = p
			end
		end
	end
end

local function unanchorAll(model)
	for _, p in ipairs(model:GetDescendants()) do
		if p:IsA("BasePart") then
			p.Anchored = false
		end
	end
end

function damageDrone(player, amount, killer, reason)
	local data = playerData[player]
	if not data or not data.alive then
		return
	end
	local model = data.model
	local armor = model:GetAttribute("Armor") or 1
	local health = (model:GetAttribute("Health") or 0) - amount * armor
	model:SetAttribute("Health", math.max(0, health))
	DamageFX:FireClient(player, amount * armor, reason or "hit")
	if health <= 0 then
		killPlayer(player, killer, reason or "destroyed")
	end
end

function killPlayer(player, killer, reason)
	local data = playerData[player]
	if not data then
		return
	end
	local pos = data.primary and data.primary.Position or Vector3.zero
	explode(pos, 28, Color3.fromRGB(255, 170, 60))
	addKill(killer)
	addScore(killer, 60)
	player:SetAttribute("Alive", false)
	player:SetAttribute("Deaths", (player:GetAttribute("Deaths") or 0) + 1)

	local model = data.model
	playerData[player] = nil
	if model then
		droneOwners[model] = nil
		model:SetAttribute("Alive", false)
		SetDrone:FireClient(player, nil, nil)
		DroneLost:FireClient(player, reason)
		for _, p in ipairs(model:GetDescendants()) do
			if p:IsA("BasePart") then
				p.Anchored = false
				p:ApplyAngularImpulse(Vector3.new(math.random(-300, 300),
					math.random(-300, 300), math.random(-300, 300)))
			end
		end
		Debris:AddItem(model, 6)
	end

	task.delay(Config.RespawnTime, function()
		if player.Parent then
			spawnDrone(player, player:GetAttribute("DroneId"))
		end
	end)
end

function spawnDrone(player, droneId)
	local old = playerData[player]
	if old then
		local model = old.model
		playerData[player] = nil
		if model then
			droneOwners[model] = nil
			model:Destroy()
		end
	end

	local droneCfg = Config.getDrone(droneId or player:GetAttribute("DroneId"))
	player:SetAttribute("DroneId", droneCfg.Id)

	local template = ServerStorage:FindFirstChild(droneCfg.Template)
	if not template then
		warn("[Drone] В ServerStorage нет модели " .. droneCfg.Template)
		return
	end

	local model = template:Clone()
	model.Name = "Drone_" .. player.Name
	model:PivotTo(getSpawnCFrame(player))

	local primary = model.PrimaryPart
	if not primary then
		local best, bestVol = nil, -1
		for _, p in ipairs(model:GetDescendants()) do
			if p:IsA("BasePart") then
				local v = p.Size.X * p.Size.Y * p.Size.Z
				if v > bestVol then
					best, bestVol = p, v
				end
			end
		end
		primary = best
		model.PrimaryPart = primary
	end
	if not primary then
		warn("[Drone] У модели нет деталей")
		model:Destroy()
		return
	end

	local camPart = findNamed(model, "camera")
	if camPart and camPart:IsA("BasePart") then
		camPart.CanCollide = false
		camPart.CanQuery = false
		camPart.CanTouch = false
	end

	weldAssembly(model, primary)

	model:SetAttribute("IsDrone", true)
	model:SetAttribute("OwnerName", player.Name)
	model:SetAttribute("OwnerUserId", player.UserId)
	model:SetAttribute("DroneId", droneCfg.Id)
	model:SetAttribute("MaxHealth", droneCfg.Health)
	model:SetAttribute("Health", droneCfg.Health)
	model:SetAttribute("Alive", true)
	model:SetAttribute("Armor", droneCfg.Armor)

	model.Parent = Workspace
	primary.Anchored = false
	unanchorAll(model)

	local guns = {}
	for _, n in ipairs({ "minigan one", "minigan two" }) do
		local g = findNamed(model, n)
		if g and g:IsA("BasePart") then
			table.insert(guns, g)
		end
	end
	if #guns == 0 then
		table.insert(guns, primary)
	end

	playerData[player] = {
		model = model,
		primary = primary,
		camera = camPart,
		guns = guns,
		gunIndex = 1,
		cfg = droneCfg,
		alive = true,
		lastFire = 0,
		lastBomb = -999,
		spawnTime = os.clock(),
	}
	droneOwners[model] = player

	-- Физику считает клиент -> управление без задержки.
	pcall(function()
		primary:SetNetworkOwner(player)
	end)

	SetDrone:FireClient(player, model, droneCfg.Id)
	player:SetAttribute("Alive", true)
end

local function isDroneModel(inst)
	local model = inst and inst:FindFirstAncestorOfClass("Model")
	while model do
		if model:GetAttribute("IsDrone") then
			return model, droneOwners[model]
		end
		model = model:FindFirstAncestorOfClass("Model")
	end
	return nil, nil
end

local function findWithAttribute(inst, attribute)
	local node = inst
	while node do
		if node:GetAttribute(attribute) then
			return node
		end
		node = node.Parent
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- Враги
-- ---------------------------------------------------------------------------
local function buildEnemyModel(position, wave)
	local model = Instance.new("Model")
	model.Name = "EnemyInterceptor"

	local core = Instance.new("Part")
	core.Name = "Core"
	core.Shape = Enum.PartType.Ball
	core.Size = Vector3.new(4.6, 4.6, 4.6)
	core.Material = Enum.Material.Neon
	core.Color = Color3.fromRGB(255, 96, 32)
	core.Anchored = true
	core.CanCollide = false
	core.CFrame = CFrame.new(position)
	core.Parent = model
	model.PrimaryPart = core

	local function weldPart(part)
		part.Anchored = true
		part.CanCollide = false
		part.Parent = model
		local w = Instance.new("WeldConstraint")
		w.Part0 = core
		w.Part1 = part
		w.Parent = part
	end

	for i = 0, 3 do
		local ang = math.rad(45 + i * 90)
		local arm = Instance.new("Part")
		arm.Name = "Arm"
		arm.Size = Vector3.new(1.6, 1.6, 8.5)
		arm.Material = Enum.Material.Metal
		arm.Color = Color3.fromRGB(42, 38, 40)
		arm.CFrame = CFrame.new(position) * CFrame.Angles(0, ang, 0) * CFrame.new(0, 0, -4.6)
		arm.TopSurface = Enum.SurfaceType.Smooth
		arm.BottomSurface = Enum.SurfaceType.Smooth
		weldPart(arm)

		local tip = Instance.new("Part")
		tip.Name = "Tip"
		tip.Shape = Enum.PartType.Ball
		tip.Size = Vector3.new(1.4, 1.4, 1.4)
		tip.Material = Enum.Material.Neon
		tip.Color = Color3.fromRGB(255, 60, 30)
		tip.CFrame = CFrame.new(position) * CFrame.Angles(0, ang, 0) * CFrame.new(0, 0, -8.6)
		weldPart(tip)
	end

	local eye = Instance.new("Part")
	eye.Name = "Eye"
	eye.Shape = Enum.PartType.Ball
	eye.Size = Vector3.new(2.2, 2.2, 2.2)
	eye.Material = Enum.Material.Neon
	eye.Color = Color3.fromRGB(255, 220, 180)
	eye.CFrame = CFrame.new(position) * CFrame.new(0, 0, -2.9)
	weldPart(eye)

	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 92, 30)
	light.Brightness = 4
	light.Range = 40
	light.Parent = core

	local fire = Instance.new("ParticleEmitter")
	fire.Rate = 20
	fire.Lifetime = NumberRange.new(0.6, 1.4)
	fire.Speed = NumberRange.new(3, 8)
	fire.Size = NumberSequence.new(1.6, 0.2)
	fire.Color = ColorSequence.new(Color3.fromRGB(255, 150, 60), Color3.fromRGB(120, 20, 0))
	fire.LightEmission = 1
	fire.Parent = core

	local hp = Config.Enemies.BaseHealth + Config.Enemies.HealthPerWave * (wave - 1)
	model:SetAttribute("Enemy", true)
	model:SetAttribute("Health", hp)
	model:SetAttribute("MaxHealth", hp)
	model.Parent = workspace

	local att = Instance.new("Attachment")
	att.Name = "Root"
	att.Parent = core

	local alignPos = Instance.new("AlignPosition")
	alignPos.Mode = Enum.PositionAlignmentMode.OneAttachment
	alignPos.Attachment0 = att
	alignPos.Position = position
	alignPos.MaxForce = 1e6
	alignPos.Responsiveness = 4.5
	alignPos.ApplyAtCenterOfMass = true
	alignPos.Parent = core

	local alignOr = Instance.new("AlignOrientation")
	alignOr.Mode = Enum.OrientationAlignmentMode.OneAttachment
	alignOr.Attachment0 = att
	alignOr.RigidityEnabled = false
	alignOr.MaxTorque = 1e6
	alignOr.Responsiveness = 6
	alignOr.Parent = core

	core.Anchored = false
	for _, p in ipairs(model:GetChildren()) do
		if p:IsA("BasePart") and p ~= core then
			p.Anchored = false
		end
	end

	return model
end

local function spawnEnemy(wave)
	local list = Players:GetPlayers()
	if #list == 0 then
		return
	end
	local player = list[math.random(1, #list)]
	local data = playerData[player]
	local base = (data and data.primary and data.primary.Position) or Vector3.new(0, 60, 0)
	local ang = math.random() * math.pi * 2
	local dist = math.random(220, 420)
	local pos = base + Vector3.new(math.cos(ang) * dist, math.random(20, 80), math.sin(ang) * dist)
	local model = buildEnemyModel(pos, wave)
	table.insert(enemies, {
		model = model,
		nextFire = os.clock() + math.random(120, 300) / 100,
		phase = math.random() * math.pi * 2,
		orbit = math.random(80, 150),
		height = math.random(15, 45),
	})
end

function damageEnemy(model, amount, attacker)
	for i, e in ipairs(enemies) do
		if e.model == model then
			local hp = (model:GetAttribute("Health") or 0) - amount
			model:SetAttribute("Health", hp)
			if hp <= 0 then
				table.remove(enemies, i)
				explode(model:GetPivot().Position, 20, Color3.fromRGB(255, 120, 40))
				model:Destroy()
				addScore(attacker, Config.Enemies.KillScore)
				addKill(attacker)
			end
			return
		end
	end
end

-- ---------------------------------------------------------------------------
-- Турели
-- ---------------------------------------------------------------------------
local function buildTurret(mount)
	local folder = Instance.new("Folder")
	folder.Name = "LavaTurret"
	local basePos = mount:GetPivot().Position

	local core = Instance.new("Part")
	core.Name = "TurretCore"
	core.Shape = Enum.PartType.Ball
	core.Size = Vector3.new(4.2, 4.2, 4.2)
	core.Material = Enum.Material.Neon
	core.Color = Color3.fromRGB(255, 110, 40)
	core.Anchored = true
	core.CanCollide = false
	core.CFrame = CFrame.new(basePos + Vector3.new(0, 14, 0))
	core.Parent = folder

	local barrel = Instance.new("Part")
	barrel.Name = "TurretBarrel"
	barrel.Size = Vector3.new(1.5, 1.5, 7)
	barrel.Material = Enum.Material.Metal
	barrel.Color = Color3.fromRGB(38, 34, 36)
	barrel.Anchored = true
	barrel.CanCollide = false
	barrel.CFrame = core.CFrame * CFrame.new(0, 0, -4)
	barrel.Parent = folder

	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 110, 40)
	light.Brightness = 3
	light.Range = 34
	light.Parent = core

	folder:SetAttribute("Turret", true)
	folder:SetAttribute("Health", Config.Turrets.Health)
	folder.Parent = workspace

	local entry = {
		folder = folder,
		core = core,
		barrel = barrel,
		mount = mount,
		nextFire = os.clock() + math.random(2, 5),
		dead = false,
	}
	table.insert(turrets, entry)
	return entry
end

function damageTurret(entry, amount, attacker)
	if entry.dead then
		return
	end
	local hp = (entry.folder:GetAttribute("Health") or 0) - amount
	entry.folder:SetAttribute("Health", hp)
	if hp <= 0 then
		entry.dead = true
		explode(entry.core.Position, 30, Color3.fromRGB(255, 140, 50))
		entry.folder:Destroy()
		addScore(attacker, Config.Turrets.KillScore)
		addKill(attacker)
		local idx = table.find(turrets, entry)
		if idx then
			table.remove(turrets, idx)
		end
		local mountRef = entry.mount
		task.delay(Config.Turrets.Respawn, function()
			if mountRef and mountRef.Parent then
				buildTurret(mountRef)
			end
		end)
	end
end

-- ---------------------------------------------------------------------------
-- Снаряды
-- ---------------------------------------------------------------------------
local function shootProjectile(from, dir, speed, damage, radius, color)
	local part = Instance.new("Part")
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.new(2, 2, 2)
	part.Material = Enum.Material.Neon
	part.Color = color
	part.CanCollide = false
	part.Anchored = true
	part.CFrame = CFrame.new(from)
	part.Parent = fxFolder
	table.insert(projectiles, {
		part = part,
		dir = dir.Unit,
		speed = speed,
		damage = damage,
		radius = radius,
		color = color,
		life = 7,
	})
end

local function nearestDrone(pos, maxDist)
	local best, bestDist, bestPos = nil, maxDist, nil
	for plr, d in pairs(playerData) do
		if d.alive and d.primary and d.primary.Parent then
			local p = d.primary.Position
			local dist = (p - pos).Magnitude
			if dist < bestDist then
				best, bestDist, bestPos = plr, dist, p
			end
		end
	end
	return best, bestPos
end

-- ---------------------------------------------------------------------------
-- Бонусы
-- ---------------------------------------------------------------------------
local function spawnPickup(anchor)
	local p = Instance.new("Part")
	p.Name = "Coolant"
	p.Shape = Enum.PartType.Ball
	p.Size = Vector3.new(4.4, 4.4, 4.4)
	p.Material = Enum.Material.Neon
	p.Color = Color3.fromRGB(80, 225, 255)
	p.Anchored = true
	p.CanCollide = false
	p.CFrame = anchor.CFrame * CFrame.new(0, 6, 0)
	p.Parent = workspace

	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(80, 225, 255)
	light.Brightness = 2.5
	light.Range = 26
	light.Parent = p

	table.insert(pickups, { part = p, anchor = anchor })
end

-- ---------------------------------------------------------------------------
-- Оружие игрока
-- ---------------------------------------------------------------------------
FireRemote.OnServerEvent:Connect(function(player, aimDir)
	local data = playerData[player]
	if not data or not data.alive then
		return
	end
	local wcfg = Config.Weapons.Minigun
	local now = os.clock()
	if now - data.lastFire < wcfg.Interval * 0.75 then
		return
	end
	data.lastFire = now

	if typeof(aimDir) ~= "Vector3" or aimDir.Magnitude < 0.5 then
		return
	end
	local dir = spreadDirection(aimDir, wcfg.Spread)

	local gun = data.guns[((data.gunIndex - 1) % #data.guns) + 1]
	data.gunIndex += 1
	local origin = gun.Position + dir * 3.5

	rayParams.FilterDescendantsInstances = { data.model, fxFolder }
	local result = Workspace:Raycast(origin, dir * wcfg.Range, rayParams)
	local hitPos = result and result.Position or (origin + dir * wcfg.Range)

	if result then
		local hit = result.Instance
		local droneModel, owner = isDroneModel(hit)
		local enemyModel = findWithAttribute(hit, "Enemy")
		local turretFolder = findWithAttribute(hit, "Turret")
		if droneModel and owner and owner ~= player then
			damageDrone(owner, wcfg.Damage, player, "minigun")
		elseif enemyModel then
			damageEnemy(enemyModel, wcfg.Damage, player)
		elseif turretFolder then
			for _, t in ipairs(turrets) do
				if t.folder == turretFolder then
					damageTurret(t, wcfg.Damage, player)
					break
				end
			end
		end
	end

	FireFX:FireAllClients(origin, hitPos, wcfg.Tracer)
end)

BombRemote.OnServerEvent:Connect(function(player)
	local data = playerData[player]
	if not data or not data.alive or not data.cfg.Bomb then
		return
	end
	local bcfg = Config.Weapons.Bomb
	local now = os.clock()
	if now - data.lastBomb < bcfg.Cooldown then
		return
	end
	data.lastBomb = now

	local start = data.primary.Position - Vector3.new(0, 7, 0)
	local model = Instance.new("Model")
	model.Name = "Bomb"

	local bomb = Instance.new("Part")
	bomb.Name = "BombBody"
	bomb.Shape = Enum.PartType.Ball
	bomb.Size = Vector3.new(2.6, 3.4, 2.6)
	bomb.Material = Enum.Material.Metal
	bomb.Color = Color3.fromRGB(52, 50, 54)
	bomb.CanCollide = false
	bomb.Anchored = true
	bomb.CFrame = CFrame.new(start)
	bomb.Parent = model

	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 60, 40)
	light.Brightness = 3
	light.Range = 26
	light.Parent = bomb

	local beep = Instance.new("ParticleEmitter")
	beep.Rate = 30
	beep.Lifetime = NumberRange.new(0.3, 0.6)
	beep.Speed = NumberRange.new(2, 6)
	beep.Size = NumberSequence.new(0.8, 0.2)
	beep.Color = ColorSequence.new(Color3.fromRGB(255, 120, 40))
	beep.LightEmission = 1
	beep.Parent = bomb

	model.Parent = workspace
	BombFX:FireAllClients(start)

	local velocity = Vector3.new(0, -bcfg.DropSpeed, 0)
	local pos = start
	local exploded = false

	local function detonate(atPos)
		if exploded then
			return
		end
		exploded = true
		explode(atPos, bcfg.Radius, Color3.fromRGB(255, 170, 60))
		for plr, d in pairs(playerData) do
			if d.alive and d.primary then
				local dist = (d.primary.Position - atPos).Magnitude
				if dist < bcfg.Radius then
					local falloff = 1 - dist / bcfg.Radius
					damageDrone(plr, bcfg.Damage * falloff, plr == player and nil or player, "bomb")
				end
			end
		end
		for _, e in ipairs(enemies) do
			local dist = (e.model:GetPivot().Position - atPos).Magnitude
			if dist < bcfg.Radius * 1.4 then
				damageEnemy(e.model, bcfg.Damage * (1 - dist / (bcfg.Radius * 1.4)) * 1.6, player)
			end
		end
		model:Destroy()
	end

	task.spawn(function()
		local t = 0
		local step = 1 / 30
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { model }
		while t < 14 and model.Parent do
			t += step
			velocity += Vector3.new(0, -workspace.Gravity * step, 0)
			local newPos = pos + velocity * step
			local res = workspace:Raycast(pos, newPos - pos, params)
			if res then
				detonate(res.Position)
				return
			end
			pos = newPos
			bomb.CFrame = CFrame.new(pos) * CFrame.Angles(t * 4, t * 6, 0)
			if pos.Y < Config.LavaKillY then
				detonate(pos)
				return
			end
			task.wait(step)
		end
		detonate(pos)
	end)
end)

CrashRemote.OnServerEvent:Connect(function(player, amount)
	local data = playerData[player]
	if not data or not data.alive then
		return
	end
	if typeof(amount) ~= "number" or amount <= 0 then
		return
	end
	damageDrone(player, math.min(amount, 34), nil, "crash")
end)

local VALID_DRONES = {}
for _, d in ipairs(Config.Drones) do
	VALID_DRONES[d.Id] = true
end

RequestDrone.OnServerEvent:Connect(function(player, droneId)
	if typeof(droneId) ~= "string" or not VALID_DRONES[droneId] then
		return
	end
	player:SetAttribute("DroneId", droneId)
	if player:GetAttribute("Alive") then
		-- killPlayer сам возродит игрока уже с новым DroneId
		killPlayer(player, nil, "switch")
	else
		spawnDrone(player, droneId)
	end
end)

-- ---------------------------------------------------------------------------
-- Главный цикл
-- ---------------------------------------------------------------------------
local pickupTimer = 0
local lavaTimer = 0

RunService.Heartbeat:Connect(function(dt)
	local now = os.clock()
	pickupTimer += dt
	lavaTimer += dt

	-- враги: держим дистанцию и стреляем
	for i = #enemies, 1, -1 do
		local e = enemies[i]
		local core = e.model.PrimaryPart
		if not e.model.Parent or not core then
			table.remove(enemies, i)
			continue
		end
		local _, targetPos = nearestDrone(core.Position, 1600)
		local alignPos = core:FindFirstChildOfClass("AlignPosition")
		local alignOr = core:FindFirstChildOfClass("AlignOrientation")
		if targetPos then
			e.phase += dt * 0.55
			local orbitDir = Vector3.new(math.cos(e.phase), 0, math.sin(e.phase))
			if alignPos then
				alignPos.Position = targetPos + orbitDir * e.orbit + Vector3.new(0, e.height, 0)
			end
			if alignOr and (targetPos - core.Position).Magnitude > 2 then
				alignOr.CFrame = CFrame.lookAt(core.Position, targetPos)
			end
			if now >= e.nextFire then
				e.nextFire = now + Config.Enemies.FireInterval * (0.7 + math.random() * 0.6)
				local from = core.Position + (targetPos - core.Position).Unit * 4
				shootProjectile(from, targetPos - from, Config.Enemies.ProjectileSpeed,
					Config.Enemies.ProjectileDamage, 9, Color3.fromRGB(255, 90, 30))
			end
		elseif alignPos then
			e.phase += dt * 0.3
			alignPos.Position = core.Position + Vector3.new(math.cos(e.phase) * 30, 0, math.sin(e.phase) * 30)
		end

		if core.Position.Y < Config.LavaKillY then
			explode(core.Position, 18, Color3.fromRGB(255, 120, 40))
			e.model:Destroy()
			table.remove(enemies, i)
		end
	end

	-- турели
	for _, t in ipairs(turrets) do
		if t.folder.Parent then
			local _, targetPos = nearestDrone(t.core.Position, Config.Turrets.Range)
			if targetPos then
				t.barrel.CFrame = CFrame.lookAt(t.core.Position, targetPos) * CFrame.new(0, 0, -4)
				if now >= t.nextFire then
					t.nextFire = now + Config.Turrets.FireInterval
					shootProjectile(t.barrel.Position, targetPos - t.barrel.Position,
						Config.Turrets.ProjectileSpeed, Config.Turrets.ProjectileDamage, 12,
						Color3.fromRGB(255, 130, 40))
				end
			end
		end
	end

	-- снаряды
	for i = #projectiles, 1, -1 do
		local p = projectiles[i]
		p.life -= dt
		if p.life <= 0 or not p.part.Parent then
			if p.part.Parent then
				p.part:Destroy()
			end
			table.remove(projectiles, i)
			continue
		end
		local step = p.dir * p.speed * dt
		local res = workspace:Raycast(p.part.Position, step, projectileParams)
		if res then
			local _, owner = isDroneModel(res.Instance)
			if owner then
				damageDrone(owner, p.damage, nil, "enemy")
			end
			explode(res.Position, p.radius, p.color)
			p.part:Destroy()
			table.remove(projectiles, i)
			continue
		end
		local newPos = p.part.Position + step
		p.part.CFrame = CFrame.new(newPos)
		if newPos.Y < Config.LavaKillY then
			explode(newPos, p.radius, p.color)
			p.part:Destroy()
			table.remove(projectiles, i)
		end
	end

	-- бонусы
	if pickupTimer > 0.16 then
		pickupTimer = 0
		for i = #pickups, 1, -1 do
			local pk = pickups[i]
			if not pk.part.Parent then
				table.remove(pickups, i)
				continue
			end
			pk.part.CFrame = pk.part.CFrame * CFrame.Angles(0, 0.07, 0)
			for plr, d in pairs(playerData) do
				if d.alive and d.primary and (d.primary.Position - pk.part.Position).Magnitude < 12 then
					local max = d.model:GetAttribute("MaxHealth") or 100
					local hp = d.model:GetAttribute("Health") or 0
					d.model:SetAttribute("Health", math.min(max, hp + Config.Pickups.Heal))
					addScore(plr, Config.Pickups.Score)
					DamageFX:FireClient(plr, -Config.Pickups.Heal, "heal")
					local anchor = pk.anchor
					pk.part:Destroy()
					table.remove(pickups, i)
					task.delay(Config.Pickups.Respawn, function()
						if anchor and anchor.Parent then
							spawnPickup(anchor)
						end
					end)
					break
				end
			end
		end
	end

	-- лава и границы арены
	if lavaTimer > 0.2 then
		lavaTimer = 0
		for plr, d in pairs(playerData) do
			if d.alive and d.primary then
				local pos = d.primary.Position
				if pos.Y < Config.LavaKillY then
					killPlayer(plr, nil, "lava")
				elseif pos.Magnitude > Config.ArenaRadius then
					damageDrone(plr, 15, nil, "bounds")
				end
			end
		end
	end
end)

-- ---------------------------------------------------------------------------
-- Волны
-- ---------------------------------------------------------------------------
local function waveLoop()
	task.wait(Config.Waves.FirstDelay)
	while true do
		waveNumber += 1
		announce("ВОЛНА " .. waveNumber, 3.5)

		for _, d in pairs(playerData) do
			if d.alive and d.model then
				local max = d.model:GetAttribute("MaxHealth") or 100
				local hp = d.model:GetAttribute("Health") or 0
				d.model:SetAttribute("Health", math.min(max, hp + max * 0.25))
			end
		end

		local toSpawn = math.min(Config.Enemies.MaxAlive,
			Config.Waves.BaseCount + (waveNumber - 1) * Config.Waves.CountPerWave)
		for i = 1, toSpawn do
			task.spawn(function()
				task.wait((i - 1) * 1.2)
				if #enemies < Config.Enemies.MaxAlive then
					spawnEnemy(waveNumber)
				end
			end)
		end

		-- ждём, пока все враги волны действительно появятся
		task.wait(toSpawn * 1.2 + 2.0)

		while #enemies > 0 do
			task.wait(1)
		end

		announce("ВОЛНА " .. waveNumber .. " ОЧИЩЕНА", 3)
		task.wait(Config.Waves.Intermission)
	end
end

-- ---------------------------------------------------------------------------
-- Игроки
-- ---------------------------------------------------------------------------
local function onPlayerAdded(player)
	setupLeaderstats(player)
	player:SetAttribute("Alive", false)
	player:SetAttribute("Deaths", 0)
	player:SetAttribute("Score", 0)
	player:SetAttribute("Kills", 0)
	player:SetAttribute("Wave", waveNumber)
	player.CharacterAdded:Connect(function(char)
		task.defer(function()
			if char and char.Parent then
				char:Destroy()
			end
		end)
	end)
	task.delay(1, function()
		if player.Parent then
			spawnDrone(player, Config.DefaultDrone)
		end
	end)
end

for _, p in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerAdded, p)
end
Players.PlayerAdded:Connect(onPlayerAdded)

Players.PlayerRemoving:Connect(function(player)
	local data = playerData[player]
	if data then
		local model = data.model
		playerData[player] = nil
		if model then
			droneOwners[model] = nil
			model:Destroy()
		end
	end
end)

-- ---------------------------------------------------------------------------
-- Запуск мира
-- ---------------------------------------------------------------------------
for _, mount in ipairs(turretMounts:GetChildren()) do
	task.delay(math.random() * 2, function()
		buildTurret(mount)
	end)
end

for _, anchor in ipairs(pickupAnchors:GetChildren()) do
	if anchor:IsA("BasePart") then
		task.delay(math.random() * 4, function()
			spawnPickup(anchor)
		end)
	end
end

task.spawn(waveLoop)

print("[Drone] «Лавовый каньон»: сервер запущен.")
