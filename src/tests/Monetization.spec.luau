--[[
	Тесты MonetizationSystem (S10, раздел 5.7 ТЗ): владение геймпассом из Roblox API кэшируется
	в профиль, сбои API не затирают кэш, покупка посреди сессии обновляет слоты петов,
	снимок экономики собирается при битом разделе Monetization.

	MarketplaceService в мире теста — заглушка Harness (world.GamePassOwnership).
	Запуск: lune run src/tests/run (из корня репозитория).
]]

local Harness = require("./lib/Harness")

type Test = { Name: string, Run: () -> () }

local tests: { Test } = {}

local function test(name: string, run: () -> ())
	table.insert(tests, { Name = name, Run = run })
end

local PASS_ID = "ExtraPetSlots"
local GAME_PASS_ID = 424242

-- Реальный конфиг держит GamePassId = 0 (заглушка); тестовая копия — с настоящим числом.
local function testConfig(world)
	local real = world:LoadModule("src/shared/Config/MonetizationConfig")
	local config = Harness.DeepCopy(real)
	config.GamePasses[1].GamePassId = GAME_PASS_ID
	return config
end

-- MonetizationSystem + PetSystem + FactorySystem в одном «сервере» с общим DataSystem.
-- Игрок уже на сервере (world.Players), Init вызывает сам тест: так видно порядок событий.
local function setup(config: any?)
	local world = Harness.NewWorld()
	local _, dataSystem = world:NewServer()
	local profiles = {}
	local snapshots = {}

	local function remote()
		return {
			OnServerEvent = { Connect = function() end },
			FireClient = function(_self, target, snapshot)
				table.insert(snapshots, { Player = target, Snapshot = Harness.DeepCopy(snapshot) })
			end,
		}
	end
	local fakeRemotes = {}
	for _, name in {
		"PurchaseUpgrade",
		"EconomySnapshot",
		"HatchCocoon",
		"EquipPet",
		"UnequipPet",
		"PetSnapshot",
	} do
		fakeRemotes[name] = remote()
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
		["src/shared/Config/MonetizationConfig"] = config or testConfig(world),
	}
	local petSystem = world:LoadModule("src/server/Systems/PetSystem", overrides)
	overrides["src/server/Systems/PetSystem"] = petSystem
	local factory = world:LoadModule("src/server/Systems/FactorySystem", overrides)
	overrides["src/server/Systems/FactorySystem"] = factory
	local monetization = world:LoadModule("src/server/Systems/MonetizationSystem", overrides)

	local player = world:NewPlayer(42)
	local data = dataSystem.BuildDefaultProfile()
	profiles[player] = data
	world.Players = { player }

	-- Считает вызовы PetSystem.RefreshBonuses (MonetizationSystem зовёт её через таблицу модуля).
	local refreshCalls = 0
	local originalRefresh = petSystem.RefreshBonuses
	petSystem.RefreshBonuses = function(p)
		refreshCalls += 1
		originalRefresh(p)
	end

	return {
		World = world,
		Player = player,
		Data = data,
		Pets = petSystem,
		Factory = factory,
		Monetization = monetization,
		Snapshots = snapshots,
		PetConfig = world:LoadModule("src/shared/Config/PetConfig"),
		RefreshCalls = function()
			return refreshCalls
		end,
		LastSnapshot = function()
			return snapshots[#snapshots]
		end,
		-- Ответ Roblox на владение геймпассом (для всех проверок).
		Owns = function(value: any)
			world.GamePassOwnership = function()
				return value
			end
		end,
		-- Roblox сообщает о завершении окна покупки.
		FinishPurchase = function(gamePassId: any, wasPurchased: any)
			for _, handler in world.PurchaseFinishedHandlers do
				handler(player, gamePassId, wasPurchased)
			end
		end,
	}
end

local function warningsAbout(t, text: string): number
	local n = 0
	for _, warning in t.World.Warnings do
		if string.find(warning, text, 1, true) then
			n += 1
		end
	end
	return n
end

local function ownedList(t): string
	return table.concat(t.Data.Monetization.GamePassesOwned, ",")
end

------------------------------------------------------------------------------------------
-- Конфиг
------------------------------------------------------------------------------------------

test("MonetizationConfig грузится, геймпасс слотов петов описан, цены в Robux в конфиге нет", function()
	local world = Harness.NewWorld()
	local config = world:LoadModule("src/shared/Config/MonetizationConfig")
	local petConfig = world:LoadModule("src/shared/Config/PetConfig")
	local found = false
	for _, pass in config.GamePasses do
		assert(type(pass.Id) == "string" and type(pass.DisplayName) == "string")
		assert(type(pass.GamePassId) == "number" and pass.GamePassId >= 0 and pass.GamePassId % 1 == 0)
		for key in pass do
			assert(not string.find(string.lower(key), "price") and not string.find(string.lower(key), "robux"), key)
		end
		found = found or pass.Id == petConfig.ExtraSlotsGamePassId
	end
	assert(found, "PetConfig.ExtraSlotsGamePassId есть в MonetizationConfig")
end)

test("MonetizationSystem не грузится, если геймпасса слотов петов нет в конфиге", function()
	local world = Harness.NewWorld()
	local config = Harness.DeepCopy(world:LoadModule("src/shared/Config/MonetizationConfig"))
	config.GamePasses = {}
	local ok, err = pcall(setup, config)
	assert(not ok and string.find(tostring(err), PASS_ID, 1, true), `ожидалась ошибка про {PASS_ID}: {err}`)
end)

test("GamePassId = 0 (заглушка): Roblox не опрашивается, владение из профиля не меняется, один warn", function()
	local world = Harness.NewWorld()
	local placeholder = world:LoadModule("src/shared/Config/MonetizationConfig")
	assert(placeholder.GamePasses[1].GamePassId == 0, "в репозитории GamePassId — заглушка")
	local t = setup(placeholder)
	local calls = 0
	t.World.GamePassOwnership = function()
		calls += 1
		return true
	end
	table.insert(t.Data.Monetization.GamePassesOwned, PASS_ID)
	t.Monetization.Init()
	assert(calls == 0, "API не вызывался")
	assert(ownedList(t) == PASS_ID, "кэш профиля не тронут")
	assert(warningsAbout(t, "заглушка") == 1)
end)

------------------------------------------------------------------------------------------
-- Проверка владения при входе
------------------------------------------------------------------------------------------

test("Владение подтверждено: GamePassesOwned записан, RefreshBonuses вызван, слоты выросли, снимок ушёл", function()
	local t = setup()
	t.Owns(true)
	assert(t.Pets.GetEquipSlots(t.Data) == t.PetConfig.BaseEquipSlots)
	t.Monetization.Init()

	assert(ownedList(t) == PASS_ID)
	assert(t.RefreshCalls() == 1, `RefreshBonuses вызван {t.RefreshCalls()} раз`)
	assert(t.Pets.GetEquipSlots(t.Data) == t.PetConfig.BaseEquipSlots + t.PetConfig.ExtraEquipSlots)
	local snap = t.LastSnapshot()
	assert(snap and snap.Player == t.Player and snap.Snapshot.GamePassesOwned[1] == PASS_ID, "снимок с владением")
end)

test("Владение не изменилось — ни RefreshBonuses, ни снимка", function()
	local t = setup()
	table.insert(t.Data.Monetization.GamePassesOwned, PASS_ID)
	t.Owns(true)
	t.Monetization.Init()
	assert(ownedList(t) == PASS_ID and #t.Data.Monetization.GamePassesOwned == 1, "без дубля")
	assert(t.RefreshCalls() == 0 and #t.Snapshots == 0)
end)

test("Владение отозвано (false): Id убран, чужие Id остались, слоты вернулись", function()
	local t = setup()
	t.Data.Monetization.GamePassesOwned = { "Other", PASS_ID }
	t.Owns(false)
	t.Monetization.Init()
	assert(ownedList(t) == "Other", `список {ownedList(t)}`)
	assert(t.RefreshCalls() == 1)
	assert(t.Pets.GetEquipSlots(t.Data) == t.PetConfig.BaseEquipSlots)
end)

test("Бонусы петов пересчитываются: после покупки лишний надетый пет начинает давать бонус", function()
	local t = setup()
	local base = t.PetConfig.BaseEquipSlots
	for i = 1, base + 1 do
		table.insert(t.Data.Pets, {
			Id = `p{i}`,
			SpeciesId = "DozySheep",
			Rarity = "Common",
			Level = 1,
			Equipped = true,
		})
	end
	t.Pets.RefreshBonuses(t.Player) -- кэш до покупки: считаются только base слотов
	local before = t.Pets.GetCachedBonuses(t.Player).ConveyorSpeedMultiplier
	t.Owns(true)
	t.Monetization.Init()
	local after = t.Pets.GetCachedBonuses(t.Player).ConveyorSpeedMultiplier
	assert(after > before, `множитель {before} → {after}`)
end)

------------------------------------------------------------------------------------------
-- Сбои Roblox API
------------------------------------------------------------------------------------------

test("UserOwnsGamePassAsync бросает ошибку: кэш не затёрт, сервер жив, один warn", function()
	local t = setup()
	table.insert(t.Data.Monetization.GamePassesOwned, PASS_ID)
	t.World.GamePassOwnership = function()
		error("HTTP 503")
	end
	local ok = pcall(t.Monetization.Init)
	assert(ok, "Init не падает")
	assert(ownedList(t) == PASS_ID, "владение осталось")
	assert(t.RefreshCalls() == 0 and #t.Snapshots == 0)
	assert(warningsAbout(t, "Не удалось проверить геймпасс") == 1)

	-- Повторный сбой в той же сессии в лог не спамит.
	t.FinishPurchase(GAME_PASS_ID, true)
	t.World:Advance(30)
	assert(warningsAbout(t, "Не удалось проверить геймпасс") == 1, "предупреждение одно за сессию")
end)

test("Мусорный ответ (не boolean) считается сбоем и не меняет профиль", function()
	for _, garbage in { "true", 1, {}, 0 / 0 } do
		local t = setup()
		table.insert(t.Data.Monetization.GamePassesOwned, PASS_ID)
		t.Owns(garbage)
		t.Monetization.Init()
		assert(ownedList(t) == PASS_ID, "кэш не затёрт")
		assert(warningsAbout(t, "неожиданный ответ") == 1)
	end
	local t = setup()
	t.Owns(nil) -- API вернул nil
	t.Monetization.Init()
	assert(ownedList(t) == "", "nil не превращается в «владеет»")
end)

test("Сбой на входе, потом успешная покупка — владение появляется", function()
	local t = setup()
	t.World.GamePassOwnership = function()
		error("timeout")
	end
	t.Monetization.Init()
	assert(ownedList(t) == "")
	t.Owns(true)
	t.FinishPurchase(GAME_PASS_ID, true)
	assert(ownedList(t) == PASS_ID)
end)

test("Зависший вызов Roblox не блокирует Init; ответ применяется, когда придёт", function()
	local t = setup()
	t.World.GamePassOwnership = function()
		t.World.Task.wait(100)
		return true
	end
	local returned = false
	t.World:Spawn(function()
		t.Monetization.Init()
		returned = true
	end)
	assert(returned, "Init вернулся, не дожидаясь Roblox")
	assert(ownedList(t) == "", "пока ответа нет — владения нет")
	t.World:Advance(101)
	assert(ownedList(t) == PASS_ID, "медленный ответ применился, когда пришёл")
end)

------------------------------------------------------------------------------------------
-- PromptGamePassPurchaseFinished
------------------------------------------------------------------------------------------

test("Покупка посреди сессии (wasPurchased = true): владение и слоты петов обновляются", function()
	local t = setup()
	t.Monetization.Init() -- на входе Roblox: false
	assert(ownedList(t) == "" and t.Pets.GetEquipSlots(t.Data) == t.PetConfig.BaseEquipSlots)

	t.Owns(true)
	t.FinishPurchase(GAME_PASS_ID, true)
	assert(ownedList(t) == PASS_ID)
	assert(t.Pets.GetEquipSlots(t.Data) == t.PetConfig.BaseEquipSlots + t.PetConfig.ExtraEquipSlots)
	assert(t.RefreshCalls() == 1)
	assert(t.LastSnapshot().Snapshot.GamePassesOwned[1] == PASS_ID)
end)

test("wasPurchased = false, чужой gamePassId и мусорные аргументы игнорируются без вызова API", function()
	local t = setup()
	local calls = 0
	t.World.GamePassOwnership = function()
		calls += 1
		return true
	end
	t.Monetization.Init()
	local callsAfterInit = calls
	t.FinishPurchase(GAME_PASS_ID, false)
	t.FinishPurchase(999, true)
	t.FinishPurchase("424242", true)
	t.FinishPurchase(GAME_PASS_ID, "yes")
	t.FinishPurchase(nil, true)
	t.World:Advance(30)
	assert(calls == callsAfterInit, "лишних обращений к Roblox нет")
end)

test("wasPurchased = true, но владение видно не сразу: перепроверки, затем успех", function()
	local t = setup()
	t.Monetization.Init()
	local calls = 0
	t.World.GamePassOwnership = function()
		calls += 1
		return calls >= 3 -- Roblox отдаёт «куплено» только с третьей проверки
	end
	t.FinishPurchase(GAME_PASS_ID, true)
	assert(ownedList(t) == "", "сразу ещё не видно")
	t.World:Advance(20)
	assert(ownedList(t) == PASS_ID and calls == 3, `проверок {calls}`)
	assert(warningsAbout(t, "не подтвердил") == 0)
end)

test("wasPurchased = true, но Roblox так и не подтвердил: ровно PurchaseRecheckAttempts проверок и один warn", function()
	local t = setup()
	t.Monetization.Init()
	local calls = 0
	t.World.GamePassOwnership = function()
		calls += 1
		return false
	end
	t.FinishPurchase(GAME_PASS_ID, true)
	t.World:Advance(60)
	local attempts = t.World:LoadModule("src/shared/Config/MonetizationConfig").PurchaseRecheckAttempts
	assert(calls == attempts, `проверок {calls}, ожидалось {attempts}`)
	assert(ownedList(t) == "" and warningsAbout(t, "не подтвердил") == 1)
end)

test("Устаревший ответ (запрошен до покупки, пришёл после) не затирает свежее «куплено»", function()
	local t = setup()
	local calls = 0
	t.World.GamePassOwnership = function()
		calls += 1
		if calls == 1 then
			t.World.Task.wait(5) -- проверка при входе: медленная, и ответ «не владеет» устарел
			return false
		end
		return true
	end
	t.Monetization.Init()
	t.FinishPurchase(GAME_PASS_ID, true) -- покупка во время «зависшей» проверки входа
	assert(ownedList(t) == PASS_ID)
	t.World:Advance(10)
	assert(ownedList(t) == PASS_ID, "старый false не затёр владение")
	assert(t.RefreshCalls() == 1)
end)

test("Игрок вышел, пока Roblox отвечал: ничего не пишется и не отправляется", function()
	local t = setup()
	t.World.GamePassOwnership = function()
		t.World.Task.wait(5)
		return true
	end
	t.Monetization.Init()
	t.Player.Parent = nil
	t.World:Advance(10)
	assert(ownedList(t) == "" and t.RefreshCalls() == 0 and #t.Snapshots == 0)
end)

------------------------------------------------------------------------------------------
-- Снимок экономики
------------------------------------------------------------------------------------------

test("EconomySnapshot с битым Monetization собирается: Essence и Rebirth не теряются", function()
	local variants = {
		function(d)
			d.Monetization = "broken"
		end,
		function(d)
			d.Monetization.GamePassesOwned = 5
		end,
		function(d)
			d.Monetization.GamePassesOwned = { PASS_ID, 7, {}, "Other" }
		end,
	}
	for index, corrupt in variants do
		local t = setup()
		t.Data.Currency.Essence = 321
		t.Data.Rebirth.Count = 4
		corrupt(t.Data)
		t.Factory.PushSnapshot(t.Player)
		local snap = t.LastSnapshot()
		assert(snap, `вариант {index}: снимок отправлен`)
		assert(snap.Snapshot.Essence == 321 and snap.Snapshot.RebirthCount == 4, `вариант {index}: данные не потеряны`)
		assert(type(snap.Snapshot.GamePassesOwned) == "table", `вариант {index}: список есть`)
		if index == 3 then
			assert(#snap.Snapshot.GamePassesOwned == 2, "нестроковые записи отброшены")
		else
			assert(#snap.Snapshot.GamePassesOwned == 0)
		end
	end
end)

test("Битый раздел Monetization: проверка владения не падает и пишет одно предупреждение", function()
	local t = setup()
	t.Data.Monetization = "broken" :: any
	t.Owns(true)
	t.Monetization.Init()
	t.FinishPurchase(GAME_PASS_ID, true)
	assert(warningsAbout(t, "Раздел Monetization повреждён") == 1)
	assert(#t.Snapshots == 0)
end)

test("Битый список GamePassesOwned восстанавливается перечитыванием у Roblox", function()
	local t = setup()
	t.Data.Monetization.GamePassesOwned = 5 :: any
	t.Owns(true)
	t.Monetization.Init()
	assert(ownedList(t) == PASS_ID and t.RefreshCalls() == 1)
end)

return tests
