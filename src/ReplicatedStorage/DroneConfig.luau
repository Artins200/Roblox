--!nonstrict
--[[
	DroneConfig -- единый конфиг игры «ДРОНЫ» (сервер + клиент).

	Всё, что можно крутить, крутится здесь: физика полёта, дроны, оружие,
	строительство, тайминги раундов и голосования.
]]

local DroneConfig = {}

DroneConfig.GameName = "ДРОНЫ"
DroneConfig.GameSubtitle = "АРЕНА НАД БЕЗДНОЙ"

-- --------------------------------------------------------------------------- //
-- Раунды, лобби, голосование
-- --------------------------------------------------------------------------- //
DroneConfig.Round = {
	VoteTime = 25,          -- сколько длится голосование за режим
	RoundTime = 15 * 60,    -- максимум раунда; дальше -- новое голосование (15 минут)
	EndDelay = 9,           -- пауза на экране итогов
	RespawnTime = 4.5,      -- респавн в режимах без выбывания
	WinScore = 30,          -- киллы/очки до победы в командных режимах
	HideTime = 7 * 60,      -- длительность пряток
	SurviveTime = 6 * 60,   -- сколько должны выжить выжившие
	MinPlayersForPVP = 2,   -- меньше -- включается соло-сценарий
	Intermission = 6,       -- пауза между раундом и голосованием
}

DroneConfig.Roles = {
	{ Id = "auto", Title = "ПО РЕЖИМУ", Desc = "Сервер сам решит, за кого тебя поставить" },
	{ Id = "drone", Title = "ДРОН", Desc = "Полёт, миниганы, бомба. Лучший выбор." },
	{ Id = "survivor", Title = "ВЫЖИВШИЙ", Desc = "Винтовка, нож, доски для укреплений" },
	{ Id = "random", Title = "СЛУЧАЙНО", Desc = "Как повезёт" },
}

-- --------------------------------------------------------------------------- //
-- Дроны (модели автора лежат в ServerStorage)
-- --------------------------------------------------------------------------- //
DroneConfig.Drones = {
	{
		Id = "scout",
		Title = "РАЗВЕДЧИК",
		Template = "Беспилотник",
		Health = 110,
		Thrust = 1.16,
		Agility = 1.18,
		Armor = 0.9,
		Bomb = false,
		Tint = Color3.fromRGB(120, 225, 255),
		Description = "Лёгкий перехватчик: два минигана, резкий разгон.",
	},
	{
		Id = "gunship",
		Title = "ШТУРМОВИК",
		Template = "скинБеспилотник",
		Health = 160,
		Thrust = 0.94,
		Agility = 0.9,
		Armor = 1.22,
		Bomb = true,
		Tint = Color3.fromRGB(255, 150, 60),
		Description = "Тяжёлый корпус и бомба в брюхе. Медленнее, но злее.",
	},
}

DroneConfig.DefaultDrone = "scout"

-- --------------------------------------------------------------------------- //
-- Физика полёта (это сердце игры -- не трогать без причины)
-- --------------------------------------------------------------------------- //
DroneConfig.Physics = {
	MaxTilt = 40,
	TiltResponsiveness = 8.0,
	YawRate = 155,
	YawFollowLerp = 2.8,
	CollectiveIdle = 1.0,
	CollectiveUp = 1.62,
	CollectiveDown = 0.22,
	CollectiveLerp = 3.6,
	LinearDrag = 0.145,
	QuadDrag = 0.0024,
	GroundEffectHeight = 16,
	GroundEffectBoost = 0.16,
	WindStrength = 6.0,
	MaxSpeed = 275,
	CrashSpeed = 100,
	CrashDamageScale = 0.5,
	MaxHealthDroneAlt = 340,  -- выше -- разряженный воздух, тяга слабее
}

-- --------------------------------------------------------------------------- //
-- Оружие дрона
-- --------------------------------------------------------------------------- //
DroneConfig.Weapons = {
	Minigun = {
		Damage = 8,
		Interval = 0.055,
		Range = 1500,
		Spread = 0.9,
		HeatPerShot = 0.021,
		CoolRate = 0.17,
		Tracer = Color3.fromRGB(255, 220, 120),
	},
	Bomb = {
		Damage = 95,
		Radius = 36,
		Cooldown = 6.0,
	},
}

-- --------------------------------------------------------------------------- //
-- Оружие выживших
-- --------------------------------------------------------------------------- //
DroneConfig.Infantry = {
	Rifle = {
		Damage = 16,
		Interval = 0.115,
		Range = 420,
		Spread = 1.2,
		Magazine = 30,
		Reload = 1.9,
		Kick = 0.9,
	},
	Melee = {
		Damage = 62,
		Range = 9.5,
		Cooldown = 0.72,
	},
	Health = 100,
	WalkSpeed = 19,
	JumpPower = 56,
	DroneDamageToSurvivor = 8,          -- урон минигана дрона по выжившему
	DroneBombDamageToSurvivor = 130,
	SurvivorDamageToDrone = 1.0,        -- множитель урона винтовки по дрону
}

-- --------------------------------------------------------------------------- //
-- Строительство досками
-- --------------------------------------------------------------------------- //
DroneConfig.Building = {
	MaxParts = 30,
	PlankSizes = {
		{ Id = "wall", Title = "СТЕНА", Size = Vector3.new(12, 9, 0.7), Color = Color3.fromRGB(150, 110, 70) },
		{ Id = "floor", Title = "НАСТИЛ", Size = Vector3.new(12, 0.7, 12), Color = Color3.fromRGB(136, 98, 62) },
		{ Id = "ramp", Title = "ПАНДУС", Size = Vector3.new(10, 0.7, 14), Color = Color3.fromRGB(120, 88, 56) },
	},
	Range = 34,
	Cooldown = 0.12,
	GridStep = 2,
	Material = Enum.Material.WoodPlanks,
	Health = 140,
}

-- --------------------------------------------------------------------------- //
-- ИИ-боты (наполняют режимы, когда игроков мало)
-- --------------------------------------------------------------------------- //
DroneConfig.Bots = {
	Walker = { Health = 80, Speed = 15, FireInterval = 1.6, Damage = 9, Range = 190, Score = 60 },
	Flyer = { Health = 90, Speed = 42, FireInterval = 1.9, Damage = 10, Range = 420, Score = 90 },
	MaxAlive = 6,
}

-- --------------------------------------------------------------------------- //
-- Прочее
-- --------------------------------------------------------------------------- //
DroneConfig.KillY = -70                  -- ниже -- «упал в бездну»
DroneConfig.ArenaRadius = 1600
DroneConfig.DroneRespawn = 5.0
DroneConfig.BeaconRadius = 16            -- радиус сбора маяка в соло-прятках
DroneConfig.BeaconCount = 6

-- --------------------------------------------------------------------------- //
-- Утилиты
-- --------------------------------------------------------------------------- //
function DroneConfig.getDrone(id)
	for _, d in ipairs(DroneConfig.Drones) do
		if d.Id == id then
			return d
		end
	end
	return DroneConfig.Drones[1]
end

function DroneConfig.getPlank(id)
	for _, p in ipairs(DroneConfig.Building.PlankSizes) do
		if p.Id == id then
			return p
		end
	end
	return DroneConfig.Building.PlankSizes[1]
end

return DroneConfig
