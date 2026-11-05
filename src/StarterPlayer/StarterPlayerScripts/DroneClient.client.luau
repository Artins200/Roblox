--!nonstrict
--[[
	DroneClient -- клиент игры «ДРОНЫ».

	Отвечает за:
	  * меню и голосование (MenuUI);
	  * настоящую физику полёта дрона (AlignOrientation + VectorForce + аэродинамика);
	  * камеру: погоня, от первого лица, вид наблюдателя;
	  * оружие выжившего от первого лица, нож, строительство досками;
	  * HUD, эффекты, тряску, хитмаркеры и ленту убийств.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("DroneConfig"))
local GameData = require(ReplicatedStorage:WaitForChild("GameData"))
local P = Config.Physics
local W = Config.Weapons

local DroneUI = require(script.Parent:WaitForChild("DroneUI"))
local MenuUI = require(script.Parent:WaitForChild("MenuUI"))
local Effects = require(script.Parent:WaitForChild("Effects"))
local FpsWeapon = require(script.Parent:WaitForChild("FpsWeapon"))
local BuilderModule = require(script.Parent:WaitForChild("Builder"))

local remotes = ReplicatedStorage:WaitForChild("DroneRemotes")
local Rem = {}
for _, name in ipairs({ "Sync", "Join", "Vote", "SetRole", "SetDrone", "DroneLost", "Fire",
	"FireFX", "Bomb", "BombFX", "ExplosionFX", "Banner", "Crash", "DamageFX",
	"RequestDrone", "GunFire", "GunFX", "Melee", "MeleeFX", "Build", "Placed", "Health",
	"Hitmark", "Feed", "Reload", "PickupBeacon" }) do
	Rem[name] = remotes:WaitForChild(name)
end

local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera

-- Roblox может подменить камеру (например, при респавне персонажа)
Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	if Workspace.CurrentCamera then
		camera = Workspace.CurrentCamera
	end
end)

-- --------------------------------------------------------------------------- --
-- Состояние клиента
-- --------------------------------------------------------------------------- --
local State = {
	phase = "Menu",
	mode = "free",
	role = nil,
	alive = false,
	drone = nil,
	health = 100,
	maxHealth = 100,
	heat = 0,
	overheated = false,
	ammo = Config.Infantry.Rifle.Magazine,
	magazine = Config.Infantry.Rifle.Magazine,
	reloading = false,
	buildMode = false,
	buildCount = 0,
	plankTitle = "СТЕНА",
	camMode = "chase",
	camYaw = 0,
	camPitch = -14,
	camDist = 40,
	lastFire = 0,
	lastCrash = 0,
	buildCountLocal = 0,
	lastPlace = 0,
	velocityPrev = Vector3.zero,
	collective = P.CollectiveIdle,
	tiltX = 0,
	tiltZ = 0,
	yaw = 0,
	snap = nil,
	mine = nil,
}

local input = {
	forward = 0, right = 0, up = 0, yaw = 0, fire = false, melee = false,
}

local keys = {}

-- --------------------------------------------------------------------------- --
-- Модули UI
-- --------------------------------------------------------------------------- --
local toggleBuild

local ui
ui = DroneUI.new({
	onSwitchDrone = function(id)
		if State.role == "drone" then
			Rem.RequestDrone:FireServer(id)
		end
	end,
	onBomb = function()
		if State.role == "drone" and State.drone and State.drone.cfg.Bomb then
			Rem.Bomb:FireServer()
		end
	end,
	onToggleCamera = function()
		State.camMode = (State.camMode == "chase") and "fpv" or "chase"
		ui:banner(State.camMode == "fpv" and "ВИД ОТ ПЕРВОГО ЛИЦА" or "ВИД ПОГОНИ", 1.4)
	end,
	onBuildToggle = function()
		toggleBuild()
	end,
})

local menu
menu = MenuUI.new({
	onJoin = function(rolePref)
		Rem.Join:FireServer(rolePref)
	end,
	onVote = function(modeId)
		Rem.Vote:FireServer(modeId)
	end,
})

local weapon = FpsWeapon.new(Config.Infantry.Rifle, {
	GunFire = Rem.GunFire,
	Melee = Rem.Melee,
	Reload = Rem.Reload,
}, {
	getCharacter = function()
		return player.Character
	end,
	onAmmo = function(ammo, magazine, reloading)
		State.ammo = ammo
		State.magazine = magazine
		State.reloading = reloading
	end,
})

local builder = BuilderModule.new(Config.Building, {
	getCharacter = function()
		return player.Character
	end,
	place = function(plankId, cf)
		Rem.Build:FireServer(plankId, cf)
	end,
})

function toggleBuild()
	if State.role ~= "survivor" then
		return
	end
	State.buildMode = not State.buildMode
	builder:setEnabled(State.buildMode)
	ui:banner(State.buildMode and "РЕЖИМ СТРОЙКИ" or "СТРОЙКА ВЫКЛЮЧЕНА", 1.6)
end

-- --------------------------------------------------------------------------- --
-- Мелкие помощники
-- --------------------------------------------------------------------------- --
local function lerp(a, b, t)
	return a + (b - a) * math.clamp(t, 0, 1)
end

local function lerpAngle(a, b, t)
	local diff = (b - a + 540) % 360 - 180
	return a + diff * math.clamp(t, 0, 1)
end

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

local function lockMouse()
	if not UserInputService.TouchEnabled then
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	end
end

-- --------------------------------------------------------------------------- --
-- Ремоуты сервера
-- --------------------------------------------------------------------------- --
Rem.FireFX.OnClientEvent:Connect(function(origin, target, color)
	Effects.tracer(origin, target, color)
end)

Rem.ExplosionFX.OnClientEvent:Connect(function(position, radius, color)
	Effects.explosion(position, radius, color)
end)

Rem.BombFX.OnClientEvent:Connect(function(position)
	Effects.muzzle(position, Color3.fromRGB(255, 120, 40))
end)

Rem.Banner.OnClientEvent:Connect(function(text, duration)
	ui:banner(text, duration)
end)

Rem.Feed.OnClientEvent:Connect(function(text, color)
	ui:feed(text, color)
end)

Rem.Hitmark.OnClientEvent:Connect(function()
	ui:hitmarker()
end)

Rem.DamageFX.OnClientEvent:Connect(function(amount, reason)
	if amount and amount > 0 then
		ui:damageFlash(false)
		Effects.addShake(0.014 + math.min(amount / 160, 0.045))
		if reason == "crash" then
			ui:toast("ЖЁСТКОЕ СТОЛКНОВЕНИЕ", Color3.fromRGB(255, 190, 90))
		end
	else
		ui:damageFlash(true)
	end
end)

Rem.Health.OnClientEvent:Connect(function(health, maxHealth)
	State.health = health or 0
	State.maxHealth = maxHealth or 100
end)

Rem.Placed.OnClientEvent:Connect(function(part, color)
	if part and part:IsA("BasePart") then
		Effects.impact(part.Position, Vector3.yAxis, color)
		if part:GetAttribute("OwnerUserId") == player.UserId then
			State.buildCountLocal += 1
			State.buildCount = State.buildCountLocal
		end
	end
end)

Rem.MeleeFX.OnClientEvent:Connect(function(userId, origin, dir)
	if userId == player.UserId then
		return
	end
	Effects.tracer(origin + dir * 3, origin + dir * 8, Color3.fromRGB(255, 220, 220), 0.1)
end)

-- --------------------------------------------------------------------------- --
-- Эффекты дрона: выхлоп, след, подсветка
-- --------------------------------------------------------------------------- --
local function addDroneFX(model, primary, cfg)
	local trailA0 = Instance.new("Attachment")
	trailA0.Name = "TrailA"
	trailA0.Position = Vector3.new(-2.4, 0, 3.4)
	trailA0.Parent = primary
	local trailA1 = Instance.new("Attachment")
	trailA1.Name = "TrailB"
	trailA1.Position = Vector3.new(2.4, 0, 3.4)
	trailA1.Parent = primary

	local trail = Instance.new("Trail")
	trail.Attachment0 = trailA0
	trail.Attachment1 = trailA1
	trail.Lifetime = 0.5
	trail.MinLength = 0.1
	trail.WidthScale = NumberSequence.new(1, 0)
	trail.Color = ColorSequence.new(cfg.Tint, Color3.fromRGB(20, 20, 24))
	trail.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35),
		NumberSequenceKeypoint.new(1, 1),
	})
	trail.LightEmission = 0.8
	trail.Parent = primary

	-- «сопла»: неоновые конусы, которые растягиваются от тяги
	local nozzles = {}
	for i = 1, 2 do
		local sign = (i == 1) and -1 or 1
		local cone = Instance.new("Part")
		cone.Name = "Nozzle"
		cone.Shape = Enum.PartType.Cylinder
		cone.Size = Vector3.new(1.4, 1.1, 1.1)
		cone.Color = cfg.Tint
		cone.Material = Enum.Material.Neon
		cone.Transparency = 0.25
		cone.Anchored = false
		cone.CanCollide = false
		cone.CanQuery = false
		cone.CastShadow = false
		cone.Massless = true
		cone.CFrame = primary.CFrame * CFrame.new(sign * 2.2, -1.0, 2.6)
			* CFrame.Angles(0, 0, math.rad(90))
		cone.Parent = model
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = primary
		weld.Part1 = cone
		weld.Parent = cone
		table.insert(nozzles, cone)
	end

	local light = Instance.new("PointLight")
	light.Color = cfg.Tint
	light.Brightness = 3
	light.Range = 30
	light.Parent = primary

	-- навигационные огни
	for i = 1, 2 do
		local sign = (i == 1) and -1 or 1
		local nav = Instance.new("Part")
		nav.Name = "Nav"
		nav.Shape = Enum.PartType.Ball
		nav.Size = Vector3.new(0.7, 0.7, 0.7)
		nav.Color = (sign < 0) and Color3.fromRGB(255, 70, 70) or Color3.fromRGB(70, 255, 140)
		nav.Material = Enum.Material.Neon
		nav.CanCollide = false
		nav.CanQuery = false
		nav.CastShadow = false
		nav.Massless = true
		nav.CFrame = primary.CFrame * CFrame.new(sign * 3.4, 0.4, -2.0)
		nav.Parent = model
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = primary
		weld.Part1 = nav
		weld.Parent = nav
	end

	return { nozzles = nozzles, trail = trail, light = light }
end

-- --------------------------------------------------------------------------- --
-- Контроллер дрона
-- --------------------------------------------------------------------------- --
local function teardownDrone()
	local d = State.drone
	State.drone = nil
	State.alive = false
	State.heat = 0
	State.overheated = false
	if d then
		if d.fx then
			if d.fx.trail then
				d.fx.trail:Destroy()
			end
		end
		if d.primary and d.primary.Parent then
			for _, name in ipairs({ "DroneAlign", "DroneThrust", "DroneDrag", "DroneBody",
				"DroneThrustDir", "Downwash" }) do
				local inst = d.primary:FindFirstChild(name)
				if inst then
					inst:Destroy()
				end
			end
		end
	end
	ui:setDrone(nil)
	ui:setVisible(false)
end

local function buildDrone(model, droneId)
	teardownDrone()
	local cfg = Config.getDrone(droneId)
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
		return
	end

	local bodyAtt = Instance.new("Attachment")
	bodyAtt.Name = "DroneBody"
	bodyAtt.Parent = primary

	local align = Instance.new("AlignOrientation")
	align.Name = "DroneAlign"
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = bodyAtt
	align.RigidityEnabled = false
	align.ReactionTorqueEnabled = true
	align.MaxTorque = math.clamp(primary.AssemblyMass * 3200, 150000, 4500000)
	align.Responsiveness = P.TiltResponsiveness * cfg.Agility
	align.CFrame = primary.CFrame
	align.Parent = primary

	local thrustAtt = Instance.new("Attachment")
	thrustAtt.Name = "DroneThrustDir"
	thrustAtt.Parent = primary

	local thrust = Instance.new("VectorForce")
	thrust.Name = "DroneThrust"
	thrust.Attachment0 = thrustAtt
	thrust.RelativeTo = Enum.ActuatorRelativeTo.Attachment0
	thrust.ApplyAtCenterOfMass = true
	thrust.Force = Vector3.zero
	thrust.Parent = primary

	local drag = Instance.new("VectorForce")
	drag.Name = "DroneDrag"
	drag.ApplyAtCenterOfMass = true
	drag.Force = Vector3.zero
	drag.Parent = primary

	local guns = {}
	for _, n in ipairs({ "minigan one", "minigan two" }) do
		local g = findNamed(model, n)
		if g and g:IsA("BasePart") then
			table.insert(guns, g)
		end
	end
	if #guns == 0 then
		guns = { primary }
	end

	local camPart = findNamed(model, "camera")

	local dust = Instance.new("ParticleEmitter")
	dust.Name = "Downwash"
	dust.Rate = 0
	dust.Lifetime = NumberRange.new(0.5, 1.1)
	dust.Speed = NumberRange.new(18, 34)
	dust.SpreadAngle = Vector2.new(180, 180)
	dust.Size = NumberSequence.new(2.4, 0.2)
	dust.Color = ColorSequence.new(Color3.fromRGB(150, 120, 100), Color3.fromRGB(60, 44, 36))
	dust.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.6),
		NumberSequenceKeypoint.new(1, 1),
	})
	dust.Acceleration = Vector3.new(0, -14, 0)
	dust.EmissionDirection = Enum.NormalId.Bottom
	dust.Parent = primary

	local fx = addDroneFX(model, primary, cfg)

	State.drone = {
		model = model,
		primary = primary,
		cfg = cfg,
		guns = guns,
		cameraPart = camPart,
		dust = dust,
		align = align,
		thrust = thrust,
		drag = drag,
		fx = fx,
	}
	State.alive = true
	State.collective = P.CollectiveIdle
	State.tiltX = 0
	State.tiltZ = 0
	State.yaw = select(2, primary.CFrame:ToEulerAnglesYXZ())
	State.velocityPrev = primary.AssemblyLinearVelocity
	State.camYaw = State.yaw
	State.health = cfg.Health
	State.maxHealth = cfg.Health
	State.buildMode = false
	builder:setEnabled(false)

	camera.CameraType = Enum.CameraType.Scriptable
	player.CameraMode = Enum.CameraMode.Classic
	lockMouse()
	ui:setRole("drone")
	ui:setDrone(cfg)
	ui:setVisible(true)
	ui:banner(cfg.Title .. "  •  " .. GameData.getMode(State.mode).Short, 2.6)
end

Rem.SetDrone.OnClientEvent:Connect(function(model, droneId, health)
	if model and model:IsA("Model") then
		buildDrone(model, droneId or Config.DefaultDrone)
		if health then
			State.health = health
			State.maxHealth = Config.getDrone(droneId).Health
		end
	else
		teardownDrone()
	end
end)

Rem.DroneLost.OnClientEvent:Connect(function(reason)
	teardownDrone()
	local text = "ДРОН УНИЧТОЖЕН"
	if reason == "бездна" or reason == "лава" then
		text = "ПАДЕНИЕ В БЕЗДНУ"
	elseif reason == "crash" then
		text = "ЖЁСТКАЯ ПОСАДКА"
	elseif reason == "vote" then
		text = "ГОЛОСОВАНИЕ"
	elseif reason == "dead" then
		text = "ВЫ ВЫБЫЛИ"
	elseif reason == "бомба" then
		text = "НАКРЫЛО БОМБОЙ"
	end
	ui:banner(text, 3)
end)

-- --------------------------------------------------------------------------- --
-- Синхронизация состояния
-- --------------------------------------------------------------------------- --
local function applyRoleUI()
	local role = State.role
	local playing = (State.phase == "Round") and (role == "drone" or role == "survivor")
	ui:setVisible(playing)
	if role == "survivor" then
		ui:setRole("survivor")
	end
	if playing then
		ui:setMode(GameData.getMode(State.mode).Title .. "  •  " ..
			GameData.getMap(State.snap and State.snap.mapId or "lava").Title)
	else
		ui:setMode(nil)
	end
end

Rem.Sync.OnClientEvent:Connect(function(snap, mine)
	State.snap = snap
	State.mine = mine
	local prevPhase = State.phase
	local prevRole = State.role
	State.phase = snap.phase
	State.mode = snap.mode
	State.role = mine and mine.role or nil

	menu:update(snap, mine)
	applyRoleUI()

	-- смена роли
	if prevPhase ~= snap.phase then
		State.buildCountLocal = 0
		State.buildCount = 0
	end
	if State.role ~= prevRole or prevPhase ~= snap.phase then
		if State.role == "survivor" then
			teardownDrone()
			if player.Character then
				player.CameraMode = Enum.CameraMode.LockFirstPerson
				camera.CameraType = Enum.CameraType.Custom
				weapon:attach()
				lockMouse()
				ui:setVisible(true)
				ui:banner("ВЫЖИВШИЙ  •  ВИНТОВКА  •  [B] СТРОЙКА", 3)
			end
		elseif State.role == "drone" then
			weapon:detach()
			player.CameraMode = Enum.CameraMode.Classic
		else
			weapon:detach()
			builder:setEnabled(false)
			State.buildMode = false
		end
	end
end)

-- --------------------------------------------------------------------------- --
-- Физика полёта
-- --------------------------------------------------------------------------- --
local windPhase = 0
local function windVector(dt)
	windPhase += dt * 0.35
	local t = os.clock() * 0.5
	return Vector3.new(
		math.noise(windPhase, t) * P.WindStrength,
		math.noise(windPhase + 10, t * 0.7) * P.WindStrength * 0.35,
		math.noise(windPhase + 20, t * 0.9) * P.WindStrength)
end

local downRay = RaycastParams.new()
downRay.FilterType = Enum.RaycastFilterType.Exclude
downRay.FilterDescendantsInstances = { Effects.folder() }

local groundTimer = 0
local groundFt = 0

local function readInput(dt)
	local f = 0
	local r = 0
	local u = 0
	local y = 0
	if keys[Enum.KeyCode.W] then f += 1 end
	if keys[Enum.KeyCode.S] then f -= 1 end
	if keys[Enum.KeyCode.A] then r -= 1 end
	if keys[Enum.KeyCode.D] then r += 1 end
	if keys[Enum.KeyCode.Space] then u += 1 end
	if keys[Enum.KeyCode.LeftShift] or keys[Enum.KeyCode.LeftControl] then u -= 1 end
	if keys[Enum.KeyCode.Q] then y -= 1 end
	if keys[Enum.KeyCode.E] then y += 1 end

	if not UserInputService.TouchEnabled then
		lockMouse()
		local delta = UserInputService:GetMouseDelta()
		State.camYaw -= delta.X * 0.22
		State.camPitch = math.clamp(State.camPitch - delta.Y * 0.18, -74, 36)
	end

	local virtual = ui:getVirtualInput()
	input.forward = math.clamp(f + (virtual.y or 0), -1, 1)
	input.right = math.clamp(r + (virtual.x or 0), -1, 1)
	input.up = math.clamp(u + (virtual.up or 0), -1, 1)
	input.yaw = math.clamp(y + (virtual.yaw or 0), -1, 1)
	input.fire = (keys.fire == true) or (virtual.fire == true)
end

local function stepFlight(dt)
	local d = State.drone
	if not d or not d.primary or not d.primary.Parent then
		return
	end
	local primary = d.primary
	local cfg = d.cfg

	readInput(dt)

	local velocity = primary.AssemblyLinearVelocity
	local speed = velocity.Magnitude
	local mass = math.max(primary.AssemblyMass, 1)
	local hover = mass * Workspace.Gravity

	-- курс
	local hasStick = math.abs(input.forward) + math.abs(input.right) > 0.08
	if input.yaw ~= 0 then
		State.yaw += input.yaw * P.YawRate * cfg.Agility * dt
		State.camYaw = lerpAngle(State.camYaw, State.yaw, dt * 3.4)
	elseif hasStick then
		State.yaw = lerpAngle(State.yaw, State.camYaw, dt * P.YawFollowLerp * cfg.Agility)
	end

	-- крен и тангаж
	local maxTilt = P.MaxTilt
	local targetPitch = -input.forward * maxTilt
	local targetRoll = input.right * maxTilt * 1.05 + math.clamp(input.yaw * 9, -9, 9)
	State.tiltX = lerp(State.tiltX, targetPitch, dt * P.TiltResponsiveness * cfg.Agility)
	State.tiltZ = lerp(State.tiltZ, targetRoll, dt * P.TiltResponsiveness * cfg.Agility)

	local desired = CFrame.fromEulerAnglesYXZ(
		math.rad(State.tiltX), math.rad(State.yaw), math.rad(State.tiltZ))
	if d.align then
		d.align.CFrame = CFrame.new(primary.Position) * desired
	end

	-- общая тяга
	local targetCollective = P.CollectiveIdle
	if input.up > 0.05 then
		targetCollective = P.CollectiveUp
	elseif input.up < -0.05 then
		targetCollective = P.CollectiveDown
	end
	-- разряженный воздух на большой высоте: тяга слабее
	local altitudePenalty = 1
	if primary.Position.Y > P.MaxHealthDroneAlt then
		altitudePenalty = math.clamp(1 - (primary.Position.Y - P.MaxHealthDroneAlt) / 900, 0.55, 1)
	end
	State.collective = lerp(State.collective, targetCollective, dt * P.CollectiveLerp)

	-- эффект экрана земли
	groundTimer += dt
	if groundTimer > 0.08 then
		groundTimer = 0
		local res = Workspace:Raycast(primary.Position, Vector3.new(0, -P.GroundEffectHeight, 0), downRay)
		groundFt = res and 1 or 0
	end
	local collective = State.collective * (groundFt > 0 and (1 + P.GroundEffectBoost) or 1)

	if d.thrust then
		d.thrust.Force = Vector3.new(0, hover * collective * cfg.Thrust * altitudePenalty, 0)
	end

	-- аэродинамика
	local air = velocity - windVector(dt)
	local airSpeed = air.Magnitude
	if d.drag then
		if airSpeed > 0.05 then
			local coef = mass * (P.LinearDrag * airSpeed + P.QuadDrag * airSpeed * airSpeed)
			d.drag.Force = -(air.Unit * coef)
		else
			d.drag.Force = Vector3.zero
		end
	end

	-- сопла
	if d.fx and d.fx.nozzles then
		local stretch = math.clamp(State.collective / P.CollectiveUp, 0.3, 1.6)
		for _, cone in ipairs(d.fx.nozzles) do
			if cone.Parent then
				cone.Size = Vector3.new(1.2 + stretch * 2.4, 1.0 + stretch * 0.6, 1.0 + stretch * 0.6)
				cone.Transparency = 0.45 - stretch * 0.25
			end
		end
	end

	if d.dust then
		d.dust.Rate = (State.collective > 1.02 and speed < 70) and 26 or 0
	end

	-- столкновения
	local deltaV = (velocity - State.velocityPrev).Magnitude
	local prevSpeed = State.velocityPrev.Magnitude
	if deltaV > 34 and prevSpeed > 42 and os.clock() - State.lastCrash > 0.75 then
		State.lastCrash = os.clock()
		local dmg = math.clamp((deltaV - 34) * P.CrashDamageScale, 0, 34)
		if dmg > 1 then
			Rem.Crash:FireServer(dmg)
			Effects.addShake(math.min(dmg / 90, 0.06))
		end
	end
	State.velocityPrev = velocity

	-- стрельба
	if input.fire and not State.overheated then
		local clock = os.clock()
		if clock - State.lastFire >= W.Minigun.Interval then
			State.lastFire = clock
			Rem.Fire:FireServer(camera.CFrame.LookVector)
			State.heat = math.min(1, State.heat + W.Minigun.HeatPerShot)
			Effects.addShake(0.004)
			local gun = d.guns[math.random(1, #d.guns)]
			if gun then
				Effects.muzzle(gun.Position, W.Minigun.Tracer)
			end
		end
	end
	State.heat = math.max(0, State.heat - W.Minigun.CoolRate * dt)
	if State.heat >= 1 then
		State.overheated = true
	end
	if State.overheated and State.heat < 0.35 then
		State.overheated = false
	end

	ui:update({
		health = State.health,
		maxHealth = State.maxHealth,
		heat = State.heat,
		overheated = State.overheated,
		speed = speed,
		altitude = primary.Position.Y,
		bombLabel = cfg.Bomb and "[X] БОМБА" or "БЕЗ БОМБЫ",
	})
end

-- --------------------------------------------------------------------------- --
-- Камера
-- --------------------------------------------------------------------------- --
local camPos = Vector3.new(0, 160, 260)
local camLook = Vector3.new(0, 40, 0)

local function updateCamera(dt)
	local d = State.drone
	if d and d.primary and d.primary.Parent then
		camera.CameraType = Enum.CameraType.Scriptable
		local primary = d.primary
		local velocity = primary.AssemblyLinearVelocity
		local speed = velocity.Magnitude
		if State.camMode == "fpv" then
			local base = primary.CFrame
			if d.cameraPart then
				base = d.cameraPart.CFrame
			end
			local pos = base.Position + base.LookVector * 2.6
			camera.CFrame = CFrame.lookAt(pos, pos + base.LookVector * 100, base.UpVector)
				* Effects.shakeCFrame(dt)
			camera.FieldOfView = 90
		else
			local dist = State.camDist * (1 + math.clamp(speed / 900, 0, 0.16))
			local rot = CFrame.fromEulerAnglesYXZ(math.rad(State.camPitch), math.rad(State.camYaw), 0)
			local targetPos = primary.Position + (rot * Vector3.new(0, 2.4, dist))
			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Exclude
			params.FilterDescendantsInstances = { d.model, Effects.folder() }
			local res = Workspace:Raycast(primary.Position, targetPos - primary.Position, params)
			if res then
				targetPos = res.Position + res.Normal * 2.2
			end
			camPos = camPos:Lerp(targetPos, math.clamp(dt * 6.5, 0, 1))
			local lookAt = primary.Position + velocity * 0.08 + Vector3.new(0, 1.4, 0)
			camLook = camLook:Lerp(lookAt, math.clamp(dt * 9, 0, 1))
			camera.CFrame = CFrame.lookAt(camPos, camLook) * Effects.shakeCFrame(dt)
			camera.FieldOfView = lerp(camera.FieldOfView, 76 + math.clamp(speed / 9, 0, 13), dt * 3)
		end
		return
	end

	if State.role == "survivor" then
		camera.CameraType = Enum.CameraType.Custom
		return
	end

	-- наблюдатель: медленный облёт
	camera.CameraType = Enum.CameraType.Scriptable
	State.camYaw += dt * 5
	local radius = 320
	local pos = Vector3.new(math.sin(math.rad(State.camYaw)) * radius, 180,
		math.cos(math.rad(State.camYaw)) * radius)
	camPos = camPos:Lerp(pos, math.clamp(dt * 1.2, 0, 1))
	camLook = camLook:Lerp(Vector3.new(0, 40, 0), math.clamp(dt * 1.2, 0, 1))
	camera.CFrame = CFrame.lookAt(camPos, camLook) * Effects.shakeCFrame(dt)
	camera.FieldOfView = 76
end

-- --------------------------------------------------------------------------- --
-- Ввод
-- --------------------------------------------------------------------------- --
UserInputService.InputBegan:Connect(function(inp, processed)
	if inp.UserInputType == Enum.UserInputType.Keyboard then
		keys[inp.KeyCode] = true
		local code = inp.KeyCode
		if code == Enum.KeyCode.Tab then
			menu:toggleScoreboard()
			return
		end
		if processed then
			return
		end
		if State.role == "drone" then
			if code == Enum.KeyCode.F then
				ui:callToggleCamera()
			elseif code == Enum.KeyCode.X then
				ui:callBomb()
			elseif code == Enum.KeyCode.One then
				Rem.RequestDrone:FireServer("scout")
			elseif code == Enum.KeyCode.Two then
				Rem.RequestDrone:FireServer("gunship")
			end
		elseif State.role == "survivor" then
			if code == Enum.KeyCode.B then
				toggleBuild()
			elseif code == Enum.KeyCode.V then
				weapon:melee()
			elseif code == Enum.KeyCode.R then
				if State.buildMode then
					builder:rotate(45)
				else
					weapon:reload()
				end
			elseif State.buildMode then
				if code == Enum.KeyCode.One then
					State.plankTitle = builder:setPlank("wall").Title
				elseif code == Enum.KeyCode.Two then
					State.plankTitle = builder:setPlank("floor").Title
				elseif code == Enum.KeyCode.Three then
					State.plankTitle = builder:setPlank("ramp").Title
				end
			end
		end
	elseif inp.UserInputType == Enum.UserInputType.MouseButton1 then
		keys.fire = true
	elseif inp.UserInputType == Enum.UserInputType.MouseButton2 then
		if State.role == "survivor" and not State.buildMode then
			weapon:melee()
		end
	end
end)

UserInputService.InputEnded:Connect(function(inp)
	if inp.UserInputType == Enum.UserInputType.Keyboard then
		keys[inp.KeyCode] = false
	elseif inp.UserInputType == Enum.UserInputType.MouseButton1 then
		keys.fire = false
	end
end)

UserInputService.InputChanged:Connect(function(inp)
	if inp.UserInputType == Enum.UserInputType.MouseWheel then
		State.camDist = math.clamp(State.camDist - inp.Position.Z * 3, 16, 84)
	end
end)

-- --------------------------------------------------------------------------- --
-- Главный цикл
-- --------------------------------------------------------------------------- --
local buildCountPrune = 0

RunService.RenderStepped:Connect(function(dt)
	if State.role == "drone" and State.alive then
		stepFlight(dt)
	end

	if State.role == "survivor" then
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local alive = humanoid and humanoid.Health > 0
		if alive then
			if player.CameraMode ~= Enum.CameraMode.LockFirstPerson then
				player.CameraMode = Enum.CameraMode.LockFirstPerson
			end
			if not weapon.enabled then
				weapon:attach()
			end
			if State.buildMode then
				builder:update(dt, camera)
				local wantsPlace = keys.fire == true or ui:getVirtualInput().fire == true
				if wantsPlace and builder.valid and os.clock() - State.lastPlace > 0.18 then
					if builder:place() then
						State.lastPlace = os.clock()
						Effects.impact(builder.targetCF.Position, Vector3.yAxis,
							Color3.fromRGB(180, 150, 110))
					end
				end
			end
			local firing = (keys.fire == true or ui:getVirtualInput().fire == true)
				and not State.buildMode
			weapon:update(dt, firing)
			ui:update({
				health = humanoid.Health,
				maxHealth = humanoid.MaxHealth,
				ammo = State.ammo,
				magazine = State.magazine,
				reloading = State.reloading,
				buildMode = State.buildMode,
				buildCount = State.buildCount,
				buildMax = Config.Building.MaxParts,
				plankTitle = State.plankTitle,
			})
		elseif weapon.enabled then
			weapon:detach()
		end
	else
		State.buildMode = false
	end

	updateCamera(dt)
end)

-- --------------------------------------------------------------------------- --
-- Старт
-- --------------------------------------------------------------------------- --
camera.CameraType = Enum.CameraType.Scriptable
ui:setVisible(false)
ui:setRole("drone")
weapon:detach()
Effects.addShake(0)
