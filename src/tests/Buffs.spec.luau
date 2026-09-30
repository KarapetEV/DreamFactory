--[[
	Тесты временных баффов (BuffSystem, BuffConfig): выдача Grant (ExpiresAt = now + Duration),
	истечение по os.time(), стекинг продлением (max(ExpiresAt, now) + Duration), битые данные
	профиля (без записи, бафф не активен), эффект Speed Boost (Humanoid.WalkSpeed и множитель
	MovementGuard; снятие по истечении, респавн под баффом), миграция v9 → v10.

	Идемпотентность покупки — DevProducts.spec, магнит от баффа — AutoCollector.spec,
	MovementGuard под Speed Boost — MovementGuard.spec.
	Запуск: lune run src/tests/run (из корня репозитория).
]]

local Harness = require("./lib/Harness")

type Test = { Name: string, Run: () -> () }

local tests: { Test } = {}

local function test(name: string, run: () -> ())
	table.insert(tests, { Name = name, Run = run })
end

-- os.time() мира Harness при текущем виртуальном времени.
local function osTime(world): number
	return 1_000_000 + math.floor(world.Now)
end

-- BuffSystem + MovementGuard в одном «сервере»; DataSystem — профили в памяти.
local function setup()
	local world = Harness.NewWorld()
	local _, dataSystem = world:NewServer()
	local profiles = {}
	local load = world:ModuleLoader({
		["src/server/Systems/DataSystem"] = {
			GetData = function(p)
				return profiles[p]
			end,
			WaitForData = function(p)
				return profiles[p]
			end,
			BuildDefaultProfile = dataSystem.BuildDefaultProfile,
		},
	})
	local t = {
		World = world,
		DataSystem = dataSystem,
		Buffs = load("src/server/Systems/BuffSystem"),
		Config = load("src/shared/Config/BuffConfig"),
		Origin = load("src/shared/Config/ChaosBossConfig").BossPosition,
	}
	t.Buffs.Init()

	-- Игрок с дефолтным профилем и живым персонажем. Возвращает player, data, humanoid.
	function t.AddPlayer(userId: number)
		local player = world:NewPlayer(userId)
		local data = dataSystem.BuildDefaultProfile()
		profiles[player] = data
		table.insert(world.Players, player)
		local character, _, humanoid = world:NewCharacter(t.Origin)
		player.Character = character
		return player, data, humanoid
	end

	return t
end

------------------------------------------------------------------------------------------
-- Конфиг и профиль
------------------------------------------------------------------------------------------

test("BuffConfig: Magnet Boost и Speed Boost по 20 с, Speed Boost быстрее базовой скорости", function()
	local t = setup()
	assert(t.Config.Buffs.MagnetBoost.Duration == 20)
	assert(t.Config.Buffs.SpeedBoost.Duration == 20)
	assert(t.Config.Buffs.SpeedBoost.WalkSpeed > t.Config.BaseWalkSpeed)
end)

test("BuffConfig: WalkSpeed Speed Boost не выше базовой — конфиг не грузится", function()
	local world = Harness.NewWorld()
	world.SourcePatches["src/shared/Config/BuffConfig"] = function(source: string): string
		local patched, count = string.gsub(source, "WalkSpeed = 32 }", "WalkSpeed = 10 }")
		assert(count == 1, "патч не применился — тест устарел")
		return patched
	end
	local ok, err = pcall(world.LoadModule, world, "src/shared/Config/BuffConfig")
	assert(not ok and string.find(tostring(err), "WalkSpeed", 1, true), tostring(err))
end)

test("Speed Boost быстрее потолка MovementGuardConfig.MaxSpeedMultiplier — BuffSystem не грузится", function()
	local world = Harness.NewWorld()
	world.SourcePatches["src/shared/Config/BuffConfig"] = function(source: string): string
		return (string.gsub(source, "WalkSpeed = 32 }", "WalkSpeed = 100 }"))
	end
	local ok, err = pcall(world.LoadModule, world, "src/server/Systems/BuffSystem")
	assert(not ok and string.find(tostring(err), "MaxSpeedMultiplier", 1, true), tostring(err))
end)

test("Новый профиль — пустой раздел Buffs; миграция v9 → v10 добавляет его, остальное не тронуто", function()
	local t = setup()
	local fresh = t.DataSystem.BuildDefaultProfile()
	assert(type(fresh.Buffs) == "table" and next(fresh.Buffs) == nil, "в новом профиле баффов нет")

	local v9 = {
		Meta = { SchemaVersion = 9 },
		Currency = { Essence = 555 },
		Collection = { RadiusLevel = 4, SpeedLevel = 2 },
		PvP = { ShieldExpiresAt = 123, StolenInWindow = 0, GuardsPlaced = {} },
	}
	local migrated = assert(t.DataSystem.MigrateProfileData(v9))
	assert(migrated.Meta.SchemaVersion == t.DataSystem.CURRENT_SCHEMA_VERSION)
	assert(t.DataSystem.CURRENT_SCHEMA_VERSION == 10)
	assert(type(migrated.Buffs) == "table" and next(migrated.Buffs) == nil, "Buffs дозаполнен пустым")
	assert(migrated.Currency.Essence == 555 and migrated.PvP.ShieldExpiresAt == 123)
	assert(migrated.Collection.RadiusLevel == 4, "уровень снятого апгрейда не тронут")
end)

------------------------------------------------------------------------------------------
-- Выдача, истечение, стекинг
------------------------------------------------------------------------------------------

test("Grant: ExpiresAt = os.time() + Duration; активен до ExpiresAt, после — нет", function()
	local t = setup()
	local player, data = t.AddPlayer(1)
	local start = osTime(t.World)
	assert(not t.Buffs.IsActive(data, "MagnetBoost"), "до покупки не активен")

	assert(t.Buffs.Grant(player, data, "MagnetBoost"))
	assert(data.Buffs.MagnetBoostExpiresAt == start + 20, tostring(data.Buffs.MagnetBoostExpiresAt))
	assert(t.Buffs.IsActive(data, "MagnetBoost"))
	assert(t.Buffs.GetExpiresAt(data, "MagnetBoost") == start + 20)
	assert(not t.Buffs.IsActive(data, "SpeedBoost"), "другой бафф не выдан")

	t.World:Advance(19.5)
	assert(t.Buffs.IsActive(data, "MagnetBoost"), "на 19.5 с ещё действует")
	t.World:Advance(0.5)
	assert(not t.Buffs.IsActive(data, "MagnetBoost"), "на 20-й секунде истёк")
	assert(t.Buffs.GetExpiresAt(data, "MagnetBoost") == nil)
	assert(data.Buffs.MagnetBoostExpiresAt == start + 20, "истёкшее значение остаётся в профиле")
end)

test("Стекинг: покупка при активном баффе продлевает от текущего конца, после истечения — от now", function()
	local t = setup()
	local player, data = t.AddPlayer(1)
	local start = osTime(t.World)
	assert(t.Buffs.Grant(player, data, "SpeedBoost"))
	t.World:Advance(5)
	assert(t.Buffs.Grant(player, data, "SpeedBoost"))
	assert(data.Buffs.SpeedBoostExpiresAt == start + 40, "20 + 20, а не 5 + 20")
	assert(t.Buffs.Grant(player, data, "SpeedBoost"))
	assert(data.Buffs.SpeedBoostExpiresAt == start + 60, "третья покупка — ещё +20")

	t.World:Advance(100) -- всё истекло
	assert(not t.Buffs.IsActive(data, "SpeedBoost"))
	local now = osTime(t.World)
	assert(t.Buffs.Grant(player, data, "SpeedBoost"))
	assert(data.Buffs.SpeedBoostExpiresAt == now + 20, "истёкший бафф начинается заново")
end)

test("Баффы независимы: Magnet и Speed хранят свои сроки", function()
	local t = setup()
	local player, data = t.AddPlayer(1)
	local start = osTime(t.World)
	assert(t.Buffs.Grant(player, data, "MagnetBoost"))
	t.World:Advance(3)
	assert(t.Buffs.Grant(player, data, "SpeedBoost"))
	assert(data.Buffs.MagnetBoostExpiresAt == start + 20)
	assert(data.Buffs.SpeedBoostExpiresAt == start + 23)
end)

test("Битые данные: Grant отказывает без записи, IsActive = false, тик не падает", function()
	local t = setup()
	local player, data = t.AddPlayer(1)

	data.Buffs.MagnetBoostExpiresAt = 0 / 0
	assert(not t.Buffs.IsActive(data, "MagnetBoost"), "NaN — не активен")
	assert(not t.Buffs.Grant(player, data, "MagnetBoost"), "NaN — отказ")
	assert(data.Buffs.MagnetBoostExpiresAt ~= data.Buffs.MagnetBoostExpiresAt, "значение не тронуто")

	data.Buffs.SpeedBoostExpiresAt = "9999999999"
	assert(not t.Buffs.IsActive(data, "SpeedBoost"), "строка — не активен")
	assert(not t.Buffs.Grant(player, data, "SpeedBoost"))

	local player2, data2 = t.AddPlayer(2)
	;(data2 :: any).Buffs = 5
	assert(not t.Buffs.IsActive(data2, "SpeedBoost"))
	assert(not t.Buffs.Grant(player2, data2, "SpeedBoost"))
	assert(not t.Buffs.Grant(player2, t.DataSystem.BuildDefaultProfile(), "NoSuchBuff" :: any), "неизвестный бафф")

	t.World:Advance(2) -- тики по битым профилям
	local errors = 0
	for _, text in t.World.Warnings do
		if string.find(text, "[BuffSystem]", 1, true) then
			errors += 1
		end
	end
	assert(errors == 0, `битый раздел — просто «нет баффа», без ошибок тика ({errors})`)
end)

------------------------------------------------------------------------------------------
-- Эффект Speed Boost: WalkSpeed
------------------------------------------------------------------------------------------

test("Speed Boost: WalkSpeed поднимается сразу при Grant и возвращается к базовой по истечении", function()
	local t = setup()
	local player, data, humanoid = t.AddPlayer(1)
	t.World:Advance(0.5)
	assert(humanoid.WalkSpeed == t.Config.BaseWalkSpeed, "без баффа — базовая")

	assert(t.Buffs.Grant(player, data, "SpeedBoost"))
	assert(humanoid.WalkSpeed == t.Config.Buffs.SpeedBoost.WalkSpeed, "сразу, без ожидания тика")

	t.World:Advance(19)
	assert(humanoid.WalkSpeed == t.Config.Buffs.SpeedBoost.WalkSpeed, "держится весь срок")
	t.World:Advance(1.5)
	assert(humanoid.WalkSpeed == t.Config.BaseWalkSpeed, `после истечения — базовая, {humanoid.WalkSpeed}`)
end)

test("Speed Boost: респавн под баффом — новый Humanoid получает ускорение на ближайшем тике", function()
	local t = setup()
	local player, data = t.AddPlayer(1)
	assert(t.Buffs.Grant(player, data, "SpeedBoost"))
	local character, _, humanoid = t.World:NewCharacter(t.Origin)
	t.World:SpawnCharacter(player, character)
	t.World:Advance(t.Config.TickInterval + 0.01)
	assert(humanoid.WalkSpeed == t.Config.Buffs.SpeedBoost.WalkSpeed, tostring(humanoid.WalkSpeed))
end)

test("Атрибуты срока для магазина: ставятся при Grant, продлеваются, снимаются по истечении", function()
	local t = setup()
	local player, data = t.AddPlayer(1)
	local start = osTime(t.World)
	t.World:Advance(0.5)
	assert(player:GetAttribute("MagnetBoostExpiresAt") == nil, "без баффа атрибута нет")

	assert(t.Buffs.Grant(player, data, "MagnetBoost"))
	assert(player:GetAttribute("MagnetBoostExpiresAt") == start + 20, "сразу при Grant")
	assert(player:GetAttribute("SpeedBoostExpiresAt") == nil, "другой бафф не выдан")
	assert(t.Buffs.Grant(player, data, "MagnetBoost"))
	assert(player:GetAttribute("MagnetBoostExpiresAt") == start + 40, "продление видно сразу")

	t.World:Advance(41)
	assert(player:GetAttribute("MagnetBoostExpiresAt") == nil, "истёк — атрибут снят тиком")
end)

test("Атрибут срока подхватывается с профиля при входе (бафф куплен в прошлой сессии)", function()
	local t = setup()
	local player, data = t.AddPlayer(1)
	data.Buffs.SpeedBoostExpiresAt = osTime(t.World) + 15
	t.World:Advance(t.Config.TickInterval + 0.01)
	assert(player:GetAttribute("SpeedBoostExpiresAt") == data.Buffs.SpeedBoostExpiresAt)
end)

test("Magnet Boost не трогает WalkSpeed; тик не перетирает WalkSpeed без изменения баффа", function()
	local t = setup()
	local player, data, humanoid = t.AddPlayer(1)
	assert(t.Buffs.Grant(player, data, "MagnetBoost"))
	assert(humanoid.WalkSpeed == t.Config.BaseWalkSpeed)
	humanoid.WalkSpeed = 10 -- например, будущий эффект замедления другой системы
	t.World:Advance(2)
	assert(humanoid.WalkSpeed == 10, "без смены баффа WalkSpeed не переписывается")
end)

return tests
