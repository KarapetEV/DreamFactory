--[[
	Тесты бонусов петов (S8, раздел 5.3 ТЗ): PetSpeciesConfig, агрегация по эмоциям,
	мутация, кэш (пересчёт только при Equip/Unequip/загрузке), fallback на 1.0 и
	интеграция с FactorySystem (конвейер) и CollectionSystem (радиус сбора).

	Запуск: lune run src/tests/run (из корня репозитория).
]]

local Harness = require("./lib/Harness")

type Test = { Name: string, Run: () -> () }

local tests: { Test } = {}

local function test(name: string, run: () -> ())
	table.insert(tests, { Name = name, Run = run })
end

local EPS = 1e-9

local function near(a: number, b: number): boolean
	return math.abs(a - b) < EPS
end

-- PetSystem + FactorySystem + CollectionSystem в одном «сервере»: общий подменённый
-- DataSystem (профили в памяти), общий PetSystem (кэш бонусов), перехват обработчиков ремоут.
-- skipPetInit — не вызывать PetSystem.Init (тест загрузки кэша вызывает его сам).
local function setup(skipPetInit: boolean?)
	local world = Harness.NewWorld()
	local _, dataSystem = world:NewServer()
	local profiles = {}
	local handlers = {}

	local function remote(name: string)
		return {
			OnServerEvent = {
				Connect = function(_self, fn)
					handlers[name] = fn
				end,
			},
			FireClient = function() end,
		}
	end

	local fakeData = {
		GetData = function(p)
			return profiles[p]
		end,
		WaitForData = function(p)
			return profiles[p]
		end,
		BuildDefaultProfile = dataSystem.BuildDefaultProfile,
	}
	local fakeRemotes = {}
	for _, name in {
		"HatchCocoon",
		"EquipPet",
		"UnequipPet",
		"PetSnapshot",
		"PurchaseUpgrade",
		"EconomySnapshot",
		"RequestCollect",
	} do
		fakeRemotes[name] = remote(name)
	end

	local overrides = {
		["src/server/Systems/DataSystem"] = fakeData,
		["src/shared/Remotes"] = fakeRemotes,
	}
	local petSystem = world:LoadModule("src/server/Systems/PetSystem", overrides)
	overrides["src/server/Systems/PetSystem"] = petSystem
	local factory = world:LoadModule("src/server/Systems/FactorySystem", overrides)
	local collection = world:LoadModule("src/server/Systems/CollectionSystem", overrides)

	local player = world:NewPlayer(42)
	local data = dataSystem.BuildDefaultProfile()
	profiles[player] = data
	if not skipPetInit then
		petSystem.Init() -- до world.Players: кэш при загрузке строит только отдельный тест
	end
	world.Players = { player }

	local nextPetId = 0
	local function addPet(speciesId: string, rarity: string, mutation: string?, equipped: boolean?)
		nextPetId += 1
		local pet = {
			Id = `pet-{nextPetId}`,
			SpeciesId = speciesId,
			Rarity = rarity,
			Mutation = mutation,
			Level = 1,
			Equipped = equipped == true,
		}
		table.insert(data.Pets, pet)
		return pet
	end

	local function call(name: string, ...)
		world:Advance(0.5)
		handlers[name](player, ...)
	end

	return {
		World = world,
		Player = player,
		Data = data,
		Pets = petSystem,
		Factory = factory,
		Collection = collection,
		Species = world:LoadModule("src/shared/Config/PetSpeciesConfig"),
		Effects = world:LoadModule("src/shared/UpgradeEffects"),
		CollectionConfig = world:LoadModule("src/shared/Config/CollectionConfig"),
		AddPet = addPet,
		Call = call,
		Equip = function(pet)
			call("EquipPet", pet.Id)
		end,
		Unequip = function(pet)
			call("UnequipPet", pet.Id)
		end,
		-- Считает вызовы GetAggregatedBonuses (PetSystem зовёт её через таблицу модуля).
		SpyAggregation = function(replacement: ((data: any) -> any)?)
			local original = petSystem.GetAggregatedBonuses
			local spy = { Calls = 0 }
			petSystem.GetAggregatedBonuses = function(d)
				spy.Calls += 1
				if replacement then
					return replacement(d)
				end
				return original(d)
			end
			return spy
		end,
	}
end

local function bonusOf(t, speciesId: string, rarity: string): number
	return t.Species.Species[speciesId].BonusPerRarity[rarity]
end

------------------------------------------------------------------------------------------
-- PetSpeciesConfig
------------------------------------------------------------------------------------------

test("PetSpeciesConfig грузится и покрывает все виды и редкости из PetRarityConfig", function()
	local t = setup()
	local rarity = t.World:LoadModule("src/server/Config/PetRarityConfig")
	for cocoonId, odds in rarity.Cocoons do
		for _, entry in odds do
			for _, speciesId in entry.Species do
				local species = assert(t.Species.Species[speciesId], `вид {speciesId} ({cocoonId}) описан`)
				assert(species.BonusPerRarity[entry.Rarity], `у {speciesId} есть бонус для {entry.Rarity}`)
			end
		end
	end
	for id, species in t.Species.Species do
		assert(table.find({ "Joyful", "Nostalgic", "Fearful" }, species.EmotionType), `эмоция {id}`)
	end
end)

test("PetRarityConfig не грузится, если вид из таблицы шансов не описан в PetSpeciesConfig", function()
	local world = Harness.NewWorld()
	local real = world:LoadModule("src/shared/Config/PetSpeciesConfig")
	local broken = table.clone(real)
	broken.Species = table.clone(real.Species)
	broken.Species.MoonOwl = nil
	local ok, err = pcall(function()
		world:LoadModule("src/server/Config/PetRarityConfig", { ["src/shared/Config/PetSpeciesConfig"] = broken })
	end)
	assert(not ok and string.find(tostring(err), "MoonOwl"), `ожидалась ошибка про MoonOwl, получено {err}`)
end)

------------------------------------------------------------------------------------------
-- Агрегация (чистая функция)
------------------------------------------------------------------------------------------

test("Joyful влияет только на скорость конвейера", function()
	local t = setup()
	t.AddPet("DozySheep", "Rare", nil, true)
	local b = t.Pets.GetAggregatedBonuses(t.Data)
	assert(near(b.ConveyorSpeedMultiplier, 1 + bonusOf(t, "DozySheep", "Rare")), `скорость {b.ConveyorSpeedMultiplier}`)
	assert(b.CollectionRadiusMultiplier == 1, "радиус не тронут")
end)

test("Nostalgic влияет только на радиус сбора", function()
	local t = setup()
	t.AddPet("PillowMoth", "Epic", nil, true)
	local b = t.Pets.GetAggregatedBonuses(t.Data)
	assert(b.ConveyorSpeedMultiplier == 1, "скорость не тронута")
	assert(near(b.CollectionRadiusMultiplier, 1 + bonusOf(t, "PillowMoth", "Epic")))
end)

test("Fearful учитывается в слотах, но не влияет ни на один множитель", function()
	local t = setup()
	t.AddPet("CloudFox", "Legendary", "Shiny", true)
	local b = t.Pets.GetAggregatedBonuses(t.Data)
	assert(b.ConveyorSpeedMultiplier == 1 and b.CollectionRadiusMultiplier == 1)

	-- Fearful занимает слот: при 3 слотах и 3 надетых Fearful Joyful сверх лимита бонуса не даёт.
	t.AddPet("CloudFox", "Common", nil, true)
	t.AddPet("CloudFox", "Common", nil, true)
	t.AddPet("DozySheep", "Legendary", nil, true)
	assert(t.Pets.GetAggregatedBonuses(t.Data).ConveyorSpeedMultiplier == 1)
end)

test("Считаются только надетые петы, бонусы одной эмоции складываются", function()
	local t = setup()
	t.AddPet("DozySheep", "Common", nil, true)
	t.AddPet("StarJelly", "Rare", nil, true)
	t.AddPet("MoonOwl", "Legendary", nil, false) -- в инвентаре, не надет
	local b = t.Pets.GetAggregatedBonuses(t.Data)
	local expected = 1 + bonusOf(t, "DozySheep", "Common") + bonusOf(t, "StarJelly", "Rare")
	assert(near(b.ConveyorSpeedMultiplier, expected), `скорость {b.ConveyorSpeedMultiplier}, ожидалось {expected}`)
end)

test("Мутация добавляет небольшой доп. бонус к своему пету", function()
	local t = setup()
	local plain = t.AddPet("DozySheep", "Rare", nil, true)
	local base = t.Pets.GetAggregatedBonuses(t.Data).ConveyorSpeedMultiplier
	plain.Mutation = "Shiny"
	local mutated = t.Pets.GetAggregatedBonuses(t.Data).ConveyorSpeedMultiplier

	local bonus = bonusOf(t, "DozySheep", "Rare")
	assert(near(mutated, 1 + bonus * (1 + t.Species.MutationBonusFraction)), `с мутацией {mutated}`)
	assert(mutated > base and mutated - base < bonus, "прибавка есть, но меньше самого бонуса")
end)

test("Надетых сверх GetEquipSlots бонус не даёт (например, после отзыва геймпасса)", function()
	local t = setup()
	for _ = 1, 5 do
		t.AddPet("DozySheep", "Common", nil, true)
	end
	local slots = t.Pets.GetEquipSlots(t.Data)
	local b = t.Pets.GetAggregatedBonuses(t.Data)
	assert(near(b.ConveyorSpeedMultiplier, 1 + slots * bonusOf(t, "DozySheep", "Common")), "учтены только слоты")
end)

test("Множитель зажат MaxMultiplier; неизвестный вид и битые записи бонуса не дают", function()
	local t = setup()
	table.insert(t.Data.Monetization.GamePassesOwned, "ExtraPetSlots")
	for _ = 1, 6 do
		t.AddPet("DozySheep", "Secret", "Shiny", true)
	end
	assert(t.Pets.GetAggregatedBonuses(t.Data).ConveyorSpeedMultiplier == t.Species.MaxMultiplier)

	local t2 = setup()
	t2.AddPet("NoSuchSpecies", "Rare", nil, true)
	t2.AddPet("PillowMoth", "NoSuchRarity", nil, true)
	table.insert(t2.Data.Pets, "garbage" :: any)
	local b = t2.Pets.GetAggregatedBonuses(t2.Data)
	assert(b.ConveyorSpeedMultiplier == 1 and b.CollectionRadiusMultiplier == 1)
end)

------------------------------------------------------------------------------------------
-- Кэш
------------------------------------------------------------------------------------------

test("Кэш пересчитывается при Equip и Unequip", function()
	local t = setup()
	local pet = t.AddPet("DozySheep", "Legendary")
	local spy = t.SpyAggregation()

	t.Equip(pet)
	assert(spy.Calls == 1, `после Equip вызовов {spy.Calls}`)
	assert(near(t.Pets.GetCachedBonuses(t.Player).ConveyorSpeedMultiplier, 1 + bonusOf(t, "DozySheep", "Legendary")))

	t.Unequip(pet)
	assert(spy.Calls == 2, `после Unequip вызовов {spy.Calls}`)
	assert(t.Pets.GetCachedBonuses(t.Player).ConveyorSpeedMultiplier == 1)

	-- Отклонённый запрос (повторный Unequip) кэш не трогает.
	t.Unequip(pet)
	assert(spy.Calls == 2, "отказ не пересчитывает")
end)

test("Кэш не пересчитывается на тиках конвейера и запросах сбора", function()
	local t = setup()
	t.Factory.Init()
	t.Collection.Init()
	local pet = t.AddPet("DozySheep", "Legendary")
	t.Equip(pet)

	local spy = t.SpyAggregation()
	t.Data.Factory.RawFragments = 100
	t.World:Advance(30)
	for id = 1, 5 do
		t.Call("RequestCollect", id)
	end
	assert(spy.Calls == 0, `пересчётов на тиках: {spy.Calls}`)
	assert(t.Data.Factory.RawFragments < 100, "конвейер при этом работал")
end)

test("Кэш строится при загрузке профиля (Init с уже вошедшим игроком)", function()
	local t = setup(true)
	t.AddPet("PillowMoth", "Rare", nil, true)
	assert(t.Pets.GetCachedBonuses(t.Player).CollectionRadiusMultiplier == 1, "до загрузки кэша нет")
	t.Pets.Init()
	assert(near(t.Pets.GetCachedBonuses(t.Player).CollectionRadiusMultiplier, 1 + bonusOf(t, "PillowMoth", "Rare")))
end)

test("Нет кэша — множители 1.0 без ошибки", function()
	local t = setup()
	local stranger = t.World:NewPlayer(999)
	local b = t.Pets.GetCachedBonuses(stranger)
	assert(b.ConveyorSpeedMultiplier == 1 and b.CollectionRadiusMultiplier == 1)
end)

test("Битый результат или ошибка расчёта — кэш сброшен, 1.0, одно предупреждение", function()
	local t = setup()
	local pet = t.AddPet("DozySheep", "Legendary")

	t.SpyAggregation(function()
		return { ConveyorSpeedMultiplier = 0 / 0, CollectionRadiusMultiplier = "x" }
	end)
	t.Equip(pet)
	assert(pet.Equipped == true, "сама экипировка прошла")
	local b = t.Pets.GetCachedBonuses(t.Player)
	assert(b.ConveyorSpeedMultiplier == 1 and b.CollectionRadiusMultiplier == 1)

	t.SpyAggregation(function()
		error("boom")
	end)
	t.Unequip(pet)
	assert(pet.Equipped == false)
	b = t.Pets.GetCachedBonuses(t.Player)
	assert(b.ConveyorSpeedMultiplier == 1 and b.CollectionRadiusMultiplier == 1)
	assert(#t.World.Warnings == 1, `предупреждений {#t.World.Warnings}`)
end)

test("Возвращаемый GetCachedBonuses — копия: потребитель не портит кэш", function()
	local t = setup()
	local pet = t.AddPet("DozySheep", "Rare")
	t.Equip(pet)
	local b = t.Pets.GetCachedBonuses(t.Player)
	b.ConveyorSpeedMultiplier = 1000
	assert(near(t.Pets.GetCachedBonuses(t.Player).ConveyorSpeedMultiplier, 1 + bonusOf(t, "DozySheep", "Rare")))
end)

------------------------------------------------------------------------------------------
-- Интеграция
------------------------------------------------------------------------------------------

-- Циклов конвейера за duration секунд при полном буфере.
local function countCycles(t, duration: number): number
	local cycles = 0
	local connection = t.Factory.OnEssenceProduced:Connect(function()
		cycles += 1
	end)
	t.Data.Factory.RawFragments = 10_000
	t.World:Advance(duration)
	if connection and connection.Disconnect then
		connection:Disconnect()
	end
	return cycles
end

test("Интеграция: Joyful-пет реально ускоряет конвейер, Nostalgic — нет", function()
	local t = setup()
	t.Factory.Init()
	local baseDelay = t.Effects.GetEffectValue("ConveyorSpeed", 0)
	local duration = 100

	local base = countCycles(t, duration)
	assert(math.abs(base - duration / baseDelay) <= 1, `без петов циклов {base}`)

	local nostalgic = t.AddPet("PillowMoth", "Legendary")
	t.Equip(nostalgic)
	local withNostalgic = countCycles(t, duration)
	assert(math.abs(withNostalgic - base) <= 1, `Nostalgic изменил конвейер: {withNostalgic} против {base}`)
	t.Unequip(nostalgic)

	local joyful = t.AddPet("DozySheep", "Legendary")
	t.Equip(joyful)
	local multiplier = 1 + bonusOf(t, "DozySheep", "Legendary")
	local withJoyful = countCycles(t, duration)
	local expected = duration * multiplier / baseDelay
	assert(math.abs(withJoyful - expected) <= 2, `с Joyful циклов {withJoyful}, ожидалось ≈{expected}`)

	t.Unequip(joyful)
	local after = countCycles(t, duration)
	assert(math.abs(after - base) <= 1, `после Unequip циклов {after}`)
end)

-- Персонаж игрока на сервере с корнем в position.
local function placeCharacter(t, position)
	local root = {
		Position = position,
		IsA = function(_self, name)
			return name == "BasePart"
		end,
	}
	local humanoid = { Health = 100 }
	t.Player.Character = {
		FindFirstChildOfClass = function(_self, className)
			return if className == "Humanoid" then humanoid else nil
		end,
		FindFirstChild = function(_self, name)
			return if name == "HumanoidRootPart" then root else nil
		end,
	}
end

local function spawnedFragments(t)
	local list = {}
	for _, instance in t.World.Instances do
		if instance.ClassName == "Part" and instance:GetAttribute("FragmentId") and not instance.Destroyed then
			table.insert(list, instance)
		end
	end
	return list
end

test("Интеграция: Nostalgic-пет реально увеличивает радиус сбора в RequestCollect", function()
	local t = setup()
	t.Collection.Init()
	local fragments = spawnedFragments(t)
	assert(#fragments >= 2, `фрагментов заспавнено {#fragments}`)

	local baseRadius = t.Effects.GetEffectValue("CollectionRadius", 0)
	local tolerance = t.CollectionConfig.DistanceTolerance
	local multiplier = 1 + bonusOf(t, "PillowMoth", "Legendary")
	-- Дистанция за базовым радиусом, но внутри радиуса с бонусом.
	local distance = baseRadius + tolerance + baseRadius * (multiplier - 1) / 2
	local function collectFrom(fragment)
		-- Vector3 доступен только модулям мира; нулевой вектор того же типа — разностью.
		local offset = fragment.Position - fragment.Position
		offset.X = distance
		placeCharacter(t, fragment.Position + offset)
		t.World:Advance(5) -- кулдаун сбора и rate limit не мешают
		t.Call("RequestCollect", fragment:GetAttribute("FragmentId"))
	end

	collectFrom(fragments[1])
	assert(t.Data.Factory.RawFragments == 0, "без пета — слишком далеко")

	local pet = t.AddPet("PillowMoth", "Legendary")
	t.Equip(pet)
	collectFrom(fragments[1])
	assert(t.Data.Factory.RawFragments == t.CollectionConfig.FragmentValue, "с Nostalgic-петом фрагмент собран")
	assert(fragments[1].Destroyed, "фрагмент убран из мира")

	-- Joyful радиус не увеличивает.
	t.Unequip(pet)
	t.Equip(t.AddPet("DozySheep", "Legendary"))
	collectFrom(fragments[2])
	assert(t.Data.Factory.RawFragments == t.CollectionConfig.FragmentValue, "Joyful не помог дотянуться")
end)

return tests
