--[[
	Тесты временных баффов (BuffSystem, BuffConfig) в модели зарядов: Grant начисляет пак зарядов
	(потолок MaxCharges режет избыток, время баффа не трогает), Activate тратит заряд и запускает
	таймер (повторно во время действия и без зарядов — no-op), истечение по os.time(), битые
	данные профиля (без записи), Remotes.ActivateBuff (валидация buffId, rate limit, вышедший
	игрок), эффект Speed Boost (WalkSpeed, респавн), атрибуты для HUD, миграции v9/v10 → v11.

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

-- BuffSystem + MovementGuard в одном «сервере»; DataSystem — профили в памяти, Remotes —
-- перехват обработчика ActivateBuff (t.Fire(player, buffId) — запрос клиента).
local function setup()
	local world = Harness.NewWorld()
	local _, dataSystem = world:NewServer()
	local profiles = {}
	local handlers = {}
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
		["src/shared/Remotes"] = {
			ActivateBuff = {
				OnServerEvent = {
					Connect = function(_self, fn)
						handlers.ActivateBuff = fn
					end,
				},
			},
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

	function t.Fire(player, buffId: any)
		handlers.ActivateBuff(player, buffId)
	end

	return t
end

------------------------------------------------------------------------------------------
-- Конфиг и профиль
------------------------------------------------------------------------------------------

test("BuffConfig: активация 60 с, пак 5 зарядов, потолок 20; Speed Boost быстрее базовой скорости", function()
	local t = setup()
	for _, id in t.Config.BuffIds do
		local buff = t.Config.Buffs[id]
		assert(buff.Duration == 60 and buff.PackSize == 5 and buff.MaxCharges == 20, id)
	end
	assert(t.Config.Buffs.SpeedBoost.WalkSpeed > t.Config.BaseWalkSpeed)
end)

test("BuffConfig: WalkSpeed ниже базовой или пак больше потолка — конфиг не грузится", function()
	local function loadPatched(from: string, to: string)
		local world = Harness.NewWorld()
		world.SourcePatches["src/shared/Config/BuffConfig"] = function(source: string): string
			local start, finish = string.find(source, from, 1, true)
			assert(start, "патч не применился — тест устарел")
			return string.sub(source, 1, start - 1) .. to .. string.sub(source, finish + 1)
		end
		return pcall(world.LoadModule, world, "src/shared/Config/BuffConfig")
	end
	local ok, err = loadPatched("WalkSpeed = 32 }", "WalkSpeed = 10 }")
	assert(not ok and string.find(tostring(err), "WalkSpeed", 1, true), tostring(err))
	ok, err = loadPatched("MagnetBoost = { Duration = 60, PackSize = 5,", "MagnetBoost = { Duration = 60, PackSize = 25,")
	assert(not ok and string.find(tostring(err), "PackSize", 1, true), tostring(err))
	ok, err = loadPatched("PackSize = 5, MaxCharges = 20, WalkSpeed", "PackSize = 2.5, MaxCharges = 20, WalkSpeed")
	assert(not ok and string.find(tostring(err), "PackSize", 1, true), tostring(err))
end)

test("Speed Boost быстрее потолка MovementGuardConfig.MaxSpeedMultiplier — BuffSystem не грузится", function()
	local world = Harness.NewWorld()
	world.SourcePatches["src/shared/Config/BuffConfig"] = function(source: string): string
		return (string.gsub(source, "WalkSpeed = 32 }", "WalkSpeed = 100 }"))
	end
	local ok, err = pcall(world.LoadModule, world, "src/server/Systems/BuffSystem")
	assert(not ok and string.find(tostring(err), "MaxSpeedMultiplier", 1, true), tostring(err))
end)

test("Новый профиль — 0 зарядов, баффы не активированы; миграции v9/v10 → v11 дозаполняют заряды нулём", function()
	local t = setup()
	local fresh = t.DataSystem.BuildDefaultProfile()
	assert(fresh.Buffs.MagnetBoostCharges == 0 and fresh.Buffs.SpeedBoostCharges == 0)
	assert(fresh.Buffs.MagnetBoostExpiresAt == nil and fresh.Buffs.SpeedBoostExpiresAt == nil)
	assert(t.DataSystem.CURRENT_SCHEMA_VERSION == 11)

	local v9 = {
		Meta = { SchemaVersion = 9 },
		Currency = { Essence = 555 },
		Collection = { RadiusLevel = 4, SpeedLevel = 2 },
		PvP = { ShieldExpiresAt = 123, StolenInWindow = 0, GuardsPlaced = {} },
	}
	local migrated = assert(t.DataSystem.MigrateProfileData(v9))
	assert(migrated.Meta.SchemaVersion == 11)
	assert(migrated.Buffs.MagnetBoostCharges == 0 and migrated.Buffs.SpeedBoostCharges == 0)
	assert(migrated.Currency.Essence == 555 and migrated.PvP.ShieldExpiresAt == 123)
	assert(migrated.Collection.RadiusLevel == 4, "уровень снятого апгрейда не тронут")

	-- v10: бафф, купленный по старой модели (сразу шёл время), дорабатывает свой срок.
	local v10 = { Meta = { SchemaVersion = 10 }, Buffs = { SpeedBoostExpiresAt = 1_000_050 } }
	local fromV10 = assert(t.DataSystem.MigrateProfileData(v10))
	assert(fromV10.Buffs.SpeedBoostExpiresAt == 1_000_050, "срок старой покупки не тронут")
	assert(fromV10.Buffs.SpeedBoostCharges == 0 and fromV10.Buffs.MagnetBoostCharges == 0)
end)

------------------------------------------------------------------------------------------
-- Grant: начисление пака зарядов
------------------------------------------------------------------------------------------

test("Grant: +PackSize зарядов, время баффа не трогает — бафф не активен до Activate", function()
	local t = setup()
	local player, data = t.AddPlayer(1)
	assert(t.Buffs.Grant(player, data, "MagnetBoost"))
	assert(data.Buffs.MagnetBoostCharges == 5)
	assert(data.Buffs.MagnetBoostExpiresAt == nil, "время не пошло")
	assert(not t.Buffs.IsActive(data, "MagnetBoost"))
	assert(data.Buffs.SpeedBoostCharges == 0, "другой бафф не тронут")

	assert(t.Buffs.Grant(player, data, "MagnetBoost"))
	assert(data.Buffs.MagnetBoostCharges == 10, "паки складываются")
end)

test("Grant: потолок MaxCharges режет избыток, покупка всё равно выдана", function()
	local t = setup()
	local player, data = t.AddPlayer(1)
	data.Buffs.SpeedBoostCharges = 18
	assert(t.Buffs.Grant(player, data, "SpeedBoost"), "покупка выдана")
	assert(data.Buffs.SpeedBoostCharges == 20, "18 + 5 зажато в 20")
	assert(t.Buffs.Grant(player, data, "SpeedBoost"), "на потолке — тоже выдана (пак сгорел)")
	assert(data.Buffs.SpeedBoostCharges == 20)

	-- Потолок снизили в конфиге: уже оплаченное сверх него покупка не отнимает.
	data.Buffs.MagnetBoostCharges = 25
	assert(t.Buffs.Grant(player, data, "MagnetBoost"))
	assert(data.Buffs.MagnetBoostCharges == 25, "не уменьшилось до потолка")
end)

test("Grant: битые заряды или раздел Buffs — отказ без записи; неизвестный бафф — отказ", function()
	local t = setup()
	local player, data = t.AddPlayer(1)
	for _, junk in { 0 / 0, -1, 2.5, "5", math.huge } do
		data.Buffs.MagnetBoostCharges = junk
		assert(not t.Buffs.Grant(player, data, "MagnetBoost"), tostring(junk))
		assert(data.Buffs.MagnetBoostCharges == junk or junk ~= junk, "значение не тронуто")
	end
	local player2, data2 = t.AddPlayer(2)
	;(data2 :: any).Buffs = 5
	assert(not t.Buffs.Grant(player2, data2, "SpeedBoost"))
	assert(not t.Buffs.Grant(player2, t.DataSystem.BuildDefaultProfile(), "NoSuchBuff" :: any))
end)

------------------------------------------------------------------------------------------
-- Activate: трата заряда
------------------------------------------------------------------------------------------

test("Activate: −1 заряд, ExpiresAt = now + 60; действует до истечения, потом нет", function()
	local t = setup()
	local player, data = t.AddPlayer(1)
	assert(t.Buffs.Grant(player, data, "MagnetBoost"))
	t.World:Advance(3)
	local start = osTime(t.World)
	assert(t.Buffs.Activate(player, "MagnetBoost") == nil, "запущен")
	assert(data.Buffs.MagnetBoostCharges == 4)
	assert(data.Buffs.MagnetBoostExpiresAt == start + 60)
	assert(t.Buffs.IsActive(data, "MagnetBoost"))
	assert(t.Buffs.GetExpiresAt(data, "MagnetBoost") == start + 60)

	t.World:Advance(59.5)
	assert(t.Buffs.IsActive(data, "MagnetBoost"), "на 59.5 с ещё действует")
	t.World:Advance(1)
	assert(not t.Buffs.IsActive(data, "MagnetBoost"), "истёк")
	assert(data.Buffs.MagnetBoostCharges == 4, "заряд списан один раз")
end)

test("Activate во время действия — no-op: заряд не тратится, срок не продлевается", function()
	local t = setup()
	local player, data = t.AddPlayer(1)
	assert(t.Buffs.Grant(player, data, "SpeedBoost"))
	local start = osTime(t.World)
	assert(t.Buffs.Activate(player, "SpeedBoost") == nil)
	t.World:Advance(10)
	for _ = 1, 3 do
		assert(t.Buffs.Activate(player, "SpeedBoost") == "already-active")
	end
	assert(data.Buffs.SpeedBoostCharges == 4, "заряды не тронуты")
	assert(data.Buffs.SpeedBoostExpiresAt == start + 60, "срок не тронут")
end)

test("Activate без зарядов — no-op; после истечения следующий заряд запускает снова", function()
	local t = setup()
	local player, data = t.AddPlayer(1)
	assert(t.Buffs.Activate(player, "MagnetBoost") == "no-charges")
	assert(data.Buffs.MagnetBoostExpiresAt == nil and data.Buffs.MagnetBoostCharges == 0)

	data.Buffs.MagnetBoostCharges = 1
	assert(t.Buffs.Activate(player, "MagnetBoost") == nil)
	assert(data.Buffs.MagnetBoostCharges == 0)
	t.World:Advance(61)
	assert(t.Buffs.Activate(player, "MagnetBoost") == "no-charges", "последний заряд потрачен")

	assert(t.Buffs.Grant(player, data, "MagnetBoost"))
	local now = osTime(t.World)
	assert(t.Buffs.Activate(player, "MagnetBoost") == nil, "после истечения и покупки — снова")
	assert(data.Buffs.MagnetBoostExpiresAt == now + 60 and data.Buffs.MagnetBoostCharges == 4)
end)

test("Activate: битые данные — отказ без записи; без профиля и неизвестный бафф — отказ", function()
	local t = setup()
	local player, data = t.AddPlayer(1)
	data.Buffs.SpeedBoostCharges = 0 / 0
	assert(t.Buffs.Activate(player, "SpeedBoost") == "corrupt-buffs")
	data.Buffs.SpeedBoostCharges = 3
	data.Buffs.SpeedBoostExpiresAt = "скоро"
	assert(t.Buffs.Activate(player, "SpeedBoost") == "corrupt-buffs", "битый срок — не перезаписываем")
	assert(data.Buffs.SpeedBoostCharges == 3 and data.Buffs.SpeedBoostExpiresAt == "скоро")

	assert(t.Buffs.Activate(t.World:NewPlayer(99), "SpeedBoost") == "no-profile")
	assert(t.Buffs.Activate(player, "FlyBoost" :: any) == "unknown-buff")
end)

test("Баффы независимы: заряды и сроки Magnet и Speed раздельны", function()
	local t = setup()
	local player, data = t.AddPlayer(1)
	assert(t.Buffs.Grant(player, data, "MagnetBoost"))
	assert(t.Buffs.Grant(player, data, "SpeedBoost"))
	assert(t.Buffs.Activate(player, "MagnetBoost") == nil)
	t.World:Advance(5)
	assert(t.Buffs.Activate(player, "SpeedBoost") == nil, "второй бафф запускается, пока первый действует")
	assert(data.Buffs.MagnetBoostCharges == 4 and data.Buffs.SpeedBoostCharges == 4)
	assert(data.Buffs.SpeedBoostExpiresAt - data.Buffs.MagnetBoostExpiresAt == 5)
end)

------------------------------------------------------------------------------------------
-- Remotes.ActivateBuff
------------------------------------------------------------------------------------------

test("ActivateBuff: валидный buffId запускает бафф; мусор вместо buffId игнорируется", function()
	local t = setup()
	local player, data = t.AddPlayer(1)
	data.Buffs.MagnetBoostCharges = 3
	for _, junk in { nil, 5, "FlyBoost", { "MagnetBoost" }, "BuffIds" } do
		t.Fire(player, junk)
		t.World:Advance(1) -- вне окна rate limit
	end
	assert(data.Buffs.MagnetBoostCharges == 3 and data.Buffs.MagnetBoostExpiresAt == nil, "мусор — без эффекта")

	t.Fire(player, "MagnetBoost")
	assert(data.Buffs.MagnetBoostCharges == 2 and t.Buffs.IsActive(data, "MagnetBoost"))
	t.Fire(player, "MagnetBoost")
	assert(data.Buffs.MagnetBoostCharges == 2, "повторный клик во время действия — без траты")
end)

test("ActivateBuff: rate limit — сверх лимита за окно запросы отбрасываются", function()
	local t = setup()
	local player, data = t.AddPlayer(1)
	data.Buffs.SpeedBoostCharges = 3
	for _ = 1, t.Config.MaxActivateRequestsPerWindow do
		t.Fire(player, "NoSuchBuff") -- исчерпать окно
	end
	t.Fire(player, "SpeedBoost")
	assert(data.Buffs.SpeedBoostCharges == 3, "сверх лимита — отброшен")

	t.World:Advance(t.Config.ActivateRequestWindow + 0.01)
	t.Fire(player, "SpeedBoost")
	assert(data.Buffs.SpeedBoostCharges == 2, "новое окно — прошёл")
end)

test("ActivateBuff от вышедшего игрока игнорируется", function()
	local t = setup()
	local player, data = t.AddPlayer(1)
	data.Buffs.SpeedBoostCharges = 3
	player.Parent = nil
	t.Fire(player, "SpeedBoost")
	assert(data.Buffs.SpeedBoostCharges == 3 and data.Buffs.SpeedBoostExpiresAt == nil)
end)

------------------------------------------------------------------------------------------
-- Эффект Speed Boost и атрибуты для HUD
------------------------------------------------------------------------------------------

test("Speed Boost: WalkSpeed поднимается сразу при Activate (не при покупке) и возвращается по истечении", function()
	local t = setup()
	local player, data, humanoid = t.AddPlayer(1)
	t.World:Advance(0.5)
	assert(humanoid.WalkSpeed == t.Config.BaseWalkSpeed, "без баффа — базовая")

	assert(t.Buffs.Grant(player, data, "SpeedBoost"))
	assert(humanoid.WalkSpeed == t.Config.BaseWalkSpeed, "покупка заряда скорость не даёт")
	assert(t.Buffs.Activate(player, "SpeedBoost") == nil)
	assert(humanoid.WalkSpeed == t.Config.Buffs.SpeedBoost.WalkSpeed, "сразу, без ожидания тика")

	t.World:Advance(59)
	assert(humanoid.WalkSpeed == t.Config.Buffs.SpeedBoost.WalkSpeed, "держится весь срок")
	t.World:Advance(1.5)
	assert(humanoid.WalkSpeed == t.Config.BaseWalkSpeed, `после истечения — базовая, {humanoid.WalkSpeed}`)
end)

test("Speed Boost: респавн под баффом — новый Humanoid получает ускорение на ближайшем тике", function()
	local t = setup()
	local player, data = t.AddPlayer(1)
	data.Buffs.SpeedBoostCharges = 1
	assert(t.Buffs.Activate(player, "SpeedBoost") == nil)
	local character, _, humanoid = t.World:NewCharacter(t.Origin)
	t.World:SpawnCharacter(player, character)
	t.World:Advance(t.Config.TickInterval + 0.01)
	assert(humanoid.WalkSpeed == t.Config.Buffs.SpeedBoost.WalkSpeed, tostring(humanoid.WalkSpeed))
end)

test("Magnet Boost не трогает WalkSpeed; тик не перетирает WalkSpeed без изменения баффа", function()
	local t = setup()
	local player, data, humanoid = t.AddPlayer(1)
	data.Buffs.MagnetBoostCharges = 1
	assert(t.Buffs.Activate(player, "MagnetBoost") == nil)
	assert(humanoid.WalkSpeed == t.Config.BaseWalkSpeed)
	humanoid.WalkSpeed = 10 -- например, будущий эффект замедления другой системы
	t.World:Advance(2)
	assert(humanoid.WalkSpeed == 10, "без смены баффа WalkSpeed не переписывается")
end)

test("Атрибуты для HUD: заряды — при Grant и Activate, срок — при Activate, снимается по истечении", function()
	local t = setup()
	local player, data = t.AddPlayer(1)
	t.World:Advance(0.5)
	assert(player:GetAttribute("MagnetBoostCharges") == 0, "заряды видны и при нуле")
	assert(player:GetAttribute("MagnetBoostExpiresAt") == nil)

	assert(t.Buffs.Grant(player, data, "MagnetBoost"))
	assert(player:GetAttribute("MagnetBoostCharges") == 5, "сразу после покупки")
	assert(player:GetAttribute("MagnetBoostExpiresAt") == nil, "покупка срок не ставит")

	local start = osTime(t.World)
	assert(t.Buffs.Activate(player, "MagnetBoost") == nil)
	assert(player:GetAttribute("MagnetBoostCharges") == 4)
	assert(player:GetAttribute("MagnetBoostExpiresAt") == start + 60, "сразу после активации")

	t.World:Advance(61)
	assert(player:GetAttribute("MagnetBoostExpiresAt") == nil, "истёк — атрибут снят тиком")
	assert(player:GetAttribute("MagnetBoostCharges") == 4)

	data.Buffs.SpeedBoostCharges = 0 / 0
	t.World:Advance(0.5)
	assert(player:GetAttribute("SpeedBoostCharges") == nil, "битые заряды — атрибут снят")
end)

test("Атрибуты подхватываются с профиля при входе (заряды и бафф из прошлой сессии)", function()
	local t = setup()
	local player, data = t.AddPlayer(1)
	data.Buffs.SpeedBoostCharges = 7
	data.Buffs.SpeedBoostExpiresAt = osTime(t.World) + 15
	t.World:Advance(t.Config.TickInterval + 0.01)
	assert(player:GetAttribute("SpeedBoostCharges") == 7)
	assert(player:GetAttribute("SpeedBoostExpiresAt") == data.Buffs.SpeedBoostExpiresAt)
end)

return tests
