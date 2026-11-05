--!nonstrict
--[[
	Effects -- все «спецэффекты» клиента в одном месте:
	трассеры, взрывы, вспышки выстрелов, попадания, тряска камеры,
	всплывающие числа урона и экранные вспышки.
]]

local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Effects = {}

local folder = Instance.new("Folder")
folder.Name = "ClientFX"
folder.Parent = Workspace

local shakeAmount = 0
local shakeSeed = math.random() * 100

function Effects.addShake(amount)
	shakeAmount = math.min(math.max(shakeAmount, amount), 0.16)
	shakeSeed = math.random() * 100
end

function Effects.shakeCFrame(dt)
	if shakeAmount <= 0.0005 then
		shakeAmount = 0
		return CFrame.new()
	end
	local t = os.clock()
	local cf = CFrame.Angles(
		math.noise(shakeSeed, t * 22) * shakeAmount,
		math.noise(shakeSeed + 5, t * 19) * shakeAmount,
		math.noise(shakeSeed + 9, t * 17) * shakeAmount * 0.6)
	shakeAmount *= math.clamp(1 - dt * 6, 0, 1)
	return cf
end

function Effects.folder()
	return folder
end

-- --------------------------------------------------------------------------- --
-- Трассер
-- --------------------------------------------------------------------------- --
function Effects.tracer(origin, target, color, thickness)
	local delta = target - origin
	local dist = delta.Magnitude
	if dist < 0.8 then
		return
	end
	local beam = Instance.new("Part")
	beam.Name = "Tracer"
	beam.Anchored = true
	beam.CanCollide = false
	beam.CanQuery = false
	beam.CastShadow = false
	beam.Material = Enum.Material.Neon
	beam.Color = color or Color3.fromRGB(255, 220, 120)
	beam.Size = Vector3.new(thickness or 0.22, thickness or 0.22, dist)
	beam.CFrame = CFrame.lookAt(origin + delta / 2, target)
	beam.Transparency = 0.05
	beam.Parent = folder
	TweenService:Create(beam, TweenInfo.new(0.09), { Transparency = 1 }):Play()
	Debris:AddItem(beam, 0.14)

	local flash = Instance.new("PointLight")
	flash.Color = color or Color3.fromRGB(255, 220, 120)
	flash.Brightness = 4
	flash.Range = 24
	flash.Parent = beam
end

-- --------------------------------------------------------------------------- --
-- Вспышка выстрела
-- --------------------------------------------------------------------------- --
function Effects.muzzle(origin, color)
	local spark = Instance.new("Part")
	spark.Shape = Enum.PartType.Ball
	spark.Size = Vector3.new(1.6, 1.6, 1.6)
	spark.Material = Enum.Material.Neon
	spark.Color = color or Color3.fromRGB(255, 220, 150)
	spark.Anchored = true
	spark.CanCollide = false
	spark.CanQuery = false
	spark.CastShadow = false
	spark.CFrame = CFrame.new(origin)
	spark.Parent = folder
	local light = Instance.new("PointLight")
	light.Color = color or Color3.fromRGB(255, 200, 120)
	light.Brightness = 6
	light.Range = 22
	light.Parent = spark
	TweenService:Create(spark, TweenInfo.new(0.07), {
		Size = Vector3.new(4.4, 4.4, 4.4),
		Transparency = 1,
	}):Play()
	Debris:AddItem(spark, 0.1)
end

-- --------------------------------------------------------------------------- --
-- Взрыв
-- --------------------------------------------------------------------------- --
function Effects.explosion(position, radius, color)
	color = color or Color3.fromRGB(255, 150, 60)
	radius = radius or 18

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
	sphere.Transparency = 0.1
	sphere.Parent = folder

	local light = Instance.new("PointLight")
	light.Color = color
	light.Brightness = 14
	light.Range = radius * 4
	light.Parent = sphere

	local sparks = Instance.new("ParticleEmitter")
	sparks.Rate = 0
	sparks.Lifetime = NumberRange.new(0.4, 1.2)
	sparks.Speed = NumberRange.new(radius * 1.4, radius * 3.2)
	sparks.SpreadAngle = Vector2.new(180, 180)
	sparks.Size = NumberSequence.new(1.9, 0)
	sparks.Color = ColorSequence.new(color, Color3.fromRGB(70, 16, 0))
	sparks.LightEmission = 1
	sparks.Acceleration = Vector3.new(0, -42, 0)
	sparks.Parent = sphere
	sparks:Emit(46)

	local smoke = Instance.new("ParticleEmitter")
	smoke.Rate = 0
	smoke.Lifetime = NumberRange.new(1.2, 2.6)
	smoke.Speed = NumberRange.new(6, 20)
	smoke.SpreadAngle = Vector2.new(180, 180)
	smoke.Size = NumberSequence.new(radius * 0.5, radius * 1.9)
	smoke.Color = ColorSequence.new(Color3.fromRGB(56, 44, 40), Color3.fromRGB(20, 16, 16))
	smoke.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.4),
		NumberSequenceKeypoint.new(1, 1),
	})
	smoke.Parent = sphere
	smoke:Emit(20)

	local ring = Instance.new("Part")
	ring.Shape = Enum.PartType.Cylinder
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CastShadow = false
	ring.Material = Enum.Material.Neon
	ring.Color = color
	ring.Size = Vector3.new(0.6, 6, 6)
	ring.CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90))
	ring.Transparency = 0.15
	ring.Parent = folder
	TweenService:Create(ring, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.6, radius * 3, radius * 3),
		Transparency = 1,
	}):Play()
	Debris:AddItem(ring, 0.55)

	TweenService:Create(sphere, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(radius * 2.2, radius * 2.2, radius * 2.2),
		Transparency = 1,
	}):Play()
	TweenService:Create(light, TweenInfo.new(0.5), { Brightness = 0 }):Play()
	Debris:AddItem(sphere, 0.62)

	local cam = Workspace.CurrentCamera
	if cam then
		local dist = (cam.CFrame.Position - position).Magnitude
		Effects.addShake(math.clamp(radius / math.max(dist, 24) * 0.05, 0, 0.07))
	end
end

-- --------------------------------------------------------------------------- --
-- Попадание
-- --------------------------------------------------------------------------- --
function Effects.impact(position, normal, color)
	local p = Instance.new("Part")
	p.Shape = Enum.PartType.Ball
	p.Size = Vector3.new(0.7, 0.7, 0.7)
	p.Material = Enum.Material.Neon
	p.Color = color or Color3.fromRGB(255, 226, 160)
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CastShadow = false
	p.CFrame = CFrame.new(position + (normal or Vector3.yAxis) * 0.2)
	p.Parent = folder
	local burst = Instance.new("ParticleEmitter")
	burst.Rate = 0
	burst.Lifetime = NumberRange.new(0.15, 0.4)
	burst.Speed = NumberRange.new(8, 22)
	burst.SpreadAngle = Vector2.new(180, 180)
	burst.Size = NumberSequence.new(0.42, 0)
	burst.Color = ColorSequence.new(color or Color3.fromRGB(255, 226, 160))
	burst.LightEmission = 1
	burst.Parent = p
	burst:Emit(7)
	Debris:AddItem(p, 0.42)
end

-- --------------------------------------------------------------------------- --
-- Всплывающий урон
-- --------------------------------------------------------------------------- --
function Effects.damageNumber(position, amount, color)
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = Vector3.new(0.2, 0.2, 0.2)
	part.CFrame = CFrame.new(position)
	part.Parent = folder

	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromScale(6, 3)
	gui.AlwaysOnTop = true
	gui.Parent = part

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = "+" .. tostring(math.floor(amount))
	label.TextColor3 = color or Color3.fromRGB(255, 236, 180)
	label.TextScaled = true
	label.Font = Enum.Font.GothamBlack
	label.TextStrokeTransparency = 0.4
	label.Parent = gui

	TweenService:Create(part, TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		CFrame = CFrame.new(position + Vector3.new(0, 12, 0)),
	}):Play()
	TweenService:Create(label, TweenInfo.new(0.7), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	Debris:AddItem(part, 0.75)
end

return Effects
