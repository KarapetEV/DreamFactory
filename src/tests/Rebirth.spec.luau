--[[
	Тесты RebirthSystem (S9, раздел 5.4 ТЗ): порог, сброс к StartingProfileConfig,
	исключения сброса (Decor, AutoCollectorOwned), пересчёт ClarityMultiplier/CurrentBiome,
	rate limit, битый профиль, расширенный EconomySnapshot и интеграция с конвейером.

	Запуск: lune run src/tests/run (из корня репозитория).
]]

local Harness = require("./lib/Harness")

type Test = { Name: string, Run: () -> () }

local tests: { Test } = {}

local function test(name: string, run: () -> ())
	table.insert(tests, { Name = name, Run = run })
end

-- RebirthSystem + FactorySystem в одном «сервере»: общий подменённый DataSystem
-- (профили в памяти), перехват обработчиков и EconomySnapshot.FireClient.
local function setup()
	local world = Harness.NewWorld()
	local _, dataSystem = world:NewServer()
	local profiles = {}
	local handlers = {}
	local snapshots = {}

	local function remote(name: string)
		return {
			OnServerEvent = {
				Connect = function(_self, fn)
					handlers[name] = fn
				end,
			},
			FireClient = function(_self, target, snapshot)
				if name == "EconomySnapshot" then
					table.insert(snapshots, { Player = target, Snapshot = Harness.DeepCopy(snapshot) })
				end
			end,
		}
	end

	local fakeRemotes = {}
	for _, name in {
		"PurchaseUpgrade",
		"EconomySnapshot",
		"PerformRebirth",
		"HatchCocoon",
		"EquipPet",
		"UnequipPet",
		"PetSnapshot",
	} do
		fakeRemotes[name] = remote(name)
	end

	local overrides = {
		["src/server/Systems/DataSystem"] = {
			GetData = function(p)
				return profiles[p]
			end,
			WaitForData = function(p)
				return profiles[p]
			end,
			BuildDefaultProfile = dataSystem.BuildDefaultProfile,
		},
		["src/shared/Remotes"] = fakeRemotes,
	}
	local factory = world:LoadModule("src/server/Systems/FactorySystem", overrides)
	overrides["src/server/Systems/FactorySystem"] = factory
	local rebirth = world:LoadModule("src/server/Systems/RebirthSystem", overrides)
	rebirth.Init()

	local player = world:NewPlayer(42)
	local data = dataSystem.BuildDefaultProfile()
	profiles[player] = data

	local config = world:LoadModule("src/shared/Config/RebirthConfig")

	return {
		World = world,
		Player = player,
		Data = data,
		Factory = factory,
		Rebirth = rebirth,
		Snapshots = snapshots,
		Config = config,
		DataSystem = dataSystem,
		Start = world:LoadModule("src/shared/Config/StartingProfileConfig"),
		Biomes = world:LoadModule("src/shared/Config/BiomeConfig"),
		-- Вызов PerformRebirth; по умолчанию сдвигает время, чтобы не упираться в rate limit.
		Perform = function(noAdvance: boolean?, ...)
			if not noAdvance then
				world:Advance(1)
			end
			handlers.PerformRebirth(player, ...)
		end,
		-- Профиль «прокачанного» игрока, готового к rebirth.
		Grind = function()
			data.Currency.Essence = config.MinEssence + 123
			data.Factory.Level = 7
			data.Factory.StorageCapacityLevel = 3
			data.Factory.ConveyorSpeedLevel = 4
			data.Factory.RawFragments = 55
			data.Factory.Decor = { "Lantern", "Clock" }
			data.Collection.RadiusLevel = 2
			data.Collection.SpeedLevel = 5
			data.Collection.AutoCollectorOwned = true
		end,
		Purchase = function(...)
			handlers.PurchaseUpgrade(player, ...)
		end,
		PerformAs = function(p, ...)
			handlers.PerformRebirth(p, ...)
		end,
		LastSnapshot = function()
			return snapshots[#snapshots]
		end,
	}
end

-- Биом с наименьшим положительным порогом (второй биом).
local function secondBiome(t)
	local best
	for _, biome in t.Biomes do
		if biome.RebirthThreshold > 0 and (not best or biome.RebirthThreshold < best.RebirthThreshold) then
			best = biome
		end
	end
	return assert(best, "в BiomeConfig есть биом с порогом > 0")
end

------------------------------------------------------------------------------------------
-- Конфиги
------------------------------------------------------------------------------------------

test("BiomeConfig: ключ = Id, пороги уникальны, ровно один с порогом 0", function()
	local t = setup()
	local zero, seen = 0, {}
	for key, biome in t.Biomes do
		assert(biome.Id == key)
		assert(not seen[biome.RebirthThreshold], "порог уникален")
		seen[biome.RebirthThreshold] = true
		if biome.RebirthThreshold == 0 then
			zero += 1
		end
	end
	assert(zero == 1)
	assert(t.Config.MinEssence > 0)
end)

test("Стартовая Essence ниже порога rebirth (иначе повторный rebirth бесплатен)", function()
	local t = setup()
	assert(t.Start.Essence < t.Config.MinEssence)
end)

test("Битый раздел Rebirth не блокирует ответ на PurchaseUpgrade", function()
	local t = setup()
	t.Data.Currency.Essence = 1_000_000
	;(t.Data :: any).Rebirth = "broken"
	t.Factory.Init() -- регистрирует обработчик PurchaseUpgrade (тик не запущен: Players пуст)
	t.World:Advance(1)
	t.Purchase("ConveyorSpeed", 1)
	local snap = t.LastSnapshot()
	assert(snap and snap.Snapshot.PurchaseAck == "ConveyorSpeed", "ответ на покупку ушёл")
	assert(t.Data.Factory.ConveyorSpeedLevel == 1)
end)

------------------------------------------------------------------------------------------
-- PerformRebirth
------------------------------------------------------------------------------------------

test("Порог не достигнут — отказ, профиль не меняется", function()
	local t = setup()
	t.Grind()
	t.Data.Currency.Essence = t.Config.MinEssence - 1
	local before = Harness.DeepCopy(t.Data)
	t.Perform()

	assert(t.Data.Rebirth.Count == 0, "Count не изменился")
	for section, value in before do
		for key, old in value do
			if type(old) ~= "table" then
				assert(t.Data[section][key] == old, `{section}.{key} изменён`)
			end
		end
	end
	local snap = t.LastSnapshot()
	assert(snap.Player == t.Player and snap.Snapshot.RebirthAck == false, "отказ подтверждён снимком")
end)

test("Успешный rebirth: сброс к StartingProfileConfig, Decor и AutoCollectorOwned целы, Count +1", function()
	local t = setup()
	t.Grind()
	t.Perform()

	local d, s = t.Data, t.Start
	assert(d.Rebirth.Count == 1, "Count + 1")
	assert(d.Currency.Essence == s.Essence, "Essence сброшена")
	assert(d.Factory.Level == s.FactoryLevel)
	assert(d.Factory.StorageCapacityLevel == s.StorageCapacityLevel)
	assert(d.Factory.ConveyorSpeedLevel == s.ConveyorSpeedLevel)
	assert(d.Factory.RawFragments == 0, "буфер сырых фрагментов обнулён")
	assert(d.Collection.RadiusLevel == s.CollectionRadiusLevel)
	assert(d.Collection.SpeedLevel == s.CollectionSpeedLevel)

	assert(#d.Factory.Decor == 2 and d.Factory.Decor[1] == "Lantern", "Decor не тронут")
	assert(d.Collection.AutoCollectorOwned == true, "AutoCollectorOwned не тронут")

	local snap = t.LastSnapshot().Snapshot
	assert(snap.RebirthAck == true and snap.RebirthCount == 1 and snap.Essence == s.Essence)
	assert(snap.ClarityMultiplier == d.Rebirth.ClarityMultiplier and snap.CurrentBiome == d.Rebirth.CurrentBiome)
end)

test("Петы и монетизация при rebirth не сбрасываются", function()
	local t = setup()
	t.Grind()
	table.insert(t.Data.Pets, { Id = "p1", SpeciesId = "DozySheep", Rarity = "Rare", Level = 1, Equipped = true })
	table.insert(t.Data.Monetization.GamePassesOwned, "ExtraPetSlots")
	t.Perform()
	assert(t.Data.Rebirth.Count == 1)
	assert(#t.Data.Pets == 1 and t.Data.Pets[1].Equipped == true)
	assert(t.Data.Monetization.GamePassesOwned[1] == "ExtraPetSlots")
end)

test("До порога второго биома: множитель стартовый, биом стартовый", function()
	local t = setup()
	t.Grind()
	t.Perform()
	local second = secondBiome(t)
	if second.RebirthThreshold > 1 then
		assert(t.Data.Rebirth.CurrentBiome == t.Start.StartingBiomeId)
		local zeroBonus = t.Biomes[t.Start.StartingBiomeId].ClarityMultiplierBonus
		assert(t.Data.Rebirth.ClarityMultiplier == t.Start.ClarityMultiplier + zeroBonus)
	end
end)

test("Пересечение порога второго биома пересчитывает ClarityMultiplier и CurrentBiome", function()
	local t = setup()
	local second = secondBiome(t)
	local first = t.Biomes[t.Start.StartingBiomeId]
	t.Grind()
	t.Data.Rebirth.Count = second.RebirthThreshold - 1
	t.Data.Rebirth.ClarityMultiplier = 999 -- битый/старый множитель не накапливается: пересчёт с нуля
	t.Perform()

	assert(t.Data.Rebirth.Count == second.RebirthThreshold)
	assert(t.Data.Rebirth.CurrentBiome == second.Id, `биом {t.Data.Rebirth.CurrentBiome}`)
	local expected = t.Start.ClarityMultiplier + first.ClarityMultiplierBonus + second.ClarityMultiplierBonus
	assert(
		math.abs(t.Data.Rebirth.ClarityMultiplier - expected) < 1e-9,
		`множитель {t.Data.Rebirth.ClarityMultiplier}, ожидалось {expected}`
	)
end)

test("ComputeProgress: биом с наибольшим открытым порогом, бонусы суммируются", function()
	local t = setup()
	local second = secondBiome(t)
	local below = t.Rebirth.ComputeProgress(second.RebirthThreshold - 1)
	local at = t.Rebirth.ComputeProgress(second.RebirthThreshold)
	assert(below.CurrentBiome == t.Start.StartingBiomeId and at.CurrentBiome == second.Id)
	assert(at.ClarityMultiplier - below.ClarityMultiplier == second.ClarityMultiplierBonus)
end)

test("Повторный rebirth сразу после первого — отказ (порог снова не достигнут)", function()
	local t = setup()
	t.Grind()
	t.Perform()
	t.Perform()
	assert(t.Data.Rebirth.Count == 1, `Count {t.Data.Rebirth.Count}`)
	assert(t.LastSnapshot().Snapshot.RebirthAck == false)
end)

test("Двойная доставка того же запроса без паузы — один rebirth", function()
	local t = setup()
	t.Grind()
	t.Perform()
	t.Perform(true)
	assert(t.Data.Rebirth.Count == 1)
end)

test("Аргументы от клиента игнорируются", function()
	local t = setup()
	t.Grind()
	t.Perform(false, { Count = 100, ClarityMultiplier = 1e9 }, "Nightmares")
	assert(t.Data.Rebirth.Count == 1)
	assert(t.Data.Rebirth.ClarityMultiplier == t.Rebirth.ComputeProgress(1).ClarityMultiplier)
end)

test("Rate limit: сверх лимита за окно запросы отбрасываются без ответа", function()
	local t = setup()
	t.World:Advance(5)
	for _ = 1, 10 do
		t.Perform(true)
	end
	assert(#t.Snapshots == t.Config.MaxRequestsPerWindow, `ответов {#t.Snapshots}`)
	-- После окна — снова обрабатываются.
	t.Grind()
	t.World:Advance(t.Config.RequestWindow + 0.1)
	t.Perform(true)
	assert(t.Data.Rebirth.Count == 1)
end)

test("Битый профиль: отказ без записи и без падения, одно предупреждение", function()
	for _, corrupt in {
		function(d)
			d.Currency.Essence = 0 / 0
		end,
		function(d)
			d.Currency.Essence = math.huge
		end,
		function(d)
			d.Rebirth.Count = -1
		end,
		function(d)
			d.Rebirth.Count = 1.5
		end,
		function(d)
			d.Rebirth.Count = "3"
		end,
		function(d)
			d.Collection = 5
		end,
		function(d)
			d.Rebirth = "broken"
		end,
	} do
		local t = setup()
		t.Grind()
		corrupt(t.Data)
		local ok = pcall(t.Perform)
		assert(ok, "обработчик не бросает наружу")
		assert(ok and pcall(t.Perform), "и повторно тоже")
		assert(t.Data.Factory.ConveyorSpeedLevel == 4, "прогресс не сброшен")
		local rebirthWarnings = 0
		for _, text in t.World.Warnings do
			if string.find(text, "[RebirthSystem]", 1, true) then
				rebirthWarnings += 1
			end
		end
		assert(rebirthWarnings == 1, `предупреждений RebirthSystem {rebirthWarnings}`)
	end
end)

test("Нет профиля (ещё грузится) — отказ без ошибки и без ответа", function()
	local t = setup()
	local stranger = t.World:NewPlayer(7)
	t.World:Advance(1)
	assert(pcall(t.PerformAs, stranger))
	assert(#t.Snapshots == 0, "снимка без профиля нет")
end)

test("Вышедший игрок (Parent = nil) игнорируется полностью", function()
	local t = setup()
	t.Grind()
	t.Player.Parent = nil
	t.Perform()
	assert(t.Data.Rebirth.Count == 0 and #t.Snapshots == 0)
end)

------------------------------------------------------------------------------------------
-- Пересчёт при загрузке профиля (DataSystem.MigrateProfileData — шаг после миграции/reconcile)
------------------------------------------------------------------------------------------

-- Загружает «сохранённый» профиль тем же шагом, что onPlayerAdded.
local function loadSaved(t, count, multiplier, biome)
	local saved = t.DataSystem.BuildDefaultProfile()
	saved.Rebirth.Count = count
	saved.Rebirth.ClarityMultiplier = multiplier
	saved.Rebirth.CurrentBiome = biome
	local data, reason = t.DataSystem.MigrateProfileData(Harness.DeepCopy(saved))
	assert(data, `профиль не загружен: {reason}`)
	return data
end

test("Load: Count = 5, сохранённый множитель — мусор (999) → пересчёт по Count из BiomeConfig", function()
	local t = setup()
	local expected = t.Rebirth.ComputeProgress(5)
	local data = loadSaved(t, 5, 999, "NoSuchBiome")
	assert(data.Rebirth.Count == 5, "Count не тронут")
	assert(data.Rebirth.ClarityMultiplier == expected.ClarityMultiplier, `множитель {data.Rebirth.ClarityMultiplier}`)
	assert(data.Rebirth.CurrentBiome == expected.CurrentBiome, `биом {data.Rebirth.CurrentBiome}`)
	assert(data.Rebirth.CurrentBiome == t.Biomes.Nightmares.Id and data.Rebirth.ClarityMultiplier == 1.5)
end)

test("Load: устаревший множитель до-патчевского баланса (0.3) обновляется до текущего", function()
	local t = setup()
	local stale = loadSaved(t, 5, 0.3, "DreamMeadow")
	local expected = t.Start.ClarityMultiplier + t.Biomes.Nightmares.ClarityMultiplierBonus
	assert(stale.Rebirth.ClarityMultiplier == expected, `множитель {stale.Rebirth.ClarityMultiplier}`)
	assert(stale.Rebirth.CurrentBiome == "Nightmares")
end)

test("Load: NaN/inf/строка в множителе и пустой биом чинятся; Count = 0 даёт стартовые значения", function()
	local t = setup()
	for _, bad in { 0 / 0, math.huge, -math.huge, "2" } do
		local data = loadSaved(t, 0, bad, "")
		assert(data.Rebirth.ClarityMultiplier == t.Start.ClarityMultiplier, `множитель при {tostring(bad)}`)
		assert(data.Rebirth.CurrentBiome == t.Start.StartingBiomeId)
	end
end)

test("Load: битый Count (отрицательный/дробный/NaN/строка) не трогается и не даёт пересчёта", function()
	local t = setup()
	for _, badCount in { -1, 1.5, 0 / 0, math.huge, "3" } do
		local data = loadSaved(t, badCount, 777, "Custom")
		assert(
			data.Rebirth.Count == badCount or (badCount ~= badCount and data.Rebirth.Count ~= data.Rebirth.Count),
			"Count не изменён"
		)
		assert(data.Rebirth.ClarityMultiplier == 777 and data.Rebirth.CurrentBiome == "Custom", "поля не перезаписаны")
	end
end)

test("Load: Rebirth не таблица — загрузка не падает (об этом сообщит RebirthSystem)", function()
	local t = setup()
	local saved = t.DataSystem.BuildDefaultProfile()
	;(saved :: any).Rebirth = "broken"
	local ok, data = pcall(t.DataSystem.MigrateProfileData, saved)
	assert(ok and data, "миграция не бросает")
end)

test("Load: старый профиль без раздела Rebirth получает Count = 0 и стартовые значения", function()
	local t = setup()
	local data = t.DataSystem.MigrateProfileData({ Currency = { Essence = 10 } })
	assert(data.Rebirth.Count == 0 and data.Rebirth.ClarityMultiplier == t.Start.ClarityMultiplier)
end)

------------------------------------------------------------------------------------------
-- EconomySnapshot и интеграция с конвейером
------------------------------------------------------------------------------------------

test("EconomySnapshot на тике содержит прогресс rebirth и шлётся сразу при его смене", function()
	local t = setup()
	t.Factory.Init()
	t.World.Players = { t.Player }
	t.World:Advance(1)
	local first = t.LastSnapshot().Snapshot
	assert(first.RebirthCount == 0 and first.CurrentBiome == t.Start.StartingBiomeId)
	assert(first.ClarityMultiplier == t.Start.ClarityMultiplier and first.RebirthAck == nil)

	-- Смена прогресса rebirth в обход ремоуты (другая система) — снимок уходит на ближайшем тике.
	local count = #t.Snapshots
	t.Data.Rebirth.Count = 3
	t.World:Advance(0.15)
	assert(#t.Snapshots == count + 1 and t.LastSnapshot().Snapshot.RebirthCount == 3)
end)

test("Интеграция: после rebirth конвейер использует новый ClarityMultiplier", function()
	local t = setup()
	local second = secondBiome(t)
	t.Factory.Init()
	t.World.Players = { t.Player }

	t.Grind()
	t.Data.Rebirth.Count = second.RebirthThreshold - 1
	t.Data.Rebirth.ClarityMultiplier = t.Rebirth.ComputeProgress(t.Data.Rebirth.Count).ClarityMultiplier
	t.Perform()
	local multiplier = t.Data.Rebirth.ClarityMultiplier
	assert(multiplier > t.Start.ClarityMultiplier, "множитель вырос")

	local produced = {}
	t.Factory.OnEssenceProduced:Connect(function(_p, amount)
		table.insert(produced, amount)
	end)
	t.Data.Factory.RawFragments = 1
	t.World:Advance(10)

	local essencePerFragment = t.World:LoadModule("src/shared/Config/FactoryConfig").EssencePerFragment
	assert(#produced == 1, `циклов {#produced}`)
	assert(produced[1] == essencePerFragment * multiplier, `выход {produced[1]}, ожидалось {essencePerFragment * multiplier}`)
	assert(t.Data.Currency.Essence == t.Start.Essence + essencePerFragment * multiplier)
end)

return tests
