--[[
	Тесты PetSystem (раздел 5.3 ТЗ): честный ролл HatchCocoon по server-only PetRarityConfig,
	независимый ролл мутации, EquipPet/UnequipPet с лимитом слотов.

	Запуск: lune run src/tests/run (из корня репозитория).
]]

local Harness = require("./lib/Harness")

type Test = { Name: string, Run: () -> () }

local tests: { Test } = {}

local function test(name: string, run: () -> ())
	table.insert(tests, { Name = name, Run = run })
end

-- Детерминированный источник для статистических тестов (как серверный Random:NextNumber()).
local function seededSource(seed: number)
	math.randomseed(seed)
	return {
		NextNumber = function(_self)
			return math.random()
		end,
	}
end

-- PetSystem с подменёнными DataSystem (профили в памяти) и Remotes (перехват обработчиков).
local function setup()
	local world = Harness.NewWorld()
	local _, dataSystem = world:NewServer()
	local profiles = {}
	local handlers = {}
	local snapshots = {} -- { Player, Snapshot } в порядке FireClient

	local function remote(name: string)
		return {
			OnServerEvent = {
				Connect = function(_self, fn)
					handlers[name] = fn
				end,
			},
			FireClient = function(_self, target, snapshot)
				table.insert(snapshots, { Player = target, Snapshot = Harness.DeepCopy(snapshot) })
			end,
		}
	end

	local petSystem = world:LoadModule("src/server/Systems/PetSystem", {
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
			HatchCocoon = remote("HatchCocoon"),
			EquipPet = remote("EquipPet"),
			UnequipPet = remote("UnequipPet"),
			PetSnapshot = remote("PetSnapshot"),
		},
	})
	petSystem.Init()

	local function addPlayer(userId: number)
		local player = world:NewPlayer(userId)
		profiles[player] = dataSystem.BuildDefaultProfile()
		return player, profiles[player]
	end

	local player, data = addPlayer(42)

	-- Каждый вызов сдвигает время: тесты логики не должны упираться в rate limit.
	local function call(name: string, p, ...)
		world:Advance(0.5)
		handlers[name](p, ...)
	end

	return {
		World = world,
		Player = player,
		Data = data,
		Pets = petSystem,
		Snapshots = snapshots,
		Cocoons = world:LoadModule("src/shared/Config/CocoonConfig"),
		PetConfig = world:LoadModule("src/shared/Config/PetConfig"),
		Rarity = world:LoadModule("src/server/Config/PetRarityConfig"),
		AddPlayer = addPlayer,
		Call = call,
		-- Вызов обработчика без сдвига времени (для rate limit).
		Fire = function(name: string, p, ...)
			handlers[name](p, ...)
		end,
		Hatch = function(...)
			call("HatchCocoon", player, ...)
		end,
		Equip = function(...)
			call("EquipPet", player, ...)
		end,
		Unequip = function(...)
			call("UnequipPet", player, ...)
		end,
		LastSnapshot = function()
			return snapshots[#snapshots]
		end,
	}
end

local function countEquipped(pets): number
	local n = 0
	for _, pet in pets do
		if pet.Equipped then
			n += 1
		end
	end
	return n
end

-- Выдаёт игроку count петов через настоящий HatchCocoon.
local function hatchMany(t, count: number)
	t.Data.Currency.Essence += t.Cocoons.DrowsyCocoon.Price * count
	for _ = 1, count do
		t.Hatch("DrowsyCocoon")
	end
	assert(#t.Data.Pets >= count, "петы вылупились")
end

------------------------------------------------------------------------------------------
-- Конфиг
------------------------------------------------------------------------------------------

test("PetRarityConfig загружается: у каждого кокона из CocoonConfig есть шансы с суммой 1", function()
	local t = setup()
	for cocoonId in t.Cocoons do
		local odds = assert(t.Rarity.Cocoons[cocoonId], `шансы для {cocoonId}`)
		local sum = 0
		for _, entry in odds do
			sum += entry.Chance
		end
		assert(math.abs(sum - 1) < 1e-9, `сумма шансов {cocoonId} = {sum}`)
	end
	assert(t.Rarity.Mutation.Chance > 0 and t.Rarity.Mutation.Chance < 0.5, "у мутации своя низкая вероятность")
end)

------------------------------------------------------------------------------------------
-- Ролл
------------------------------------------------------------------------------------------

local TRIALS = 200_000

-- Допуск в 5 сигм биномиального распределения: ложный провал практически исключён.
local function assertFrequency(label: string, hits: number, trials: number, p: number)
	local freq = hits / trials
	local sigma = math.sqrt(p * (1 - p) / trials)
	assert(math.abs(freq - p) <= 5 * sigma, `{label}: частота {freq}, ожидалось {p} ± {5 * sigma}`)
end

test("Взвешенный ролл редкости статистически соответствует конфигу (каждый кокон)", function()
	local t = setup()
	for cocoonId, odds in t.Rarity.Cocoons do
		local source = seededSource(1234)
		local counts = {}
		for _ = 1, TRIALS do
			local roll = assert(t.Pets.RollPet(cocoonId, source))
			counts[roll.Rarity] = (counts[roll.Rarity] or 0) + 1
		end
		for _, entry in odds do
			assertFrequency(`{cocoonId}/{entry.Rarity}`, counts[entry.Rarity] or 0, TRIALS, entry.Chance)
			counts[entry.Rarity] = nil
		end
		assert(next(counts) == nil, `{cocoonId}: выпала редкость вне конфига`)
	end
end)

test("Вид пета берётся из списка выпавшей редкости", function()
	local t = setup()
	local source = seededSource(99)
	for _ = 1, 20_000 do
		local roll = assert(t.Pets.RollPet("LucidCocoon", source))
		local allowed = false
		for _, entry in t.Rarity.Cocoons.LucidCocoon do
			if entry.Rarity == roll.Rarity then
				allowed = table.find(entry.Species, roll.SpeciesId) ~= nil
			end
		end
		assert(allowed, `вид {roll.SpeciesId} не из редкости {roll.Rarity}`)
	end
end)

test("Мутация — независимый ролл: её частота одинакова для каждой редкости", function()
	local t = setup()
	local p = t.Rarity.Mutation.Chance
	local source = seededSource(777)
	local total, mutated = {}, {}
	local mutatedAll = 0
	for _ = 1, TRIALS do
		local roll = assert(t.Pets.RollPet("DrowsyCocoon", source))
		total[roll.Rarity] = (total[roll.Rarity] or 0) + 1
		if roll.Mutation then
			mutated[roll.Rarity] = (mutated[roll.Rarity] or 0) + 1
			mutatedAll += 1
		end
	end

	assertFrequency("мутация в целом", mutatedAll, TRIALS, p)
	for rarity, n in total do
		assertFrequency(`мутация при {rarity}`, mutated[rarity] or 0, n, p)
	end
end)

test("Мутация выпадает поверх любой редкости и не меняет её (заданный исход ролла)", function()
	local t = setup()
	-- Порядок бросков: редкость, вид, мутация, тип мутации.
	local function rollWith(values)
		local i = 0
		return t.Pets.RollPet("DrowsyCocoon", {
			NextNumber = function()
				i += 1
				return values[i]
			end,
		})
	end

	local legendaryMutated = assert(rollWith({ 0.999, 0, 0, 0 }))
	assert(legendaryMutated.Rarity == "Legendary" and legendaryMutated.Mutation == "Shiny")

	local commonMutated = assert(rollWith({ 0, 0, 0, 0.99 }))
	assert(commonMutated.Rarity == "Common" and commonMutated.Mutation == "Nightmare")

	local legendaryPlain = assert(rollWith({ 0.999, 0, 0.5, 0 }))
	assert(legendaryPlain.Rarity == "Legendary" and legendaryPlain.Mutation == nil, "мутация не выпала — редкость та же")
end)

test("Ролл неизвестного кокона — nil", function()
	local t = setup()
	assert(t.Pets.RollPet("NoSuchCocoon", seededSource(1)) == nil)
end)

------------------------------------------------------------------------------------------
-- HatchCocoon
------------------------------------------------------------------------------------------

test("HatchCocoon списывает цену из CocoonConfig и добавляет пета с уникальным Id", function()
	local t = setup()
	local price = t.Cocoons.DrowsyCocoon.Price
	t.Data.Currency.Essence = price * 2 + 5
	t.Hatch("DrowsyCocoon")
	t.Hatch("DrowsyCocoon")

	assert(t.Data.Currency.Essence == 5, "списано дважды по цене конфига")
	assert(#t.Data.Pets == 2)
	local a, b = t.Data.Pets[1], t.Data.Pets[2]
	assert(type(a.Id) == "string" and a.Id ~= b.Id, "Id уникальны")
	assert(a.Equipped == false and a.Level == 1, "новый пет не надет, уровень 1")

	local snap = t.LastSnapshot()
	assert(snap.Player == t.Player, "ответ владельцу")
	assert(snap.Snapshot.Ack == "HatchCocoon" and snap.Snapshot.HatchedPetId == b.Id)
	assert(#snap.Snapshot.Pets == 2)
end)

test("HatchCocoon отклоняется при нехватке Essence", function()
	local t = setup()
	t.Data.Currency.Essence = t.Cocoons.DrowsyCocoon.Price - 1
	t.Hatch("DrowsyCocoon")

	assert(#t.Data.Pets == 0, "пет не создан")
	assert(t.Data.Currency.Essence == t.Cocoons.DrowsyCocoon.Price - 1, "Essence не тронута")
	local snap = t.LastSnapshot().Snapshot
	assert(snap.Ack == "HatchCocoon" and snap.HatchedPetId == nil, "отказ подтверждён снимком")
	assert(snap.Pets == nil, "на отказ список петов не шлётся")
end)

test("HatchCocoon отклоняется при неизвестном или некорректном cocoonId", function()
	local t = setup()
	t.Data.Currency.Essence = 1_000_000
	for _, bad in { "NoSuchCocoon", 42, nil, { Id = "DrowsyCocoon" }, "__index" } do
		t.Hatch(bad)
	end
	assert(#t.Data.Pets == 0)
	assert(t.Data.Currency.Essence == 1_000_000)
end)

test("HatchCocoon с битой Essence (NaN) отклоняется и пишет в лог", function()
	local t = setup()
	t.Data.Currency.Essence = 0 / 0
	t.Hatch("DrowsyCocoon")
	assert(#t.Data.Pets == 0)
	assert(#t.World.Warnings == 1 and string.find(t.World.Warnings[1], "Essence"), "предупреждение о порче")
end)

test("HatchCocoon упирается в MaxInventory", function()
	local t = setup()
	for i = 1, t.PetConfig.MaxInventory do
		t.Data.Pets[i] = { Id = `p{i}`, SpeciesId = "DozySheep", Rarity = "Common", Level = 1, Equipped = false }
	end
	t.Data.Currency.Essence = 1_000_000
	t.Hatch("DrowsyCocoon")
	assert(#t.Data.Pets == t.PetConfig.MaxInventory)
	assert(t.Data.Currency.Essence == 1_000_000)
end)

test("Rate limit: залп HatchCocoon в один момент обрабатывается не больше лимита окна", function()
	local t = setup()
	t.Data.Currency.Essence = 1_000_000
	t.World:Advance(5)
	for _ = 1, 20 do
		t.Fire("HatchCocoon", t.Player, "DrowsyCocoon")
	end
	assert(#t.Data.Pets == t.PetConfig.MaxRequestsPerWindow, `вылуплено {#t.Data.Pets} за окно`)
	assert(#t.Snapshots == t.PetConfig.MaxRequestsPerWindow, "отброшенным запросам ответа нет")
end)

------------------------------------------------------------------------------------------
-- EquipPet / UnequipPet
------------------------------------------------------------------------------------------

test("EquipPet надевает своего пета, UnequipPet снимает", function()
	local t = setup()
	hatchMany(t, 1)
	local pet = t.Data.Pets[1]

	t.Equip(pet.Id)
	assert(pet.Equipped == true)
	assert(t.LastSnapshot().Snapshot.Ack == "EquipPet" and t.LastSnapshot().Snapshot.Pets[1].Equipped == true)

	t.Unequip(pet.Id)
	assert(pet.Equipped == false)
	assert(t.LastSnapshot().Snapshot.Ack == "UnequipPet")
end)

test("EquipPet чужого пета отклоняется, чужой профиль не меняется", function()
	local t = setup()
	local other, otherData = t.AddPlayer(7)
	otherData.Currency.Essence = t.Cocoons.DrowsyCocoon.Price
	t.Call("HatchCocoon", other, "DrowsyCocoon")
	local foreignPet = assert(otherData.Pets[1], "у другого игрока есть пет")

	t.Equip(foreignPet.Id)
	assert(foreignPet.Equipped == false, "чужой пет не надет")
	assert(#t.Data.Pets == 0, "своих петов не появилось")
	local snap = t.LastSnapshot()
	assert(snap.Player == t.Player and snap.Snapshot.Pets == nil, "отказ, чужие петы в ответ не попали")

	-- И снять чужого надетого пета тоже нельзя.
	t.Call("EquipPet", other, foreignPet.Id)
	assert(foreignPet.Equipped == true)
	t.Unequip(foreignPet.Id)
	assert(foreignPet.Equipped == true, "чужой пет не снят")
end)

test("EquipPet с некорректным аргументом отклоняется", function()
	local t = setup()
	hatchMany(t, 1)
	for _, bad in { 42, nil, "", string.rep("x", 1000), { t.Data.Pets[1].Id } } do
		t.Equip(bad)
	end
	assert(countEquipped(t.Data.Pets) == 0)
end)

test("Лимит слотов: без геймпасса не больше BaseEquipSlots активных", function()
	local t = setup()
	local base = t.PetConfig.BaseEquipSlots
	hatchMany(t, base + 2)
	for _, pet in t.Data.Pets do
		t.Equip(pet.Id)
	end
	assert(countEquipped(t.Data.Pets) == base, `надето {countEquipped(t.Data.Pets)}`)
	assert(t.LastSnapshot().Snapshot.EquipSlots == base)

	-- Освободили слот — можно надеть другого.
	local equipped, spare
	for _, pet in t.Data.Pets do
		if pet.Equipped and not equipped then
			equipped = pet
		elseif not pet.Equipped and not spare then
			spare = pet
		end
	end
	t.Unequip(equipped.Id)
	t.Equip(spare.Id)
	assert(spare.Equipped and countEquipped(t.Data.Pets) == base)
end)

test("Лимит слотов: геймпасс из GamePassesOwned добавляет ExtraEquipSlots", function()
	local t = setup()
	local slots = t.PetConfig.BaseEquipSlots + t.PetConfig.ExtraEquipSlots
	table.insert(t.Data.Monetization.GamePassesOwned, t.PetConfig.ExtraSlotsGamePassId)
	hatchMany(t, slots + 1)
	for _, pet in t.Data.Pets do
		t.Equip(pet.Id)
	end
	assert(countEquipped(t.Data.Pets) == slots, `надето {countEquipped(t.Data.Pets)}`)
	assert(t.LastSnapshot().Snapshot.EquipSlots == slots)
end)

test("Повторный EquipPet того же пета не занимает второй слот", function()
	local t = setup()
	hatchMany(t, 2)
	for _ = 1, t.PetConfig.BaseEquipSlots + 1 do
		t.Equip(t.Data.Pets[1].Id)
	end
	t.Equip(t.Data.Pets[2].Id)
	assert(countEquipped(t.Data.Pets) == 2)
end)

test("Битый раздел Pets не роняет обработчики", function()
	local t = setup()
	t.Data.Pets = "broken" :: any
	t.Data.Currency.Essence = 1_000_000
	t.Hatch("DrowsyCocoon")
	t.Equip("some-id")
	assert(t.Data.Currency.Essence == 1_000_000, "Essence не списана")
	assert(t.LastSnapshot().Snapshot.Ack == "EquipPet", "ответ всё равно отправлен")
end)

test("Битый раздел Currency: HatchCocoon не падает, отвечает и пишет в лог один раз", function()
	local t = setup()
	t.Data.Currency = 5 :: any
	t.Hatch("DrowsyCocoon")
	t.Hatch("DrowsyCocoon")
	assert(#t.Data.Pets == 0)
	assert(#t.Snapshots == 2 and t.LastSnapshot().Snapshot.Ack == "HatchCocoon")
	assert(#t.World.Warnings == 1, `предупреждений {#t.World.Warnings}`)
end)

test("Pets с дырами считается порчей: MaxInventory не обходится", function()
	local t = setup()
	t.Data.Pets = { [1] = { Id = "a", Equipped = false }, [500] = { Id = "b", Equipped = false } } :: any
	t.Data.Currency.Essence = 1_000_000
	t.Hatch("DrowsyCocoon")
	assert(t.Data.Currency.Essence == 1_000_000, "Essence не списана")
end)

return tests
