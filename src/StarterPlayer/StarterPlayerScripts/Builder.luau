--!nonstrict
--[[
	Builder -- строительство из досок для выживших.

	Сетка, призрачная доска перед камерой (зелёная -- можно, красная -- нет),
	поворот колесом/R, три типа: стена, настил, пандус. Сервер проверяет
	расстояние и лимит деталей, поэтому читерить не получится.
]]

local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Builder = {}
Builder.__index = Builder

function Builder.new(config, callbacks)
	local self = setmetatable({}, Builder)
	self.cfg = config
	self.callbacks = callbacks or {}
	self.enabled = false
	self.plankIndex = 1
	self.yaw = 0
	self.ghost = nil
	self.valid = false
	self.targetCF = nil
	return self
end

function Builder:getPlank()
	local list = self.cfg.PlankSizes
	return list[(self.plankIndex - 1) % #list + 1]
end

function Builder:cycle(delta)
	local list = self.cfg.PlankSizes
	self.plankIndex = (self.plankIndex - 1 + (delta or 1)) % #list + 1
	self:refresh()
	return self:getPlank()
end

function Builder:setPlank(id)
	local list = self.cfg.PlankSizes
	for i, plank in ipairs(list) do
		if plank.Id == id then
			self.plankIndex = i
			self:refresh()
			return plank
		end
	end
	return self:getPlank()
end

function Builder:refresh()
	local plank = self:getPlank()
	if self.ghost then
		self.ghost.Size = plank.Size
		self.ghost.Color = plank.Color
	end
end

function Builder:ensureGhost()
	if self.ghost and self.ghost.Parent then
		return
	end
	local plank = self:getPlank()
	local ghost = Instance.new("Part")
	ghost.Name = "PlankGhost"
	ghost.Size = plank.Size
	ghost.Color = plank.Color
	ghost.Material = self.cfg.Material
	ghost.Anchored = true
	ghost.CanCollide = false
	ghost.CanQuery = false
	ghost.CanTouch = false
	ghost.CastShadow = false
	ghost.Transparency = 0.55
	ghost.Parent = Workspace
	self.ghost = ghost
end

function Builder:setEnabled(value)
	self.enabled = value
	if value then
		self:ensureGhost()
		self:refresh()
	elseif self.ghost then
		self.ghost:Destroy()
		self.ghost = nil
	end
end

function Builder:rotate(deg)
	self.yaw = (self.yaw + (deg or 45)) % 360
end

-- считает CFrame установки по лучу камеры
function Builder:update(dt, camera)
	if not self.enabled then
		return
	end
	self:ensureGhost()
	local plank = self:getPlank()
	local character = self.callbacks.getCharacter and self.callbacks.getCharacter()

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude = {}
	if character then
		table.insert(exclude, character)
	end
	if self.ghost then
		table.insert(exclude, self.ghost)
	end
	local fx = Workspace:FindFirstChild("ClientFX")
	if fx then
		table.insert(exclude, fx)
	end
	params.FilterDescendantsInstances = exclude

	local origin = camera.CFrame.Position
	local dir = camera.CFrame.LookVector
	local hit = Workspace:Raycast(origin, dir * (self.cfg.Range + 26), params)
	if not hit then
		self.valid = false
		self.targetCF = nil
		self.ghost.Transparency = 1
		return
	end

	local pos = hit.Position
	local normal = hit.Normal
	if plank.Id == "floor" then
		pos = pos + Vector3.new(0, plank.Size.Y / 2 + 0.06, 0)
	else
		-- прижимаем доску к поверхности по нормали
		local push = math.abs(normal.X) * plank.Size.X / 2
			+ math.abs(normal.Z) * plank.Size.Z / 2
			+ math.abs(normal.Y) * plank.Size.Y / 2
		pos = pos + normal * (push + 0.06)
	end
	-- сетка
	local step = self.cfg.GridStep
	pos = Vector3.new(
		math.floor(pos.X / step + 0.5) * step,
		math.floor(pos.Y / step + 0.5) * step,
		math.floor(pos.Z / step + 0.5) * step)

	local cf
	if plank.Id == "floor" then
		cf = CFrame.new(pos) * CFrame.Angles(0, math.rad(self.yaw), 0)
	elseif plank.Id == "ramp" then
		local yaw = math.degrees(math.atan2(-dir.X, -dir.Z)) + self.yaw
		cf = CFrame.new(pos) * CFrame.Angles(0, math.rad(yaw), 0)
			* CFrame.Angles(math.rad(-32), 0, 0)
	else
		local flat = Vector3.new(normal.X, 0, normal.Z)
		if flat.Magnitude < 0.2 then
			flat = -dir
		end
		flat = flat.Unit
		local yaw = math.degrees(math.atan2(-flat.X, -flat.Z)) + self.yaw
		cf = CFrame.new(pos) * CFrame.Angles(0, math.rad(yaw), 0)
	end

	self.targetCF = cf
	self.valid = true
	if character then
		local root = character:FindFirstChild("HumanoidRootPart")
		if root and (pos - root.Position).Magnitude > self.cfg.Range then
			self.valid = false
		end
	end

	self.ghost.Size = plank.Size
	self.ghost.CFrame = cf
	self.ghost.Transparency = 0.5
	self.ghost.Color = self.valid and Color3.fromRGB(130, 255, 170)
		or Color3.fromRGB(255, 110, 110)
end

function Builder:place()
	if not self.enabled or not self.valid or not self.targetCF then
		return false
	end
	if self.callbacks.place then
		self.callbacks.place(self:getPlank().Id, self.targetCF)
	end
	return true
end

return Builder
