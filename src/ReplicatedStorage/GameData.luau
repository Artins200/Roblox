--!nonstrict
--[[
	GameData -- режимы и карты. Один источник правды для сервера и меню:
	сервер берёт id, клиент рисует карточки с названием, описанием и цветом.
]]

local GameData = {}

-- --------------------------------------------------------------------------- //
-- Режимы
-- --------------------------------------------------------------------------- //
GameData.Modes = {
	{
		Id = "hide",
		Title = "ПРЯТКИ",
		Short = "ПРЯТКИ",
		Desc = "Один дрон против всех прячущихся. Нашёл всех -- победили дроны. Не успел -- победа у тех, кто спрятался.",
		Hint = "Прячущиеся: не светитесь. Дрон: обыщите каждый угол.",
		Color = Color3.fromRGB(150, 110, 255),
		Icon = "hide",
		MinPlayers = 2,
		Timer = 7 * 60,
		Teams = false,
	},
	{
		Id = "teams",
		Title = "КОМАНДА НА КОМАНДУ",
		Short = "БОЙ КОМАНД",
		Desc = "Дроны делятся на красных и синих. У каждого -- тимейты. Побеждает команда, набравшая больше фрагов.",
		Hint = "Держитесь вместе: одиночку собьют за секунды.",
		Color = Color3.fromRGB(255, 96, 92),
		Icon = "teams",
		MinPlayers = 2,
		Timer = 15 * 60,
		Teams = true,
	},
	{
		Id = "free",
		Title = "СВОБОДНЫЙ ПОЛЁТ",
		Short = "ФРИПЛЕЙ",
		Desc = "Все на дронах, никаких правил: летайте, стреляйте, тренируйте физику сколько влезет.",
		Hint = "Идеально, чтобы освоить полёт и перегрев миниганов.",
		Color = Color3.fromRGB(120, 225, 255),
		Icon = "free",
		MinPlayers = 1,
		Timer = 15 * 60,
		Teams = false,
	},
	{
		Id = "survivors",
		Title = "ВЫЖИВШИЕ",
		Short = "ВЫЖИВШИЕ",
		Desc = "Отряд с винтовками, ножами и досками против дронов. Продержитесь до конца -- победа ваша.",
		Hint = "Стройте укрытия из досок: дронам сложно бить по закрытым целям.",
		Color = Color3.fromRGB(255, 186, 76),
		Icon = "survivors",
		MinPlayers = 1,
		Timer = 6 * 60,
		Teams = false,
	},
}

-- --------------------------------------------------------------------------- //
-- Карты
-- --------------------------------------------------------------------------- //
GameData.Maps = {
	{ Id = "lava", Title = "ЛАВОВЫЙ КАНЬОН", Subtitle = "лава, пепел и замок", Color = Color3.fromRGB(255, 120, 56) },
	{ Id = "desert", Title = "ПЕСЧАНЫЕ РУИНЫ", Subtitle = "мёртвый город в пустыне", Color = Color3.fromRGB(240, 196, 120) },
	{ Id = "ice", Title = "ЛЕДЯНЫЕ ШПИЛИ", Subtitle = "снег, кристаллы, метель", Color = Color3.fromRGB(150, 220, 255) },
	{ Id = "space", Title = "ОРБИТАЛЬНАЯ СТАНЦИЯ", Subtitle = "неон и пустота", Color = Color3.fromRGB(180, 140, 255) },
}

-- --------------------------------------------------------------------------- //
-- Утилиты
-- --------------------------------------------------------------------------- //
function GameData.getMode(id)
	for _, m in ipairs(GameData.Modes) do
		if m.Id == id then
			return m
		end
	end
	return GameData.Modes[1]
end

function GameData.getMap(id)
	for _, m in ipairs(GameData.Maps) do
		if m.Id == id then
			return m
		end
	end
	return GameData.Maps[1]
end

function GameData.randomMode()
	return GameData.Modes[math.random(1, #GameData.Modes)]
end

local lastMap = nil

function GameData.randomMap()
	local map = GameData.Maps[math.random(1, #GameData.Maps)]
	if #GameData.Maps > 1 and lastMap and map.Id == lastMap then
		-- не повторяем карту два раунда подряд
		for _, m in ipairs(GameData.Maps) do
			if m.Id ~= lastMap then
				map = m
				break
			end
		end
	end
	lastMap = map.Id
	return map
end

return GameData
