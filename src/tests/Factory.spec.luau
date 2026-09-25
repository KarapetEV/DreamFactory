--[[
	Тесты FactorySystem (раздел 5.2 ТЗ), ступенчатых апгрейдов UpgradeEffects и миграции
	схемы v2 → v3. Находки M-1/M-4 security-ревью персистентности.

	Запуск: lune run src/tests/run (из корня репозитория).
]]

local Harness = require("./lib/Harness")

type Test = { Name: string, Run: () -> () }

local tests: { Test } = {}

local function test(name: string, run: () -> ())
	table.insert(tests, { Name = name, Run = run })
end

-- FactorySystem с подменёнными DataSystem (профиль в памяти) и Remotes (перехват обработчика).
local function setup()
	local world = Harness.NewWorld()
	local _, dataSystem = world:NewServer()
	local player = world:NewPlayer()
	local data = dataSystem.BuildDefaultProfile()
	local profiles = { [player] = data }
	local handler

	local factory = world:LoadModule("src/server/Systems/FactorySystem", {
		["src/server/Systems/DataSystem"] = {
			GetData = function(p)
				return profiles[p]
			end,
			BuildDefaultProfile = dataSystem.BuildDefaultProfile,
		},
		["src/shared/Remotes"] = {
			PurchaseUpgrade = {
				OnServerEvent = {
					Connect = function(_self, fn)
						handler = fn
					end,
				},
			},
		},
	})
	factory.Init()
	world.Players = { player }

	local produced = {}
	factory.OnEssenceProduced:Connect(function(p, amount)
		table.insert(produced, { Player = p, Amount = amount })
	end)

	return {
		World = world,
		Player = player,
		Data = data,
		Factory = factory,
		Produced = produced,
		Upgrades = world:LoadModule("src/shared/Config/UpgradeConfig"),
		Effects = world:LoadModule("src/shared/UpgradeEffects"),
		DataSystem = dataSystem,
		Purchase = function(...)
			handler(player, ...)
		end,
		-- Ещё один игрок конвейера со своим (дефолтным) профилем. first = true — поставить
		-- его в начало Players:GetPlayers(), чтобы он обрабатывался раньше основного.
		AddPlayer = function(userId: number, first: boolean?)
			local other = world:NewPlayer(userId)
			local otherData = dataSystem.BuildDefaultProfile()
			profiles[other] = otherData
			table.insert(world.Players, if first then 1 else #world.Players + 1, other)
			return other, otherData
		end,
	}
end

------------------------------------------------------------------------------------------
-- PurchaseUpgrade
------------------------------------------------------------------------------------------

test("Покупка следующего уровня списывает цену из конфига и повышает уровень", function()
	local t = setup()
	t.Data.Currency.Essence = 1000
	t.Purchase("ConveyorSpeed", 1)

	assert(t.Data.Factory.ConveyorSpeedLevel == 1, "уровень повышен")
	assert(t.Data.Currency.Essence == 1000 - t.Upgrades.ConveyorSpeed.Levels[1].Price, "списана цена уровня 1")
end)

test("Каждый апгрейд пишет свой уровень в профиль", function()
	local t = setup()
	t.Data.Currency.Essence = 1_000_000
	for _, id in { "StorageCapacity", "CollectionRadius", "CollectionSpeed" } do
		t.Purchase(id, 1)
	end
	assert(t.Data.Factory.StorageCapacityLevel == 1)
	assert(t.Data.Collection.RadiusLevel == 1)
	assert(t.Data.Collection.SpeedLevel == 1)
	assert(t.Data.Factory.ConveyorSpeedLevel == 0, "чужой уровень не тронут")
end)

test("Повтор того же запроса (двойной клик) не списывает второй раз", function()
	local t = setup()
	t.Data.Currency.Essence = 1000
	t.Purchase("ConveyorSpeed", 1)
	local after = t.Data.Currency.Essence
	t.World:Advance(2)
	t.Purchase("ConveyorSpeed", 1)

	assert(t.Data.Factory.ConveyorSpeedLevel == 1)
	assert(t.Data.Currency.Essence == after, "повтор отклонён")
end)

test("Нельзя перескочить уровень", function()
	local t = setup()
	t.Data.Currency.Essence = 1_000_000
	t.Purchase("ConveyorSpeed", 3)

	assert(t.Data.Factory.ConveyorSpeedLevel == 0)
	assert(t.Data.Currency.Essence == 1_000_000)
end)

test("Выше MaxLevel купить нельзя", function()
	local t = setup()
	local max = t.Upgrades.StorageCapacity.MaxLevel
	t.Data.Currency.Essence = 1_000_000
	for level = 1, max + 2 do
		t.Purchase("StorageCapacity", level)
		t.World:Advance(2)
	end

	assert(t.Data.Factory.StorageCapacityLevel == max, "остановились на MaxLevel")
	local spent = 0
	for _, step in t.Upgrades.StorageCapacity.Levels do
		spent += step.Price
	end
	assert(t.Data.Currency.Essence == 1_000_000 - spent, "списаны цены ровно MaxLevel уровней")
end)

test("Не хватает Essence — ничего не меняется", function()
	local t = setup()
	t.Data.Currency.Essence = t.Upgrades.ConveyorSpeed.Levels[1].Price - 1
	t.Purchase("ConveyorSpeed", 1)

	assert(t.Data.Factory.ConveyorSpeedLevel == 0)
	assert(t.Data.Currency.Essence == t.Upgrades.ConveyorSpeed.Levels[1].Price - 1)
end)

test("Некорректные аргументы отклоняются", function()
	local t = setup()
	t.Data.Currency.Essence = 1_000_000
	local cases = {
		{ "NoSuchUpgrade", 1 },
		{ 1, 1 },
		{ nil, 1 },
		{ "__index", 1 },
		{ "ConveyorSpeed", 0 / 0 },
		{ "ConveyorSpeed", math.huge },
		{ "ConveyorSpeed", 0.5 },
		{ "ConveyorSpeed", "1" },
		{ "ConveyorSpeed", nil },
	}
	for _, args in cases do
		t.Purchase(args[1], args[2])
		t.World:Advance(2)
	end

	assert(t.Data.Factory.ConveyorSpeedLevel == 0)
	assert(t.Data.Currency.Essence == 1_000_000)
end)

test("Битый уровень или Essence в профиле — покупка отклоняется без записи", function()
	for _, badLevel in { 0 / 0, 1.5, -1, 99, math.huge } do
		local t = setup()
		t.Data.Currency.Essence = 1_000_000
		t.Data.Factory.ConveyorSpeedLevel = badLevel
		t.Purchase("ConveyorSpeed", 1)
		t.Purchase("ConveyorSpeed", 100)
		assert(t.Data.Currency.Essence == 1_000_000, `уровень {badLevel}: Essence не списан`)
		assert(#t.World.Warnings >= 1, "порча данных залогирована")
	end

	for _, badEssence in { 0 / 0, math.huge, -5 } do
		local t = setup()
		t.Data.Currency.Essence = badEssence
		t.Purchase("ConveyorSpeed", 1)
		assert(t.Data.Factory.ConveyorSpeedLevel == 0, `Essence {badEssence}: уровень не выдан`)
	end
end)

test("Rate limit: сверх лимита за окно запросы отбрасываются", function()
	local t = setup()
	local config = t.World:LoadModule("src/shared/Config/FactoryConfig")
	t.Data.Currency.Essence = 1_000_000

	for _ = 1, config.MaxRequestsPerWindow do
		t.Purchase("NoSuchUpgrade", 1)
	end
	t.Purchase("ConveyorSpeed", 1)
	assert(t.Data.Factory.ConveyorSpeedLevel == 0, "запрос сверх лимита отброшен")

	t.World:Advance(config.RequestWindow + 0.1)
	t.Purchase("ConveyorSpeed", 1)
	assert(t.Data.Factory.ConveyorSpeedLevel == 1, "после окна запросы снова проходят")
end)

------------------------------------------------------------------------------------------
-- Конвейер
------------------------------------------------------------------------------------------

test("Конвейер перерабатывает фрагменты с задержкой уровня и шлёт OnEssenceProduced", function()
	local t = setup()
	local delay = t.Upgrades.ConveyorSpeed.BaseValue
	t.Data.Factory.RawFragments = 3
	t.Data.Rebirth.ClarityMultiplier = 2

	t.World:Advance(delay * 0.75)
	assert(t.Data.Currency.Essence == 0, "до истечения задержки ничего не произведено")

	t.World:Advance(delay * 0.75)
	assert(t.Data.Factory.RawFragments == 2, "один цикл")
	assert(t.Data.Currency.Essence == 2, "выход умножен на ClarityMultiplier")
	assert(#t.Produced == 1 and t.Produced[1].Player == t.Player and t.Produced[1].Amount == 2, "событие (player, amount)")

	t.World:Advance(delay * 3)
	assert(t.Data.Factory.RawFragments == 0 and t.Data.Currency.Essence == 6, "буфер переработан полностью")
	assert(#t.Produced == 3)
end)

test("Задержка конвейера пересчитывается из уровня на каждом тике", function()
	local t = setup()
	local track = t.Upgrades.ConveyorSpeed
	t.Data.Factory.RawFragments = 100

	t.World:Advance(track.BaseValue + 0.15)
	local before = #t.Produced
	assert(before == 1)

	t.Data.Factory.ConveyorSpeedLevel = track.MaxLevel
	local fastDelay = track.Levels[track.MaxLevel].Value
	t.World:Advance(fastDelay * 10 + 0.15)
	assert(#t.Produced - before == 10, `после апгрейда 10 циклов, а не {#t.Produced - before}`)
end)

test("Конвейер: уровень выше MaxLevel не ускоряет сверх последней ступени", function()
	local t = setup()
	local track = t.Upgrades.ConveyorSpeed
	t.Data.Factory.RawFragments = 1000
	t.Data.Factory.ConveyorSpeedLevel = 1e9

	t.World:Advance(track.Levels[track.MaxLevel].Value * 10 + 0.05)
	assert(#t.Produced <= 10, "скорость не выше последней ступени")
end)

test("Нечисловой выход конвейера не пишется в профиль", function()
	for _, bad in { 0 / 0, math.huge, -1 } do
		local t = setup()
		t.Data.Factory.RawFragments = 5
		t.Data.Rebirth.ClarityMultiplier = bad
		t.World:Advance(10)

		assert(t.Data.Currency.Essence == 0, `ClarityMultiplier {bad}: Essence не тронут`)
		assert(t.Data.Factory.RawFragments == 5, "фрагменты не потрачены")
		assert(#t.Produced == 0, "событие не отправлено")
		assert(#t.World.Warnings == 1, "одно предупреждение, без спама на каждом тике")
	end
end)

test("S4-1: ошибка на битом профиле одного игрока не останавливает конвейер остальным", function()
	local t = setup()
	local delay = t.Upgrades.ConveyorSpeed.BaseValue
	t.Data.Factory.RawFragments = 5

	-- Битые игроки стоят в списке раньше нормального: без pcall тик падал бы до него.
	local broken, brokenData = t.AddPlayer(1001, true)
	brokenData.Factory.RawFragments = 5
	brokenData.Rebirth = 5 :: any -- индексирование числа бросает ошибку в runConveyor
	local brokenCurrency, brokenCurrencyData = t.AddPlayer(1002, true)
	brokenCurrencyData.Factory.RawFragments = 5
	brokenCurrencyData.Currency = "x" :: any

	t.World:Advance(delay * 4 + 0.15)

	assert(t.Data.Currency.Essence > 0, "у нормального игрока Essence растёт")
	assert(t.Data.Factory.RawFragments < 5, "нормальный игрок тратит фрагменты")
	local normalEvents = 0
	for _, event in t.Produced do
		assert(event.Player ~= broken and event.Player ~= brokenCurrency, "битым игрокам событие не отправлено")
		if event.Player == t.Player then
			normalEvents += 1
		end
	end
	assert(normalEvents >= 3, `OnEssenceProduced нормальному игроку: {normalEvents}`)

	for _, userId in { 1001, 1002 } do
		local count = 0
		for _, message in t.World.Warnings do
			if string.find(message, `({userId})`, 1, true) then
				count += 1
			end
		end
		assert(count == 1, `предупреждение про {userId} ровно одно, а не {count}`)
	end
	assert(#t.World.Warnings == 2, `других предупреждений нет: {#t.World.Warnings}`)
	assert(brokenData.Factory.RawFragments == 5, "битому игроку ничего не списано")
end)

------------------------------------------------------------------------------------------
-- UpgradeEffects (используется и CollectionSystem)
------------------------------------------------------------------------------------------

test("Эффект зажат в [BaseValue, значение MaxLevel] для любого уровня из профиля", function()
	local t = setup()
	local track = t.Upgrades.CollectionRadius
	local maxValue = track.Levels[track.MaxLevel].Value

	assert(t.Effects.GetEffectValue("CollectionRadius", 1e9) == maxValue)
	assert(t.Effects.GetEffectValue("CollectionRadius", math.huge) == maxValue)
	assert(t.Effects.GetEffectValue("CollectionRadius", 0 / 0) == track.BaseValue)
	assert(t.Effects.GetEffectValue("CollectionRadius", -5) == track.BaseValue)
	assert(t.Effects.GetEffectValue("CollectionRadius", "3") == track.BaseValue)
	assert(t.Effects.GetEffectValue("CollectionRadius", 2.7) == track.Levels[2].Value)
end)

test("Во всех треках MaxLevel совпадает с числом уровней", function()
	local t = setup()
	for id, track in t.Upgrades do
		assert(track.MaxLevel == #track.Levels, id)
	end
end)

------------------------------------------------------------------------------------------
-- Миграция v2 → v3
------------------------------------------------------------------------------------------

test("Миграция v2 → v3: StorageCapacity заменяется на StorageCapacityLevel", function()
	local t = setup()
	local v2 = {
		Meta = { SchemaVersion = 2 },
		Currency = { Essence = 50 },
		Factory = { Level = 1, StorageCapacity = 100, RawFragments = 7, ConveyorSpeedLevel = 2, Decor = {} },
	}
	local migrated = t.DataSystem.MigrateProfileData(v2)

	assert(migrated, "миграция прошла")
	assert(migrated.Meta.SchemaVersion == 3 and t.DataSystem.CURRENT_SCHEMA_VERSION == 3)
	assert(migrated.Factory.StorageCapacity == nil, "готовое число удалено")
	assert(migrated.Factory.StorageCapacityLevel == 0, "уровень склада = 0")
	assert(migrated.Factory.RawFragments == 7 and migrated.Factory.ConveyorSpeedLevel == 2, "остальное сохранено")
	assert(migrated.Currency.Essence == 50)
end)

------------------------------------------------------------------------------------------
-- Signal
------------------------------------------------------------------------------------------

test("Signal: Disconnect отписывает обработчик", function()
	local t = setup()
	local Signal = t.World:LoadModule("src/shared/Signal")
	local signal = Signal.new()
	local calls = 0
	local connection = signal:Connect(function(n)
		calls += n
	end)
	signal:Fire(2)
	connection:Disconnect()
	signal:Fire(5)
	assert(calls == 2 and connection.Connected == false)
end)

return tests
