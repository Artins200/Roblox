--!nonstrict
--[[
	FpsWeapon -- оружие выжившего от первого лица.

	Собранный кодом «вид от первого лица»: винтовка, руки, нож. Никаких
	загруженных анимаций -- всё процедурное: покачивание при шаге, инерция
	мыши, отдача, перезарядка с провалом ствола, замах ножом по дуге,
	вспышка выстрела, трассер и искры.

	Стрельба: клиент рисует эффекты и отправляет направление на сервер,
	сервер считает попадание (античит: клиент не может наносить урон сам).
]]

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")

local Effects = require(script.Parent:WaitForChild("Effects"))

local FpsWeapon = {}
FpsWeapon.__index = FpsWeapon

local SKIN = Color3.fromRGB(226, 178, 140)
local SLEEVE = Color3.fromRGB(58, 74, 62)
local GUN_BODY = Color3.fromRGB(46, 48, 54)
local GUN_METAL = Color3.fromRGB(96, 100, 110)
local GUN_WOOD = Color3.fromRGB(96, 66, 40)
local NEON = Color3.fromRGB(120, 235, 255)

-- --------------------------------------------------------------------------- --
local function makePart(name, size, color, material, parent)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = material or Enum.Material.Metal
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Massless = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

-- --------------------------------------------------------------------------- --
function FpsWeapon.new(cfg, remotes, callbacks)
	local self = setmetatable({}, FpsWeapon)
	self.cfg = cfg
	self.rifle = remotes.GunFire
	self.meleeRemote = remotes.Melee
	self.reloadRemote = remotes.Reload
	self.callbacks = callbacks or {}
	self.model = nil
	self.parts = {}          -- { part = Part, cf = CFrame, group = "gun"|"knife" }
	self.ammo = cfg.Magazine
	self.magazine = cfg.Magazine
	self.lastFire = 0
	self.recoil = 0
	self.bob = 0
	self.sway = Vector2.zero
	self.reloadT = -1
	self.meleeT = -1
	self.muzzle = nil
	self.muzzleLight = nil
	self.enabled = false
	return self
end

function FpsWeapon:build()
	if self.model then
		return
	end
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local model = Instance.new("Model")
	model.Name = "Viewmodel"
	model.Parent = camera
	self.model = model

	local function add(name, size, offset, color, material, rot, group)
		local part = makePart(name, size, color, material, model)
		local cf = CFrame.new(offset) * (rot or CFrame.new())
		table.insert(self.parts, { part = part, cf = cf, group = group or "gun" })
		return part
	end

	-- корпус винтовки
	add("Body", Vector3.new(0.46, 0.56, 2.3), Vector3.new(0.86, -0.86, -1.5), GUN_BODY)
	add("Foregrip", Vector3.new(0.4, 0.34, 1.1), Vector3.new(0.86, -0.72, -2.6), GUN_METAL)
	add("Barrel", Vector3.new(0.15, 0.15, 1.9), Vector3.new(0.86, -0.74, -3.6), GUN_METAL)
	add("Muzzle", Vector3.new(0.3, 0.3, 0.44), Vector3.new(0.86, -0.74, -4.5), GUN_BODY)
	add("Stock", Vector3.new(0.32, 0.46, 1.1), Vector3.new(0.86, -0.92, -0.2), GUN_WOOD)
	add("Mag", Vector3.new(0.32, 1.0, 0.46), Vector3.new(0.86, -1.3, -1.2), GUN_BODY)
	add("Grip", Vector3.new(0.28, 0.66, 0.36), Vector3.new(0.86, -1.18, -0.86), GUN_WOOD,
		CFrame.Angles(math.rad(-14), 0, 0))
	add("Scope", Vector3.new(0.24, 0.28, 1.0), Vector3.new(0.86, -0.42, -1.9), GUN_BODY)
	add("ScopeGlass", Vector3.new(0.2, 0.2, 0.06), Vector3.new(0.86, -0.42, -2.42), NEON,
		Enum.Material.Neon)
	add("Rail", Vector3.new(0.08, 0.08, 1.6), Vector3.new(0.86, -0.55, -2.2), NEON,
		Enum.Material.Neon)
	add("Sight", Vector3.new(0.1, 0.16, 0.1), Vector3.new(0.86, -0.6, -4.1), NEON,
		Enum.Material.Neon)

	-- руки
	add("RightArm", Vector3.new(0.42, 0.42, 1.5), Vector3.new(1.02, -1.42, -0.72), SKIN,
		Enum.Material.SmoothPlastic, CFrame.Angles(math.rad(18), math.rad(-6), 0))
	add("RightSleeve", Vector3.new(0.5, 0.5, 0.9), Vector3.new(1.08, -1.66, 0.28), SLEEVE,
		Enum.Material.Fabric)
	add("LeftArm", Vector3.new(0.4, 0.4, 1.4), Vector3.new(0.52, -1.12, -2.5), SKIN,
		Enum.Material.SmoothPlastic, CFrame.Angles(math.rad(-8), math.rad(28), math.rad(-16)))
	add("LeftSleeve", Vector3.new(0.48, 0.48, 0.8), Vector3.new(0.28, -0.98, -3.2), SLEEVE,
		Enum.Material.Fabric)

	-- нож (виден только в замахе)
	add("Blade", Vector3.new(0.07, 0.42, 1.5), Vector3.new(0.95, -1.0, -1.6),
		Color3.fromRGB(198, 208, 220), Enum.Material.Metal, CFrame.Angles(math.rad(6), 0, 0), "knife")
	add("BladeEdge", Vector3.new(0.03, 0.14, 1.45), Vector3.new(0.95, -1.22, -1.6), NEON,
		Enum.Material.Neon, nil, "knife")
	add("Hilt", Vector3.new(0.18, 0.18, 0.5), Vector3.new(0.95, -1.0, -0.72), GUN_WOOD, nil, nil,
		"knife")
	add("Guard", Vector3.new(0.34, 0.1, 0.12), Vector3.new(0.95, -1.0, -1.0), GUN_METAL, nil, nil,
		"knife")

	self:muzzleSetup()
	self:setGroupVisible("knife", false)
end

function FpsWeapon:muzzleSetup()
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local flash = makePart("MuzzleFlash", Vector3.new(0.7, 0.7, 0.7),
		Color3.fromRGB(255, 226, 150), Enum.Material.Neon, self.model)
	flash.Shape = Enum.PartType.Ball
	flash.Transparency = 1
	flash.CFrame = camera.CFrame * CFrame.new(0.86, -0.74, -4.7)
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 210, 140)
	light.Brightness = 0
	light.Range = 26
	light.Parent = flash
	self.muzzle = flash
	self.muzzleLight = light
end

function FpsWeapon:setGroupVisible(group, visible)
	for _, entry in ipairs(self.parts) do
		if entry.group == group then
			entry.part.Transparency = visible and 0 or 1
		end
	end
	if group == "gun" and self.muzzle then
		self.muzzle.Transparency = visible and 1 or 1
	end
end

function FpsWeapon:attach()
	self:build()
	self.enabled = true
	self:setGroupVisible("gun", true)
	self.ammo = self.magazine
	self.reloadT = -1
	if self.callbacks.onAmmo then
		self.callbacks.onAmmo(self.ammo, self.magazine, false)
	end
	local character = self.callbacks.getCharacter and self.callbacks.getCharacter()
	if character then
		for _, part in ipairs(character:GetDescendants()) do
			if part:IsA("BasePart") then
				part.LocalTransparencyModifier = 1
			end
		end
	end
end

function FpsWeapon:detach()
	self.enabled = false
	if self.model then
		self.model:Destroy()
		self.model = nil
	end
	self.parts = {}
	self.muzzle = nil
	self.muzzleLight = nil
end

-- --------------------------------------------------------------------------- --
-- Стрельба
-- --------------------------------------------------------------------------- --
function FpsWeapon:reload()
	if self.reloadT >= 0 or self.ammo >= self.magazine then
		return
	end
	self.reloadT = 0
	if self.reloadRemote then
		self.reloadRemote:FireServer()
	end
end

function FpsWeapon:fire()
	local camera = Workspace.CurrentCamera
	if not self.enabled or not camera or self.reloadT >= 0 then
		return
	end
	if os.clock() - self.lastFire < self.cfg.Interval then
		return
	end
	if self.ammo <= 0 then
		self:reload()
		return
	end
	self.lastFire = os.clock()
	self.ammo -= 1
	self.recoil = 1

	local origin = camera.CFrame.Position
	local dir = camera.CFrame.LookVector
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude = { Effects.folder() }
	local character = self.callbacks.getCharacter and self.callbacks.getCharacter()
	if character then
		table.insert(exclude, character)
	end
	if self.model then
		table.insert(exclude, self.model)
	end
	params.FilterDescendantsInstances = exclude
	local hit = Workspace:Raycast(origin + dir * 1.5, dir * (self.cfg.Range + 40), params)
	local endpoint = hit and hit.Position or (origin + dir * self.cfg.Range)

	local muzzlePos = camera.CFrame * CFrame.new(0.86, -0.74, -4.6)
	Effects.tracer(muzzlePos.Position, endpoint, Color3.fromRGB(255, 240, 190), 0.14)
	Effects.muzzle(muzzlePos.Position, Color3.fromRGB(255, 226, 150))
	if hit then
		Effects.impact(hit.Position, hit.Normal)
	end
	Effects.addShake(0.012)

	if self.muzzle then
		self.muzzle.Transparency = 0.05
		self.muzzleLight.Brightness = 7
		task.delay(0.05, function()
			if self.muzzle then
				self.muzzle.Transparency = 1
				self.muzzleLight.Brightness = 0
			end
		end)
	end

	self.rifle:FireServer(dir)
	if self.callbacks.onAmmo then
		self.callbacks.onAmmo(self.ammo, self.magazine, self.reloadT >= 0)
	end
	if self.ammo <= 0 then
		task.delay(0.25, function()
			self:reload()
		end)
	end
end

function FpsWeapon:melee()
	if not self.enabled or self.meleeT >= 0 then
		return
	end
	self.meleeT = 0
	self:setGroupVisible("gun", false)
	self:setGroupVisible("knife", true)
	self.meleeRemote:FireServer()

	local camera = Workspace.CurrentCamera
	if camera then
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		local character = self.callbacks.getCharacter and self.callbacks.getCharacter()
		local exclude = { Effects.folder() }
		if character then
			table.insert(exclude, character)
		end
		params.FilterDescendantsInstances = exclude
		local origin = camera.CFrame.Position
		local hit = Workspace:Raycast(origin, camera.CFrame.LookVector * 10, params)
		if hit then
			Effects.impact(hit.Position, hit.Normal, Color3.fromRGB(255, 200, 200))
		end
	end
end

-- --------------------------------------------------------------------------- --
-- Анимация
-- --------------------------------------------------------------------------- --
function FpsWeapon:update(dt, firing)
	if not self.enabled or not self.model then
		return
	end
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end

	if firing then
		self:fire()
	end

	-- отдача
	self.recoil = math.max(0, self.recoil - dt * 6)
	local kick = self.recoil * self.recoil

	-- покачивание при ходьбе
	local character = self.callbacks.getCharacter and self.callbacks.getCharacter()
	local speed = 0
	if character then
		local hum = character:FindFirstChildOfClass("Humanoid")
		if hum then
			speed = (hum.MoveDirection.Magnitude > 0.1) and hum.WalkSpeed or 0
		end
	end
	self.bob += dt * (speed > 0 and 9 or 2.2)
	local bobX = math.sin(self.bob) * (speed > 0 and 0.035 or 0.008)
	local bobY = math.abs(math.cos(self.bob)) * (speed > 0 and 0.03 or 0.006)

	-- инерция мыши
	local delta = Vector2.zero
	if not UserInputService.TouchEnabled then
		local d = UserInputService:GetMouseDelta()
		delta = Vector2.new(d.X, d.Y)
	end
	self.sway = self.sway:Lerp(delta * 0.0016, math.clamp(dt * 9, 0, 1))
	self.sway = Vector2.new(math.clamp(self.sway.X, -0.08, 0.08),
		math.clamp(self.sway.Y, -0.08, 0.08))

	-- перезарядка
	local reloadOffset = 0
	local reloadRoll = 0
	local magDrop = 0
	if self.reloadT >= 0 then
		self.reloadT += dt / self.cfg.Reload
		local t = math.clamp(self.reloadT, 0, 1)
		local arc = math.sin(t * math.pi)
		reloadOffset = -arc * 0.55
		reloadRoll = arc * 0.9
		magDrop = (t > 0.25 and t < 0.75) and math.sin((t - 0.25) / 0.5 * math.pi) * 0.9 or 0
		if self.reloadT >= 1 then
			self.reloadT = -1
			self.ammo = self.magazine
			if self.callbacks.onAmmo then
				self.callbacks.onAmmo(self.ammo, self.magazine, false)
			end
		elseif self.callbacks.onAmmo then
			self.callbacks.onAmmo(self.ammo, self.magazine, true)
		end
	end

	-- замах ножом
	local knifeCF = nil
	if self.meleeT >= 0 then
		self.meleeT += dt / 0.42
		local t = math.clamp(self.meleeT, 0, 1)
		local swing = math.sin(t * math.pi)
		local side = 1 - t * 1.6
		knifeCF = CFrame.new(0.6 + side * 0.5, -0.7 + swing * 0.35, -1.2 - swing * 0.9)
			* CFrame.Angles(math.rad(-30 + swing * 60), math.rad(-70 + t * 110),
				math.rad(20 - t * 70))
		if self.meleeT >= 1 then
			self.meleeT = -1
			self:setGroupVisible("knife", false)
			self:setGroupVisible("gun", true)
		end
	end

	local base = CFrame.new(
		bobX + self.sway.X,
		-bobY + self.sway.Y + reloadOffset - kick * 0.1,
		0.16 + kick * 0.35)
		* CFrame.Angles(math.rad(-reloadRoll * 26 - kick * 4), math.rad(reloadRoll * 14),
			math.rad(reloadRoll * 22))
		* CFrame.Angles(-self.sway.Y * 1.6, -self.sway.X * 1.6, self.sway.X * 2.2)

	for _, entry in ipairs(self.parts) do
		local cf = base * entry.cf
		if entry.group == "knife" and knifeCF then
			cf = base * knifeCF
		elseif entry.group == "knife" then
			cf = base * entry.cf
		elseif entry.part.Name == "Mag" then
			cf = base * entry.cf * CFrame.new(0, -magDrop, 0)
		end
		entry.part.CFrame = camera.CFrame * cf
	end
	if self.muzzle then
		self.muzzle.CFrame = camera.CFrame * base * CFrame.new(0.86, -0.74, -4.7)
	end
end

return FpsWeapon
