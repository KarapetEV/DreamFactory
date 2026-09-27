--[[
	Тесты эмоционального типа фрагментов (GDD раздел 3, ТЗ 5.2/5.5):
	- тип при спавне выбирается по весам FragmentEmotionConfig (статистика на большой выборке);
	- сбор кладёт фрагмент в Factory.RawFragments[тип], ёмкость ограничивает сумму по типам;
	- миграция v5 → v6 не теряет фрагменты; EconomySnapshot.RawFragments — сумма по типам;
	- конвейер перерабатывает по типам со своим модификатором и шлёт OnEssenceProduced
	  (player, amount, emotionType) на каждый переработанный тип; итоговая Essence сходится.

	Запуск: lune run src/tests/run (из корня репозитория).
]]

local Harness = require("./lib/Harness")

type Test = { Name: string, Run: () -> () }

local tests: { Test } = {}

local function test(name: string, run: () -> ())
	table.insert(tests, { Name = name, Run = run })
end

local EMOTIONS = { "Joyful", "Nostalgic", "Fearful" }

local function buffer(joyful: number, nostalgic: number, fearful: number)
	return { Joyful = joyful, Nostalgic = nostalgic, Fearful = fearful }
end

local function near(a: number, b: number, eps: number?): boolean
	return math.abs(a - b) <= (eps or 1e-9) * math.max(1, math.abs(a), math.abs(b))
end

-- Бонусы петов нейтральны: проверяем только эмоции фрагментов.
local fakePets = {
	GetCachedBonuses = function()
		return { ConveyorSpeedMultiplier = 1, CollectionRadiusMultiplier = 1 }
	end,
}

------------------------------------------------------------------------------------------
-- Мир с CollectionSystem
------------------------------------------------------------------------------------------

local function collectionSetup(overrides: { [string]: any }?)
	local world = Harness.NewWorld()
	local _, dataSystem = world:NewServer()
	local profiles = {}
	local handlers = {}
	local modules: { [string]: any } = {
		["src/server/Systems/DataSystem"] = {
			GetData = function(p)
				return profiles[p]
			end,
			WaitForData = function(p)
				return profiles[p]
			end,
			BuildDefaultProfile = dataSystem.BuildDefaultProfile,
		},
		["src/server/Systems/PetSystem"] = fakePets,
		["src/shared/Remotes"] = {
			RequestCollect = {
				OnServerEvent = {
					Connect = function(_self, fn)
						handlers.RequestCollect = fn
					end,
				},
			},
		},
	}
	for path, module in overrides or {} do
		modules[path] = module
	end
	local collection = world:LoadModule("src/server/Systems/CollectionSystem", modules)

	local player = world:NewPlayer(1)
	local data = dataSystem.BuildDefaultProfile()
	profiles[player] = data
	world.Players = { player }

	local t = { World = world, Collection = collection, Player = player, Data = data }

	function t.Fragments()
		local list = {}
		for _, instance in world.Instances do
			if instance.ClassName == "Part" and instance:GetAttribute("FragmentId") and not instance.Destroyed then
				table.insert(list, instance)
			end
		end
		return list
	end

	-- Ставит персонажа прямо на фрагмент и шлёт RequestCollect(id); время сдвигается за кулдаун.
	function t.Collect(fragment)
		local root = {
			Position = fragment.Position,
			IsA = function(_self, name)
				return name == "BasePart"
			end,
		}
		local humanoid = { Health = 100 }
		player.Character = {
			FindFirstChildOfClass = function(_self, className)
				return if className == "Humanoid" then humanoid else nil
			end,
			FindFirstChild = function(_self, name)
				return if name == "HumanoidRootPart" then root else nil
			end,
		}
		world:Advance(10)
		handlers.RequestCollect(player, fragment:GetAttribute("FragmentId"))
	end

	return t
end

------------------------------------------------------------------------------------------
-- Мир с FactorySystem
------------------------------------------------------------------------------------------

local function factorySetup(overrides: { [string]: any }?)
	local world = Harness.NewWorld()
	local _, dataSystem = world:NewServer()
	local player = world:NewPlayer()
	local data = dataSystem.BuildDefaultProfile()
	local profiles = { [player] = data }
	local snapshots = {}
	local modules: { [string]: any } = {
		["src/server/Systems/DataSystem"] = {
			GetData = function(p)
				return profiles[p]
			end,
			BuildDefaultProfile = dataSystem.BuildDefaultProfile,
		},
		["src/server/Systems/PetSystem"] = fakePets,
		["src/shared/Remotes"] = {
			PurchaseUpgrade = { OnServerEvent = { Connect = function() end } },
			EconomySnapshot = {
				OnServerEvent = { Connect = function() end },
				FireClient = function(_self, _target, snapshot)
					table.insert(snapshots, Harness.DeepCopy(snapshot))
				end,
			},
		},
	}
	for path, module in overrides or {} do
		modules[path] = module
	end
	local factory = world:LoadModule("src/server/Systems/FactorySystem", modules)
	factory.Init()
	world.Players = { player }

	local produced = {}
	factory.OnEssenceProduced:Connect(function(p, amount, emotionType)
		table.insert(produced, { Player = p, Amount = amount, EmotionType = emotionType })
	end)

	return {
		World = world,
		Player = player,
		Data = data,
		Factory = factory,
		Produced = produced,
		Snapshots = snapshots,
		DataSystem = dataSystem,
		Emotion = world:LoadModule("src/shared/Config/FragmentEmotionConfig"),
		Delay = world:LoadModule("src/shared/Config/UpgradeConfig").ConveyorSpeed.BaseValue,
	}
end

local function factoryConfigWith(world, fragmentsPerCycle: number)
	local config = Harness.DeepCopy(world:LoadModule("src/shared/Config/FactoryConfig"))
	config.FragmentsPerCycle = fragmentsPerCycle
	return config
end

------------------------------------------------------------------------------------------
-- Конфиг
------------------------------------------------------------------------------------------

test("FragmentEmotionConfig: веса и модификаторы ровно для эмоций петов; заглушки", function()
	local world = Harness.NewWorld()
	local config = world:LoadModule("src/shared/Config/FragmentEmotionConfig")
	local species = world:LoadModule("src/shared/Config/PetSpeciesConfig")
	assert(table.concat(species.EmotionTypes, ",") == table.concat(EMOTIONS, ","), "тот же enum, что у петов")
	for _, emotion in EMOTIONS do
		assert(config.SpawnWeights[emotion] == 1, `{emotion}: равные трети`)
	end
	assert(config.EssenceModifiers.Joyful == 1.1)
	assert(config.EssenceModifiers.Nostalgic == 1)
	assert(config.EssenceModifiers.Fearful == 0.9)
end)

------------------------------------------------------------------------------------------
-- Тип при спавне
------------------------------------------------------------------------------------------

test("RollEmotionType: равные веса — трети на выборке 60 000", function()
	local t = collectionSetup()
	local counts = { Joyful = 0, Nostalgic = 0, Fearful = 0 }
	local n = 60_000
	for _ = 1, n do
		local emotion = t.Collection.RollEmotionType(math.random())
		counts[emotion] += 1
	end
	for _, emotion in EMOTIONS do
		local share = counts[emotion] / n
		assert(math.abs(share - 1 / 3) < 0.015, `{emotion}: доля {share}`)
	end
end)

test("RollEmotionType: неравные веса из конфига 6:3:1 и нулевой вес", function()
	local world = Harness.NewWorld()
	local config = Harness.DeepCopy(world:LoadModule("src/shared/Config/FragmentEmotionConfig"))
	config.SpawnWeights = { Joyful = 6, Nostalgic = 3, Fearful = 1 }
	local t = collectionSetup({ ["src/shared/Config/FragmentEmotionConfig"] = config })
	local counts = { Joyful = 0, Nostalgic = 0, Fearful = 0 }
	local n = 60_000
	for _ = 1, n do
		counts[t.Collection.RollEmotionType(math.random())] += 1
	end
	local expected = { Joyful = 0.6, Nostalgic = 0.3, Fearful = 0.1 }
	for _, emotion in EMOTIONS do
		local share = counts[emotion] / n
		assert(math.abs(share - expected[emotion]) < 0.015, `{emotion}: доля {share}, ожидалось {expected[emotion]}`)
	end

	config.SpawnWeights = { Joyful = 0, Nostalgic = 1, Fearful = 0 }
	local only = collectionSetup({ ["src/shared/Config/FragmentEmotionConfig"] = config })
	for _, unit in { 0, 0.001, 0.5, 0.999999, 1 } do
		assert(only.Collection.RollEmotionType(unit) == "Nostalgic", `unit {unit}: тип с нулевым весом не выпадает`)
	end
end)

test("RollEmotionType: границы отрезков — порядок эмоций из PetSpeciesConfig", function()
	local t = collectionSetup()
	assert(t.Collection.RollEmotionType(0) == "Joyful")
	assert(t.Collection.RollEmotionType(0.33) == "Joyful")
	assert(t.Collection.RollEmotionType(0.34) == "Nostalgic")
	assert(t.Collection.RollEmotionType(0.66) == "Nostalgic")
	assert(t.Collection.RollEmotionType(0.67) == "Fearful")
	assert(t.Collection.RollEmotionType(1) == "Fearful", "unit = 1 не выходит за последний тип")
end)

test("Спавн: тип из серверного Random, сбор кладёт фрагмент в буфер своего типа", function()
	for _, case in { { 0.1, "Joyful" }, { 0.5, "Nostalgic" }, { 0.9, "Fearful" } } do
		local t = collectionSetup()
		t.World.NextRandom = function()
			return case[1]
		end
		t.Collection.Init()
		local fragment = assert(t.Fragments()[1], "фрагмент заспавнен")
		assert(fragment:GetAttribute("EmotionType") == nil, "тип клиенту не публикуется")
		t.Collect(fragment)
		for _, emotion in EMOTIONS do
			local expected = if emotion == case[2] then 1 else 0
			assert(t.Data.Factory.RawFragments[emotion] == expected, `{case[2]}: {emotion} = {t.Data.Factory.RawFragments[emotion]}`)
		end
	end
end)

test("Сбор: ёмкость склада ограничивает сумму по типам", function()
	local t = collectionSetup()
	local capacity = t.World:LoadModule("src/shared/UpgradeEffects").GetEffectValue("StorageCapacity", 0)
	t.Data.Factory.RawFragments = buffer(capacity - 2, 1, 1) -- сумма = ёмкость
	t.World.NextRandom = function()
		return 0.9 -- Fearful
	end
	t.Collection.Init()
	local fragment = t.Fragments()[1]
	t.Collect(fragment)
	assert(t.Data.Factory.RawFragments.Fearful == 1, "склад полон — фрагмент не принят")
	assert(not fragment.Destroyed, "фрагмент остался в мире")

	t.Data.Factory.RawFragments.Joyful -= 1
	t.Collect(fragment)
	assert(t.Data.Factory.RawFragments.Fearful == 2, "место появилось — принят в свой тип")
	assert(fragment.Destroyed)
end)

test("Сбор: битый буфер — отказ без записи, фрагмент остаётся", function()
	for _, broken in { buffer(0 / 0, 0, 0), buffer(-1, 0, 0), 5, { Joyful = 0, Nostalgic = 0 } } do
		local t = collectionSetup()
		t.Data.Factory.RawFragments = broken
		t.Collection.Init()
		local fragment = t.Fragments()[1]
		t.Collect(fragment)
		assert(not fragment.Destroyed, "фрагмент не засчитан")
	end
end)

------------------------------------------------------------------------------------------
-- Миграция и снимок
------------------------------------------------------------------------------------------

test("Миграция v5 → v6: число целиком уходит в Nostalgic, сумма не теряется", function()
	local world = Harness.NewWorld()
	local _, dataSystem = world:NewServer()
	assert(dataSystem.CURRENT_SCHEMA_VERSION == 6)
	for _, old in { 0, 7, 2.5, 1_000_000 } do
		local v5 = { Meta = { SchemaVersion = 5 }, Factory = { RawFragments = old, StorageCapacityLevel = 2 } }
		local migrated = assert(dataSystem.MigrateProfileData(v5))
		local raw = migrated.Factory.RawFragments
		assert(type(raw) == "table", "буфер стал таблицей")
		assert(raw.Joyful == 0 and raw.Nostalgic == old and raw.Fearful == 0, `{old}: {raw.Joyful}/{raw.Nostalgic}/{raw.Fearful}`)
		assert(migrated.Factory.StorageCapacityLevel == 2, "соседние поля не тронуты")
	end

	-- Запись до версионирования (v0) без Factory: пустой буфер из шаблона.
	local legacy = assert(dataSystem.MigrateProfileData({}))
	local raw = legacy.Factory.RawFragments
	assert(raw.Joyful == 0 and raw.Nostalgic == 0 and raw.Fearful == 0)

	-- Частично заполненный буфер: недостающие эмоции дозаполняются нулём, данные целы.
	local partial = assert(dataSystem.MigrateProfileData({
		Meta = { SchemaVersion = 6 },
		Factory = { RawFragments = { Joyful = 3 } },
	}))
	raw = partial.Factory.RawFragments
	assert(raw.Joyful == 3 and raw.Nostalgic == 0 and raw.Fearful == 0)
end)

test("Миграция v5 → v6: битое число не превращается в буфер — конвейер сообщает о порче", function()
	local t = factorySetup()
	local v5 = { Meta = { SchemaVersion = 5 }, Factory = { RawFragments = 0 / 0 } }
	local migrated = assert(t.DataSystem.MigrateProfileData(v5))
	assert(type(migrated.Factory.RawFragments) == "number", "порча не замаскирована нулями")

	t.Data.Factory.RawFragments = migrated.Factory.RawFragments
	t.Data.Currency.Essence = 10
	t.World:Advance(t.Delay * 3)
	assert(t.Data.Currency.Essence == 10 and #t.Produced == 0, "ничего не начислено")
	local reported = false
	for _, warning in t.World.Warnings do
		if string.find(warning, "RawFragments повреждён", 1, true) then
			reported = true
		end
	end
	assert(reported, "порча записана в лог")
end)

test("EconomySnapshot.RawFragments — сумма по типам; битый буфер — 0", function()
	local t = factorySetup()
	t.Data.Factory.RawFragments = buffer(2, 3, 4)
	t.Factory.PushSnapshot(t.Player)
	assert(t.Snapshots[#t.Snapshots].RawFragments == 9, `сумма {t.Snapshots[#t.Snapshots].RawFragments}`)
	assert(type(t.Snapshots[#t.Snapshots].RawFragments) == "number", "клиенту — число, не разбивка")

	t.Data.Factory.RawFragments = buffer(1, 0 / 0, 0)
	t.Factory.PushSnapshot(t.Player)
	assert(t.Snapshots[#t.Snapshots].RawFragments == 0)
end)

------------------------------------------------------------------------------------------
-- Конвейер
------------------------------------------------------------------------------------------

test("Конвейер: по одному фрагменту за цикл, событие с типом и модификатором каждого", function()
	local t = factorySetup()
	t.Data.Factory.RawFragments = buffer(1, 1, 1)
	t.Data.Rebirth.ClarityMultiplier = 2
	t.World:Advance(t.Delay * 3.5)

	assert(#t.Produced == 3, `событий {#t.Produced}`)
	local expectedOrder = { "Joyful", "Nostalgic", "Fearful" }
	for index, event in t.Produced do
		local emotion = expectedOrder[index]
		assert(event.Player == t.Player)
		assert(event.EmotionType == emotion, `событие {index}: {event.EmotionType}`)
		assert(near(event.Amount, 2 * t.Emotion.EssenceModifiers[emotion]), `{emotion}: {event.Amount}`)
	end
	assert(near(t.Data.Currency.Essence, 2 * (1.1 + 1 + 0.9)), `Essence {t.Data.Currency.Essence}`)
	local raw = t.Data.Factory.RawFragments
	assert(raw.Joyful == 0 and raw.Nostalgic == 0 and raw.Fearful == 0)
end)

test("Конвейер: цикл на несколько типов — событие на каждый реально переработанный тип", function()
	local world = Harness.NewWorld()
	local t = factorySetup({ ["src/shared/Config/FactoryConfig"] = factoryConfigWith(world, 5) })
	t.Data.Factory.RawFragments = buffer(2, 0, 4) -- Nostalgic пуст — события по нему нет
	t.World:Advance(t.Delay * 1.5)

	assert(#t.Produced == 2, `за один цикл {#t.Produced} событий`)
	assert(t.Produced[1].EmotionType == "Joyful" and near(t.Produced[1].Amount, 2 * 1.1))
	assert(t.Produced[2].EmotionType == "Fearful" and near(t.Produced[2].Amount, 3 * 0.9), "взято 3 из 4 до лимита цикла")
	local raw = t.Data.Factory.RawFragments
	assert(raw.Joyful == 0 and raw.Nostalgic == 0 and raw.Fearful == 1, "в буфере остался 1 Fearful")

	t.World:Advance(t.Delay)
	assert(#t.Produced == 3 and t.Produced[3].EmotionType == "Fearful" and near(t.Produced[3].Amount, 0.9))
	assert(near(t.Data.Currency.Essence, 2 * 1.1 + 4 * 0.9))
end)

test("Конвейер: итоговая Essence сходится с модификаторами на большом буфере", function()
	local world = Harness.NewWorld()
	local t = factorySetup({ ["src/shared/Config/FactoryConfig"] = factoryConfigWith(world, 7) })
	local counts = { Joyful = 137, Nostalgic = 211, Fearful = 452 }
	t.Data.Factory.RawFragments = buffer(counts.Joyful, counts.Nostalgic, counts.Fearful)
	t.Data.Rebirth.ClarityMultiplier = 1.75
	t.World:Advance(t.Delay * 200)

	local raw = t.Data.Factory.RawFragments
	assert(raw.Joyful == 0 and raw.Nostalgic == 0 and raw.Fearful == 0, "буфер переработан")

	local expectedTotal = 0
	local byType = { Joyful = 0, Nostalgic = 0, Fearful = 0 }
	for _, emotion in EMOTIONS do
		expectedTotal += counts[emotion] * 1.75 * t.Emotion.EssenceModifiers[emotion]
	end
	local eventSum = 0
	for _, event in t.Produced do
		byType[event.EmotionType] += event.Amount
		eventSum += event.Amount
	end
	assert(near(t.Data.Currency.Essence, expectedTotal), `Essence {t.Data.Currency.Essence} vs {expectedTotal}`)
	assert(near(eventSum, t.Data.Currency.Essence), "сумма событий = начисленная Essence")
	for _, emotion in EMOTIONS do
		assert(
			near(byType[emotion], counts[emotion] * 1.75 * t.Emotion.EssenceModifiers[emotion]),
			`{emotion}: по событиям {byType[emotion]}`
		)
	end
end)

test("Конвейер: модификаторы берутся из FragmentEmotionConfig", function()
	local world = Harness.NewWorld()
	local emotion = Harness.DeepCopy(world:LoadModule("src/shared/Config/FragmentEmotionConfig"))
	emotion.EssenceModifiers = { Joyful = 3, Nostalgic = 0.5, Fearful = 2 }
	local t = factorySetup({ ["src/shared/Config/FragmentEmotionConfig"] = emotion })
	t.Data.Factory.RawFragments = buffer(1, 2, 1)
	t.World:Advance(t.Delay * 4.5)
	assert(near(t.Data.Currency.Essence, 3 + 2 * 0.5 + 2), `Essence {t.Data.Currency.Essence}`)
end)

test("Конвейер: переполнение Essence — ни одного типа не списано, событий нет", function()
	local t = factorySetup()
	t.Data.Factory.RawFragments = buffer(1, 1, 1)
	t.Data.Currency.Essence = math.huge
	t.World:Advance(t.Delay * 3)
	local raw = t.Data.Factory.RawFragments
	assert(raw.Joyful == 1 and raw.Nostalgic == 1 and raw.Fearful == 1, "буфер не тронут")
	assert(#t.Produced == 0)
end)

test("FragmentBuffer: Empty и Total (сумма, порча)", function()
	local world = Harness.NewWorld()
	local fragmentBuffer = world:LoadModule("src/shared/FragmentBuffer")
	local empty = fragmentBuffer.Empty()
	assert(empty.Joyful == 0 and empty.Nostalgic == 0 and empty.Fearful == 0)
	assert(fragmentBuffer.Total(buffer(1, 2, 3.5)) == 6.5)
	assert(fragmentBuffer.Total(buffer(1, -2, 3)) == nil)
	assert(fragmentBuffer.Total(buffer(1, math.huge, 3)) == nil)
	assert(fragmentBuffer.Total(7) == nil)
	assert(fragmentBuffer.Total({ Joyful = 1 }) == nil, "без какой-то эмоции — порча")
end)

return tests
