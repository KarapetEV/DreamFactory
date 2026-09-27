--[[
	Тесты авто-сборщика (геймпасс + пассивный сбор в CollectionSystem): владение только через
	Monetization.GamePassesOwned, радиус = getCollectRadius (апгрейд × Nostalgic-петы),
	общая с RequestCollect транзакция (без двойного засчёта фрагмента), изоляция битых профилей,
	миграция v3 → v4 (удаление Collection.AutoCollectorOwned) и load-time проверки конфига.

	Запуск: lune run src/tests/run (из корня репозитория).
]]

local Harness = require("./lib/Harness")

type Test = { Name: string, Run: () -> () }

local tests: { Test } = {}

local function test(name: string, run: () -> ())
	table.insert(tests, { Name = name, Run = run })
end

-- Сумма буфера сырых фрагментов по эмоциям (Factory.RawFragments).
local function rawTotal(data): number
	local total = 0
	for _, value in data.Factory.RawFragments do
		total += value
	end
	return total
end

-- PetSystem + CollectionSystem в одном «сервере»: подменённый DataSystem (профили в памяти),
-- перехват обработчиков ремоут. Игроки — через AddPlayer; CollectionSystem.Init вызывает тест.
local function setup()
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
	for _, name in { "HatchCocoon", "EquipPet", "UnequipPet", "PetSnapshot", "RequestCollect" } do
		fakeRemotes[name] = remote(name)
	end

	local overrides = {
		["src/server/Systems/DataSystem"] = fakeData,
		["src/shared/Remotes"] = fakeRemotes,
	}
	local petSystem = world:LoadModule("src/server/Systems/PetSystem", overrides)
	overrides["src/server/Systems/PetSystem"] = petSystem
	local collection = world:LoadModule("src/server/Systems/CollectionSystem", overrides)
	petSystem.Init()

	local autoConfig = world:LoadModule("src/shared/Config/AutoCollectorConfig")

	local t = {
		World = world,
		DataSystem = dataSystem,
		Pets = petSystem,
		Collection = collection,
		Handlers = handlers,
		AutoConfig = autoConfig,
		Species = world:LoadModule("src/shared/Config/PetSpeciesConfig"),
		Effects = world:LoadModule("src/shared/UpgradeEffects"),
		CollectionConfig = world:LoadModule("src/shared/Config/CollectionConfig"),
	}

	-- Новый игрок с дефолтным профилем; ownsPass — выдать геймпасс авто-сборщика.
	function t.AddPlayer(userId: number, ownsPass: boolean?)
		local player = world:NewPlayer(userId)
		local data = dataSystem.BuildDefaultProfile()
		if ownsPass then
			table.insert(data.Monetization.GamePassesOwned, autoConfig.GamePassId)
		end
		profiles[player] = data
		table.insert(world.Players, player)
		return player, data
	end

	-- Одна итерация тика авто-сборщика (плюс запас, чтобы тик точно отработал).
	function t.Tick(count: number?)
		world:Advance(autoConfig.TickInterval * (count or 1) + 0.01)
	end

	return t
end

-- Персонаж игрока на сервере с корнем в position.
local function placeCharacter(player, position)
	local root = {
		Position = position,
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
end

-- Ставит персонажа над фрагментом на высоте distance. Точки спавна зоны разнесены
-- по горизонтали минимум на 18 studs, поэтому до соседних фрагментов заметно дальше.
local function placeAbove(player, fragment, distance: number)
	-- Vector3 доступен только модулям мира; нулевой вектор того же типа — разностью.
	local offset = fragment.Position - fragment.Position
	offset.Y = distance
	placeCharacter(player, fragment.Position + offset)
end

local function liveFragments(t)
	local list = {}
	for _, instance in t.World.Instances do
		if instance.ClassName == "Part" and instance:GetAttribute("FragmentId") and not instance.Destroyed then
			table.insert(list, instance)
		end
	end
	return list
end

local function firstFragment(t)
	local fragments = liveFragments(t)
	assert(#fragments >= 1, "фрагменты заспавнены")
	return fragments[1]
end

local function bonusOf(t, speciesId: string, rarity: string): number
	return t.Species.Species[speciesId].BonusPerRarity[rarity]
end

------------------------------------------------------------------------------------------
-- Конфиг и профиль
------------------------------------------------------------------------------------------

test("Геймпасс авто-сборщика описан в MonetizationConfig (ShopUI покажет его сам)", function()
	local t = setup()
	local config = t.World:LoadModule("src/shared/Config/MonetizationConfig")
	local found = nil
	for _, pass in config.GamePasses do
		if pass.Id == t.AutoConfig.GamePassId then
			found = pass
		end
	end
	assert(found, "запись есть")
	assert(found.GamePassId == 0, "id — заглушка до публикации")
	assert(t.AutoConfig.TickInterval > 0, "интервал тика положителен")
end)

test("AutoCollectorConfig не грузится, если его геймпасса нет в MonetizationConfig", function()
	local world = Harness.NewWorld()
	local real = world:LoadModule("src/shared/Config/MonetizationConfig")
	local broken = table.clone(real)
	broken.GamePasses = { real.GamePasses[1] }
	local ok, err = pcall(function()
		world:LoadModule("src/shared/Config/AutoCollectorConfig", { ["src/shared/Config/MonetizationConfig"] = broken })
	end)
	assert(not ok and string.find(tostring(err), "AutoCollector"), `ожидалась ошибка про AutoCollector, получено {err}`)
end)

test("Новый профиль без Collection.AutoCollectorOwned; миграция v3 → v4 удаляет поле", function()
	local t = setup()
	local fresh = t.DataSystem.BuildDefaultProfile()
	assert(fresh.Collection.AutoCollectorOwned == nil, "поля нет в новом профиле")

	local v3 = {
		Meta = { SchemaVersion = 3 },
		Collection = { RadiusLevel = 2, SpeedLevel = 1, AutoCollectorOwned = false },
		Monetization = { GamePassesOwned = { "ExtraPetSlots" }, BattlePassTier = 0 },
	}
	local migrated = assert(t.DataSystem.MigrateProfileData(v3), "миграция прошла")
	assert(migrated.Meta.SchemaVersion == t.DataSystem.CURRENT_SCHEMA_VERSION, "доведено до текущей версии")
	assert(migrated.Collection.AutoCollectorOwned == nil, "старое поле удалено")
	assert(migrated.Collection.RadiusLevel == 2 and migrated.Collection.SpeedLevel == 1, "уровни сохранены")
	assert(migrated.Monetization.GamePassesOwned[1] == "ExtraPetSlots", "владение не тронуто")
end)

------------------------------------------------------------------------------------------
-- Пассивный сбор
------------------------------------------------------------------------------------------

test("Без геймпасса пассивного сбора нет", function()
	local t = setup()
	local player, data = t.AddPlayer(1, false)
	t.Collection.Init()
	local fragment = firstFragment(t)
	placeAbove(player, fragment, 0)

	t.Tick(5)
	assert(rawTotal(data) == 0, "ничего не собрано")
	assert(not fragment.Destroyed, "фрагмент на месте")
end)

test("С геймпассом фрагмент в радиусе собирается без RequestCollect от клиента", function()
	local t = setup()
	local player, data = t.AddPlayer(1, true)
	t.Collection.Init()
	local fragment = firstFragment(t)
	placeAbove(player, fragment, 5)

	local fired = false
	local original = t.Handlers.RequestCollect
	t.Handlers.RequestCollect = function(...)
		fired = true
		return original(...)
	end

	t.Tick()
	assert(not fired, "клиентский путь не участвовал")
	assert(rawTotal(data) == t.CollectionConfig.FragmentValue, `собрано {rawTotal(data)}`)
	assert(fragment.Destroyed, "фрагмент убран из мира")
end)

test("За тик собирается не больше одного фрагмента, берётся ближайший", function()
	local t = setup()
	local player, data = t.AddPlayer(1, true)
	data.Collection.RadiusLevel = 5 -- радиус 22: дотягивается до нескольких точек спавна
	t.Collection.Init()
	t.World:Advance(t.CollectionConfig.SpawnInterval * 3) -- до тика: докинуть фрагментов в зону
	data.Factory.RawFragments = { Joyful = 0, Nostalgic = 0, Fearful = 0 }
	local fragments = liveFragments(t)
	assert(#fragments >= 2, `фрагментов {#fragments}`)
	local target = fragments[1]
	placeAbove(player, target, 1)

	t.Tick()
	assert(rawTotal(data) == t.CollectionConfig.FragmentValue, `за тик собрано {rawTotal(data)}`)
	assert(target.Destroyed, "собран ближайший")
end)

test("Фрагмент за пределами радиуса не собирается", function()
	local t = setup()
	local player, data = t.AddPlayer(1, true)
	t.Collection.Init()
	local fragment = firstFragment(t)
	local radius = t.Effects.GetEffectValue("CollectionRadius", 0)
	placeAbove(player, fragment, radius + t.CollectionConfig.DistanceTolerance + 1)

	t.Tick(5)
	assert(rawTotal(data) == 0, "далеко — не собрано")
	assert(not fragment.Destroyed)
end)

test("Радиус пассивного сбора растёт от апгрейда CollectionRadius", function()
	local t = setup()
	local player, data = t.AddPlayer(1, true)
	t.Collection.Init()
	local fragment = firstFragment(t)
	local base = t.Effects.GetEffectValue("CollectionRadius", 0)
	local upgraded = t.Effects.GetEffectValue("CollectionRadius", 1)
	assert(upgraded > base)
	placeAbove(player, fragment, (base + upgraded) / 2)

	t.Tick(3)
	assert(rawTotal(data) == 0, "на уровне 0 не дотягивается")

	data.Collection.RadiusLevel = 1
	t.Tick()
	assert(rawTotal(data) == t.CollectionConfig.FragmentValue, "после апгрейда собран")
	assert(fragment.Destroyed)
end)

test("Радиус пассивного сбора растёт от Nostalgic-пета", function()
	local t = setup()
	local player, data = t.AddPlayer(1, true)
	t.Collection.Init()
	local fragment = firstFragment(t)
	local base = t.Effects.GetEffectValue("CollectionRadius", 0)
	local multiplier = 1 + bonusOf(t, "PillowMoth", "Legendary")
	placeAbove(player, fragment, base * (1 + multiplier) / 2)

	t.Tick(3)
	assert(rawTotal(data) == 0, "без пета не дотягивается")

	local pet = { Id = "pet-1", SpeciesId = "PillowMoth", Rarity = "Legendary", Level = 1, Equipped = false }
	table.insert(data.Pets, pet)
	t.Handlers.EquipPet(player, pet.Id)
	t.Tick()
	assert(rawTotal(data) == t.CollectionConfig.FragmentValue, "с Nostalgic-петом собран")
	assert(fragment.Destroyed)
end)

------------------------------------------------------------------------------------------
-- Гонка с ручным сбором
------------------------------------------------------------------------------------------

test("Гонка: ручной сбор забрал фрагмент — тик его второй раз не засчитывает", function()
	local t = setup()
	local owner, ownerData = t.AddPlayer(1, true)
	local other, otherData = t.AddPlayer(2, false)
	t.Collection.Init()
	local fragment = firstFragment(t)
	placeAbove(owner, fragment, 1)
	placeAbove(other, fragment, 1)

	-- Ручной сбор в тот же виртуальный момент, что и ближайший тик.
	t.World:Advance(t.AutoConfig.TickInterval - 0.001)
	t.Handlers.RequestCollect(other, fragment:GetAttribute("FragmentId"))
	t.World:Advance(0.01) -- ровно один тик (следующий совпал бы с респавном в той же точке)

	assert(rawTotal(otherData) == t.CollectionConfig.FragmentValue, "забрал ручной сбор")
	assert(rawTotal(ownerData) == 0, "тик не засчитал уже собранный фрагмент")
end)

test("Гонка: тик забрал фрагмент — ручной RequestCollect того же id отклоняется", function()
	local t = setup()
	local owner, ownerData = t.AddPlayer(1, true)
	t.Collection.Init()
	local fragment = firstFragment(t)
	local id = fragment:GetAttribute("FragmentId")
	placeAbove(owner, fragment, 1)

	t.Tick()
	assert(rawTotal(ownerData) == t.CollectionConfig.FragmentValue, "тик собрал")
	t.World:Advance(1) -- кулдаун истёк: отказ только из-за того, что фрагмента уже нет
	t.Handlers.RequestCollect(owner, id)
	assert(rawTotal(ownerData) == t.CollectionConfig.FragmentValue, "второй раз не засчитан")
end)

test("Кулдаун общий: сразу после ручного сбора тик не собирает", function()
	local t = setup()
	local owner, data = t.AddPlayer(1, true)
	data.Collection.RadiusLevel = 5
	t.Collection.Init()
	t.World:Advance(t.CollectionConfig.SpawnInterval * 2)
	local fragments = liveFragments(t)
	assert(#fragments >= 2, `фрагментов {#fragments}`)
	placeAbove(owner, fragments[1], 1)

	-- Время кратно TickInterval + 0.01 не совпадает: доводим до момента прямо перед тиком.
	local interval = t.AutoConfig.TickInterval
	local nextTick = (math.floor(t.World.Now / interval) + 1) * interval
	t.World:Advance(nextTick - t.World.Now - 0.001)
	t.Handlers.RequestCollect(owner, fragments[1]:GetAttribute("FragmentId"))
	assert(rawTotal(data) == t.CollectionConfig.FragmentValue, "ручной сбор прошёл")

	t.World:Advance(0.01) -- тик внутри кулдауна ручного сбора
	assert(rawTotal(data) == t.CollectionConfig.FragmentValue, "тик упёрся в общий кулдаун")
end)

------------------------------------------------------------------------------------------
-- Изоляция битых профилей
------------------------------------------------------------------------------------------

test("Битый профиль/Monetization одного игрока не валит тик для остальных", function()
	local t = setup()
	local noMonetization, d1 = t.AddPlayer(1, false)
	;(d1 :: any).Monetization = 5
	local junkList, d2 = t.AddPlayer(2, false)
	;(d2 :: any).Monetization.GamePassesOwned = "AutoCollector"
	local brokenCollection, d3 = t.AddPlayer(3, true)
	;(d3 :: any).Collection = 5 -- getCollectRadius бросит ошибку
	local healthy, d4 = t.AddPlayer(4, true)
	t.Collection.Init()

	local fragment = firstFragment(t)
	for _, player in { noMonetization, junkList, brokenCollection } do
		placeAbove(player, fragment, 0)
	end
	placeAbove(healthy, fragment, 1)

	t.Tick()
	assert(rawTotal(d4) == t.CollectionConfig.FragmentValue, "здоровый игрок собрал")
	assert(fragment.Destroyed)
	assert(rawTotal(d1) == 0 and rawTotal(d2) == 0, "битая монетизация = нет геймпасса")

	t.Tick(2) -- ещё тики: цикл жив, лог не спамится

	local errors = 0
	for _, message in t.World.Warnings do
		if string.find(message, "авто-сборщика у", 1, true) then
			errors += 1
		end
	end
	assert(errors == 1, `ошибка битого профиля записана один раз, записей {errors}`)
end)

return tests
