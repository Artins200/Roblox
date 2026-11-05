--!nonstrict
--[[
	DroneClient -- клиентская часть.

	Здесь живёт «физика» дрона. Она сделана по-настоящему, а не через
	CFrame-телепортацию:

	  * тяга -- VectorForce вдоль локальной оси «вверх» корпуса;
	    гравитация настоящая, поэтому при крене дрон честно «съезжает» вниз;
	  * ориентация -- AlignOrientation (упругий гироскоп с инерцией),
	    MaxTorque масштабируется от массы, поэтому тяжёлый дрон чувствуется
	    тяжёлым;
	  * сопротивление воздуха -- линейное + квадратичное (F = -(k1*v + k2*v|v|)),
	    поэтому есть настоящая максимальная скорость и «планирование»;
	  * порывы ветра, эффект экрана земли, инерция разгона и торможения.

	Управление: WASD -- крен/тангаж, Q/E -- рыскание, Space/Shift -- тяга,
	ЛКМ -- миниганы, X -- бомба, F -- вид от первого лица, 1/2 -- смена дрона.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")

local Config = require(ReplicatedStorage:WaitForChild("DroneConfig"))
local DroneUI = require(script.Parent:WaitForChild("DroneUI"))

local remotes = ReplicatedStorage:WaitForChild("DroneRemotes")
local SetDrone = remotes:WaitForChild("SetDrone")
local DroneLost = remotes:WaitForChild("DroneLost")
local FireRemote = remotes:WaitForChild("Fire")
local FireFX = remotes:WaitForChild("FireFX")
local BombRemote = remotes:WaitForChild("Bomb")
local BombFX = remotes:WaitForChild("BombFX")
local ExplosionFX = remotes:WaitForChild("ExplosionFX")
local Banner = remotes:WaitForChild("Banner")
local CrashRemote = remotes:WaitForChild("Crash")
local DamageFX = remotes:WaitForChild("DamageFX")
local RequestDrone = remotes:WaitForChild("RequestDrone")

local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera
local P = Config.Physics
local W = Config.Weapons

camera.CameraType = Enum.CameraType.Scriptable
camera.FieldOfView = 74

-- ---------------------------------------------------------------------------
-- Состояние
-- ---------------------------------------------------------------------------
local state = {
	drone = nil,          -- {model, primary, cfg, guns, camera}
	align = nil,
	thrust = nil,
	drag = nil,
	mass = 100,
	collective = P.CollectiveIdle,
	tiltX = 0,            -- текущий тангаж (градусы)
	tiltZ = 0,            -- текущий крен
	yaw = 0,              -- текущий курс
	lastFire = 0,
	heat = 0,
	overheated = false,
	alive = false,
	lastCrash = 0,
	camYaw = 0,
	camPitch = -16,
	camDist = 38,
	camMode = "chase",    -- chase | fpv
	shake = 0,
	shakeSeed = 0,
	velocityPrev = Vector3.zero,
	windPhase = 0,
	zoom = 1,
	landedOn = nil,
	lastDamaged = 0,
}

local inputState = {
	forward = 0,
	right = 0,
	up = 0,
	yaw = 0,
	fire = false,
}

local ui
ui = DroneUI.new({
	onSwitchDrone = function(id)
		RequestDrone:FireServer(id)
	end,
	onBomb = function()
		if state.drone and state.drone.cfg.Bomb then
			BombRemote:FireServer()
		end
	end,
	onToggleCamera = function()
		state.camMode = (state.camMode == "chase") and "fpv" or "chase"
		ui:setCameraMode(state.camMode)
	end,
})

-- ---------------------------------------------------------------------------
-- Мелочи
-- ---------------------------------------------------------------------------
local function lerp(a, b, t)
	return a + (b - a) * math.clamp(t, 0, 1)
end

local function lerpAngle(a, b, t)
	local diff = (b - a + 540) % 360 - 180
	return a + diff * math.clamp(t, 0, 1)
end

local function findNamed(root, name)
	local n = (name:lower():gsub("[%s_%-]", ""))
	for _, d in ipairs(root:GetDescendants()) do
		if (d.Name:lower():gsub("[%s_%-]", "")) == n then
			return d
		end
	end
	return nil
end

local function shaking()
	state.shake = math.max(state.shake, 0)
	return CFrame.Angles(
		math.noise(state.shakeSeed, os.clock() * 22) * state.shake,
		math.noise(state.shakeSeed + 5, os.clock() * 19) * state.shake,
		math.noise(state.shakeSeed + 9, os.clock() * 17) * state.shake * 0.6)
end

-- ---------------------------------------------------------------------------
-- Эффекты
-- ---------------------------------------------------------------------------
local fxFolder = Instance.new("Folder")
fxFolder.Name = "ClientFX"
fxFolder.Parent = Workspace

local function tracer(origin, target, color)
	local dist = (target - origin).Magnitude
	if dist < 0.6 then
		return
	end
	local beam = Instance.new("Part")
	beam.Name = "Tracer"
	beam.Anchored = true
	beam.CanCollide = false
	beam.CanQuery = false
	beam.CastShadow = false
	beam.Material = Enum.Material.Neon
	beam.Color = color or W.Minigun.Tracer
	beam.Size = Vector3.new(0.22, 0.22, dist)
	beam.CFrame = CFrame.lookAt(origin + (target - origin) / 2, target)
	beam.Transparency = 0.05
	beam.Parent = fxFolder
	TweenService:Create(beam, TweenInfo.new(0.09), { Transparency = 1 }):Play()
	Debris:AddItem(beam, 0.14)

	local flash = Instance.new("PointLight")
	flash.Color = color or W.Minigun.Tracer
	flash.Brightness = 4
	flash.Range = 26
	flash.Parent = beam

	-- искры в точке попадания
	local hit = Instance.new("ParticleEmitter")
	hit.Rate = 0
	hit.Lifetime = NumberRange.new(0.2, 0.5)
	hit.Speed = NumberRange.new(10, 26)
	hit.SpreadAngle = Vector2.new(180, 180)
	hit.Size = NumberSequence.new(0.5, 0)
	hit.Color = ColorSequence.new(color or W.Minigun.Tracer)
	hit.LightEmission = 1
	hit.Enabled = false
	hit.Parent = beam
	hit:Emit(6)
end

local function explosion(position, radius, color)
	local sphere = Instance.new("Part")
	sphere.Shape = Enum.PartType.Ball
	sphere.Anchored = true
	sphere.CanCollide = false
	sphere.CanQuery = false
	sphere.CastShadow = false
	sphere.Material = Enum.Material.Neon
	sphere.Color = color
	sphere.Size = Vector3.new(4, 4, 4)
	sphere.CFrame = CFrame.new(position)
	sphere.Transparency = 0.15
	sphere.Parent = fxFolder

	local light = Instance.new("PointLight")
	light.Color = color
	light.Brightness = 12
	light.Range = radius * 3
	light.Parent = sphere

	local sparks = Instance.new("ParticleEmitter")
	sparks.Rate = 0
	sparks.Lifetime = NumberRange.new(0.4, 1.1)
	sparks.Speed = NumberRange.new(radius * 1.6, radius * 3.4)
	sparks.SpreadAngle = Vector2.new(180, 180)
	sparks.Size = NumberSequence.new(1.8, 0)
	sparks.Color = ColorSequence.new(color, Color3.fromRGB(90, 20, 0))
	sparks.LightEmission = 1
	sparks.Acceleration = Vector3.new(0, -40, 0)
	sparks.Parent = sphere
	sparks:Emit(40)

	local smoke = Instance.new("ParticleEmitter")
	smoke.Rate = 0
	smoke.Lifetime = NumberRange.new(1.2, 2.4)
	smoke.Speed = NumberRange.new(6, 18)
	smoke.SpreadAngle = Vector2.new(180, 180)
	smoke.Size = NumberSequence.new(radius * 0.6, radius * 1.8)
	smoke.Color = ColorSequence.new(Color3.fromRGB(60, 40, 34), Color3.fromRGB(24, 18, 18))
	smoke.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35),
		NumberSequenceKeypoint.new(1, 1) })
	smoke.Parent = sphere
	smoke:Emit(18)

	TweenService:Create(sphere, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(radius * 2, radius * 2, radius * 2),
		Transparency = 1,
	}):Play()
	TweenService:Create(light, TweenInfo.new(0.5), { Brightness = 0 }):Play()
	Debris:AddItem(sphere, 0.6)

	local dist = (camera.CFrame.Position - position).Magnitude
	state.shake = math.max(state.shake, math.clamp(radius / math.max(dist, 20) * 0.06, 0, 0.09))
	state.shakeSeed = math.random() * 100
end

FireFX.OnClientEvent:Connect(function(origin, target, color)
	tracer(origin, target, color)
end)

ExplosionFX.OnClientEvent:Connect(function(position, radius, color)
	explosion(position, radius, color)
end)

BombFX.OnClientEvent:Connect(function(position)
	local p = Instance.new("Part")
	p.Shape = Enum.PartType.Ball
	p.Size = Vector3.new(3, 3, 3)
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.Material = Enum.Material.Neon
	p.Color = Color3.fromRGB(255, 120, 40)
	p.Transparency = 0.4
	p.CFrame = CFrame.new(position)
	p.Parent = fxFolder
	TweenService:Create(p, TweenInfo.new(0.25), { Transparency = 1 }):Play()
	Debris:AddItem(p, 0.3)
end)

Banner.OnClientEvent:Connect(function(text, duration)
	ui:banner(text, duration)
end)

DamageFX.OnClientEvent:Connect(function(amount, reason)
	if amount > 0 then
		ui:damageFlash(false)
		state.shake = math.max(state.shake, 0.012 + math.min(amount / 140, 0.05))
		state.shakeSeed = math.random() * 100
		state.lastDamaged = os.clock()
		if reason == "crash" then
			ui:toast("ЖЁСТКОЕ СТОЛКНОВЕНИЕ", Color3.fromRGB(255, 190, 90))
		end
	else
		ui:damageFlash(true)
		ui:toast("+" .. math.floor(-amount) .. " РЕМОНТ", Color3.fromRGB(120, 255, 190))
	end
end)

-- ---------------------------------------------------------------------------
-- Управление (клавиатура + мышь + тач)
-- ---------------------------------------------------------------------------
local keys = {}

UserInputService.InputBegan:Connect(function(input, processed)
	if input.UserInputType == Enum.UserInputType.Keyboard then
		keys[input.KeyCode] = true
		if input.KeyCode == Enum.KeyCode.F then
			ui:callToggleCamera()
		end
		if input.KeyCode == Enum.KeyCode.One then
			RequestDrone:FireServer("scout")
		elseif input.KeyCode == Enum.KeyCode.Two then
			RequestDrone:FireServer("gunship")
		end
		if input.KeyCode == Enum.KeyCode.X then
			ui:callBomb()
		end
	elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
		keys.fire = true
	elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
		state.zoom = 1.6
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.Keyboard then
		keys[input.KeyCode] = false
	elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
		keys.fire = false
	elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
		state.zoom = 1
	end
end)

UserInputService.InputChanged:Connect(function(input, processed)
	if input.UserInputType == Enum.UserInputType.MouseWheel then
		state.camDist = math.clamp(state.camDist - input.Position.Z * 3, 16, 78)
	end
end)

if not UserInputService.TouchEnabled then
	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
end

local function readKeyboard(dt)
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

	if not UserInputService.TouchEnabled and UserInputService.MouseBehavior ~= Enum.MouseBehavior.LockCenter then
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	end
	local delta = UserInputService:GetMouseDelta()
	state.camYaw -= delta.X * 0.22
	state.camPitch = math.clamp(state.camPitch - delta.Y * 0.18, -72, 34)

	local virtual = ui:getVirtualInput()
	inputState.forward = math.clamp(f + virtual.y, -1, 1)
	inputState.right = math.clamp(r + virtual.x, -1, 1)
	inputState.up = math.clamp(u + virtual.up, -1, 1)
	inputState.yaw = math.clamp(y + virtual.yaw, -1, 1)
	inputState.fire = (keys.fire == true) or virtual.fire
end

-- ---------------------------------------------------------------------------
-- Сборка контроллера
-- ---------------------------------------------------------------------------
local function teardown()
	local d = state.drone
	state.drone = nil
	state.alive = false
	state.align = nil
	state.thrust = nil
	state.drag = nil
	if d then
		local primary = d.primary
		if primary and primary.Parent then
			for _, name in ipairs({ "DroneAlign", "DroneThrust", "DroneDrag", "DroneBody",
				"DroneThrustDir" }) do
				local inst = primary:FindFirstChild(name)
				if inst then
					inst:Destroy()
				end
			end
		end
	end
	ui:setDrone(nil)
end

local function buildController(model, droneId)
	teardown()

	local cfg = Config.getDrone(droneId)
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
	align.MaxTorque = math.clamp(primary.AssemblyMass * 3000, 120000, 4000000)
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

	-- пыль от винтов: красиво и сразу читается как «дрон»
	local dust = Instance.new("ParticleEmitter")
	dust.Name = "Downwash"
	dust.Rate = 0
	dust.Lifetime = NumberRange.new(0.5, 1.1)
	dust.Speed = NumberRange.new(18, 34)
	dust.SpreadAngle = Vector2.new(180, 180)
	dust.Size = NumberSequence.new(2.4, 0.2)
	dust.Color = ColorSequence.new(Color3.fromRGB(150, 120, 100), Color3.fromRGB(60, 44, 36))
	dust.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.6),
		NumberSequenceKeypoint.new(1, 1) })
	dust.Acceleration = Vector3.new(0, -14, 0)
	dust.EmissionDirection = Enum.NormalId.Bottom
	dust.Parent = primary

	local engine = Instance.new("PointLight")
	engine.Name = "EngineGlow"
	engine.Color = cfg.Tint
	engine.Brightness = 2
	engine.Range = 26
	engine.Parent = primary

	state.drone = {
		model = model,
		primary = primary,
		cfg = cfg,
		guns = guns,
		cameraPart = camPart,
		dust = dust,
		align = align,
		alignCFrame = primary.CFrame,
	}
	state.align = align
	state.thrust = thrust
	state.drag = drag
	state.mass = primary.AssemblyMass
	state.collective = P.CollectiveIdle
	state.tiltX = 0
	state.tiltZ = 0
	state.yaw = select(2, primary.CFrame:ToEulerAnglesYXZ())
	state.heat = 0
	state.overheated = false
	state.alive = true
	state.velocityPrev = primary.AssemblyLinearVelocity
	state.camYaw = state.yaw
	ui:setDrone(cfg)
	ui:setCameraMode(state.camMode)

	-- начальный «толчок» эффектов
	ui:toast("ДРОН ГОТОВ: " .. cfg.Title, cfg.Tint)
end

SetDrone.OnClientEvent:Connect(function(model, droneId)
	if model and model:IsA("Model") then
		buildController(model, droneId)
		-- ждём, пока сервер отдаст владение физикой
		task.delay(0.1, function()
			if state.drone and state.drone.model == model and model.PrimaryPart then
				state.mass = model.PrimaryPart.AssemblyMass
			end
		end)
	else
		teardown()
	end
end)

DroneLost.OnClientEvent:Connect(function(reason)
	teardown()
	local text = "ДРОН УНИЧТОЖЕН"
	if reason == "lava" then
		text = "ЛАВА! ДРОН РАСПЛАВИЛСЯ"
	elseif reason == "crash" then
		text = "ЖЁСТКАЯ ПОСАДКА"
	elseif reason == "switch" then
		text = "СМЕНА ДРОНА"
	end
	ui:banner(text, 3)
end)

-- ---------------------------------------------------------------------------
-- Физика: главный цикл
-- ---------------------------------------------------------------------------
local function windVector(dt)
	state.windPhase += dt * 0.35
	local t = os.clock() * 0.5
	return Vector3.new(
		math.noise(state.windPhase, t) * P.WindStrength,
		math.noise(state.windPhase + 10, t * 0.7) * P.WindStrength * 0.35,
		math.noise(state.windPhase + 20, t * 0.9) * P.WindStrength)
end

local downRay = RaycastParams.new()
downRay.FilterType = Enum.RaycastFilterType.Exclude
downRay.FilterDescendantsInstances = { fxFolder }

local groundFt = 0
local groundTimer = 0

local function stepPhysics(dt)
	local d = state.drone
	if not d or not d.primary or not d.primary.Parent then
		return
	end
	local primary = d.primary
	local cfg = d.cfg

	readKeyboard(dt)

	state.mass = math.max(primary.AssemblyMass, 1)
	local hover = state.mass * Workspace.Gravity

	-- ------------------------------------------------------------- курс
	local hasStick = math.abs(inputState.forward) + math.abs(inputState.right) > 0.08
	if inputState.yaw ~= 0 then
		state.yaw += inputState.yaw * P.YawRate * cfg.Agility * dt
		state.camYaw = lerpAngle(state.camYaw, state.yaw, dt * 3.4)
	elseif hasStick then
		state.yaw = lerpAngle(state.yaw, state.camYaw, dt * P.YawFollowLerp * cfg.Agility)
	end

	-- ------------------------------------------------------------- крен/тангаж
	local maxTilt = P.MaxTilt
	local targetPitch = -inputState.forward * maxTilt
	local targetRoll = inputState.right * maxTilt * 1.05
	-- крен в поворот для «живого» поведения
	targetRoll += math.clamp(inputState.yaw * 9, -9, 9)
	state.tiltX = lerp(state.tiltX, targetPitch, dt * P.TiltResponsiveness * cfg.Agility)
	state.tiltZ = lerp(state.tiltZ, targetRoll, dt * P.TiltResponsiveness * cfg.Agility)

	local desired = CFrame.fromEulerAnglesYXZ(
		math.rad(state.tiltX), math.rad(state.yaw), math.rad(state.tiltZ))

	if state.align then
		state.align.CFrame = CFrame.new(primary.Position) * desired
	end

	-- ------------------------------------------------------------- тяга
	local targetCollective = P.CollectiveIdle + inputState.up * 0.6
	if inputState.up > 0 then
		targetCollective = P.CollectiveUp
	elseif inputState.up < 0 then
		targetCollective = P.CollectiveDown
	end
	state.collective = lerp(state.collective, targetCollective, dt * P.CollectiveLerp)

	-- эффект экрана земли: у самой поверхности винты «отталкиваются»
	groundTimer += dt
	if groundTimer > 0.08 then
		groundTimer = 0
		local res = Workspace:Raycast(primary.Position, Vector3.new(0, -P.GroundEffectHeight, 0), downRay)
		groundFt = res and 1 or 0
	end
	local collective = state.collective * (groundFt > 0 and (1 + P.GroundEffectBoost) or 1)

	if state.thrust then
		state.thrust.Force = Vector3.new(0, hover * collective * cfg.Thrust, 0)
	end

	-- ------------------------------------------------------------- воздух
	local velocity = primary.AssemblyLinearVelocity
	local air = velocity - windVector(dt)
	local speed = air.Magnitude
	if state.drag then
		if speed > 0.05 then
			local coef = state.mass * (P.LinearDrag * speed + P.QuadDrag * speed * speed)
			state.drag.Force = -(air.Unit * coef)
		else
			state.drag.Force = Vector3.zero
		end
	end

	-- ------------------------------------------------------------- пыль/звук винтов
	if d.dust then
		d.dust.Rate = (state.collective > 1.02 and speed < 60) and 26 or 0
	end

	-- ------------------------------------------------------------- столкновения
	local deltaV = (velocity - state.velocityPrev).Magnitude
	local prevSpeed = state.velocityPrev.Magnitude
	if deltaV > 34 and prevSpeed > 42 and os.clock() - state.lastCrash > 0.75 then
		state.lastCrash = os.clock()
		local dmg = math.clamp((deltaV - 34) * P.CrashDamageScale, 0, 30)
		if dmg > 1 then
			CrashRemote:FireServer(dmg)
			state.shake = math.max(state.shake, math.min(dmg / 90, 0.06))
			state.shakeSeed = math.random() * 100
		end
	end
	state.velocityPrev = velocity

	-- ------------------------------------------------------------- оружие
	if inputState.fire then
		local now = os.clock()
		if now - state.lastFire >= W.Minigun.Interval and not state.overheated then
			state.lastFire = now
			FireRemote:FireServer(camera.CFrame.LookVector)
			state.heat = math.min(1, state.heat + W.Minigun.HeatPerShot)

			-- локальная отдача
			state.shake = math.max(state.shake, 0.004)
			state.shakeSeed = math.random() * 100

			-- дымок из ствола
			if d.dust then
				d.dust:Emit(1)
			end
		end
	end
	state.heat = math.max(0, state.heat - W.Minigun.CoolRate * dt)
	if state.heat >= 1 then
		state.overheated = true
	end
	if state.overheated and state.heat < 0.35 then
		state.overheated = false
	end

	-- ------------------------------------------------------------- HUD
	local health = d.model:GetAttribute("Health") or 0
	local maxHealth = d.model:GetAttribute("MaxHealth") or cfg.Health
	local stats = player:FindFirstChild("leaderstats")
	ui:update({
		health = health,
		maxHealth = maxHealth,
		heat = state.heat,
		overheated = state.overheated,
		speed = velocity.Magnitude,
		altitude = primary.Position.Y,
		score = player:GetAttribute("Score") or 0,
		kills = player:GetAttribute("Kills") or 0,
		wave = player:GetAttribute("Wave") or 1,
		collective = state.collective,
		bombReady = d.cfg.Bomb and (os.clock() - 0 >= 0) or false,
		alive = state.alive,
		ammo = math.floor((1 - state.heat) * 100),
	})
end

-- ---------------------------------------------------------------------------
-- Камера
-- ---------------------------------------------------------------------------
local camPos = Vector3.new(0, 90, 130)
local camLook = Vector3.new(0, 40, 0)

local function updateCamera(dt)
	local d = state.drone
	if not d or not d.primary or not d.primary.Parent then
		-- дрон уничтожен: плавно облетаем арену
		state.camYaw += dt * 4
		local radius = 260
		local pos = Vector3.new(math.sin(math.rad(state.camYaw)) * radius, 130,
			math.cos(math.rad(state.camYaw)) * radius)
		camPos = camPos:Lerp(pos, math.clamp(dt * 1.6, 0, 1))
		camLook = camLook:Lerp(Vector3.new(0, 20, 0), math.clamp(dt * 1.6, 0, 1))
		camera.CFrame = CFrame.lookAt(camPos, camLook) * shaking()
		camera.Focus = CFrame.new(camLook)
		return
	end

	local primary = d.primary
	local velocity = primary.AssemblyLinearVelocity
	local speed = velocity.Magnitude

	if state.camMode == "fpv" then
		local camPart = d.cameraPart
		local base = primary.CFrame
		if camPart then
			base = camPart.CFrame
		end
		local fwd = base.LookVector
		local pos = base.Position + fwd * 3.2 + base.UpVector * 0.35
		camera.CFrame = CFrame.lookAt(pos, pos + fwd * 100, base.UpVector) * shaking()
		camera.FieldOfView = 88
		camera.Focus = CFrame.new(pos + fwd * 60)
	else
		local dist = state.camDist * state.zoom * (1 + math.clamp(speed / 900, 0, 0.14))
		local yaw = math.rad(state.camYaw)
		local pitch = math.rad(state.camPitch)
		local rot = CFrame.fromEulerAnglesYXZ(pitch + 0.12, yaw, 0)
		local targetPos = primary.Position + (rot * Vector3.new(0, 2.2, dist))
		-- не залезать в геометрию
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { d.model, fxFolder }
		local res = Workspace:Raycast(primary.Position, targetPos - primary.Position, params)
		if res then
			targetPos = res.Position + res.Normal * 2.4
		end

		camPos = camPos:Lerp(targetPos, math.clamp(dt * 6.5, 0, 1))
		local lookAt = primary.Position + velocity * 0.09 + Vector3.new(0, 1.5, 0)
		camLook = camLook:Lerp(lookAt, math.clamp(dt * 9, 0, 1))
		camera.CFrame = CFrame.lookAt(camPos, camLook) * shaking()
		camera.FieldOfView = lerp(camera.FieldOfView, 74 + math.clamp(speed / 8, 0, 14), dt * 3)
		camera.Focus = CFrame.new(camLook)
	end
end

RunService.Heartbeat:Connect(function(dt)
	if state.alive then
		stepPhysics(dt)
	end
	updateCamera(dt)
	state.shake *= 0.92
end)

-- ---------------------------------------------------------------------------
-- Стартовый экран / ожидание
-- ---------------------------------------------------------------------------
ui:banner("ЛАВОВЫЙ КАНЬОН", 4)
task.delay(4.5, function()
	ui:banner("WASD — полёт    SPACE — вверх    ЛКМ — огонь", 4)
end)
