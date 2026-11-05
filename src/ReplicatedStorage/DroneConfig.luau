--!strict
--[[
	DroneConfig -- общие настройки игры «Беспилотник: Лавовый каньон».

	Файл лежит в ReplicatedStorage и читается и сервером, и клиентом,
	поэтому все числа физики/оружия задаются в одном месте.
]]

local DroneConfig = {}

-- ---------------------------------------------------------------------------
-- Основное
-- ---------------------------------------------------------------------------
DroneConfig.GameName = "БЕСПИЛОТНИК"
DroneConfig.GameSubtitle = "ЛАВОВЫЙ КАНЬОН"
DroneConfig.RespawnTime = 4.0
DroneConfig.LavaKillY = -34.0        -- ниже этой высоты дрон плавится
DroneConfig.ArenaRadius = 1150.0     -- дальше -- «выход из зоны»
DroneConfig.MaxHealthDefault = 100

-- ---------------------------------------------------------------------------
-- Модели дронов (лежат в ServerStorage)
-- ---------------------------------------------------------------------------
DroneConfig.Drones = {
	{
		Id = "scout",
		Title = "РАЗВЕДЧИК",
		Template = "Беспилотник",
		Health = 95,
		Thrust = 1.16,          -- множитель тяги (быстрее, резче)
		Agility = 1.18,         -- множитель скорости поворота
		Armor = 0.9,            -- входящий урон умножается на это
		Bomb = false,
		Tint = Color3.fromRGB(120, 225, 255),
		Description = "Лёгкий перехватчик. Два минигана, высокая скорость.",
	},
	{
		Id = "gunship",
		Title = "ШТУРМОВИК",
		Template = "скинБеспилотник",
		Health = 140,
		Thrust = 0.94,
		Agility = 0.9,
		Armor = 1.22,
		Bomb = true,
		Tint = Color3.fromRGB(255, 150, 60),
		Description = "Тяжёлая броня и бомба в брюхе. Медленнее, но живёт дольше.",
	},
}

DroneConfig.DefaultDrone = "scout"

-- ---------------------------------------------------------------------------
-- Физика полёта
-- ---------------------------------------------------------------------------
DroneConfig.Physics = {
	MaxTilt = 38,           -- максимальный крен/тангаж, градусы
	TiltResponsiveness = 7.5,   -- как быстро дрон выходит на заданный крен
	YawRate = 150,          -- градусов в секунду при Q/E
	YawFollowLerp = 2.6,    -- автодоворот корпуса к камере
	CollectiveIdle = 1.0,   -- столько тяги нужно для висения
	CollectiveUp = 1.62,
	CollectiveDown = 0.22,
	CollectiveLerp = 3.4,
	LinearDrag = 0.155,     -- линейное сопротивление воздуха (на кг)
	QuadDrag = 0.0026,      -- квадратичное сопротивление (на кг)
	AngularDamping = 1.0,
	GroundEffectHeight = 14,
	GroundEffectBoost = 0.14,
	WindStrength = 6.0,     -- порывы ветра (студии/с)
	MaxSpeed = 260,
	CrashSpeed = 105,       -- с какой скорости столкновение начинает ломать корпус
	CrashDamageScale = 0.55,
}

-- ---------------------------------------------------------------------------
-- Оружие
-- ---------------------------------------------------------------------------
DroneConfig.Weapons = {
	Minigun = {
		Damage = 7,
		Interval = 0.055,
		Range = 1400,
		Spread = 0.9,       -- градусы конуса разброса
		HeatPerShot = 0.021,
		CoolRate = 0.16,
		OverheatCooldown = 0.35,
		Tracer = Color3.fromRGB(255, 220, 120),
	},
	Bomb = {
		Damage = 85,
		Radius = 34,
		Cooldown = 6.0,
		DropSpeed = 40,
	},
}

-- ---------------------------------------------------------------------------
-- Противники
-- ---------------------------------------------------------------------------
DroneConfig.Enemies = {
	BaseHealth = 70,
	HealthPerWave = 22,
	Speed = 46,
	FireInterval = 1.9,
	ProjectileSpeed = 190,
	ProjectileDamage = 11,
	KillScore = 100,
	MaxAlive = 7,
}

DroneConfig.Turrets = {
	Health = 90,
	FireInterval = 2.6,
	ProjectileSpeed = 150,
	ProjectileDamage = 14,
	Range = 520,
	KillScore = 150,
	Respawn = 26.0,
}

DroneConfig.Pickups = {
	Heal = 30,
	Score = 50,
	Respawn = 22.0,
	MaxHeatRelief = 100,
}

DroneConfig.Waves = {
	FirstDelay = 8.0,
	Intermission = 12.0,
	BaseCount = 2,
	CountPerWave = 1,
}

-- ---------------------------------------------------------------------------
-- Утилиты
-- ---------------------------------------------------------------------------
function DroneConfig.getDrone(id: string?)
	for _, d in ipairs(DroneConfig.Drones) do
		if d.Id == id then
			return d
		end
	end
	return DroneConfig.Drones[1]
end

return DroneConfig
