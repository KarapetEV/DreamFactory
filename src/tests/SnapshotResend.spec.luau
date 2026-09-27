--[[
	Тесты страховки от гонки при старте: первый снимок (PetSnapshot / EconomySnapshot) после
	загрузки профиля уходит ещё раз через InitialSnapshotResendDelay секунд.

	RemoteEvent не ставится в очередь: если клиент подключил OnClientEvent позже первой
	отправки, тот снимок потерян. «Клиент» ниже принимает FireClient только после Connect().

	Запуск: lune run src/tests/run (из корня репозитория).
]]

local Harness = require("./lib/Harness")

type Test = { Name: string, Run: () -> () }

local tests: { Test } = {}

local function test(name: string, run: () -> ())
	table.insert(tests, { Name = name, Run = run })
end

-- Поддельный клиент: события до Connect() теряются, как у настоящего RemoteEvent без обработчика.
local function newClient()
	local client = { Received = {} :: { any }, Connected = false }
	function client.Connect()
		client.Connected = true
	end
	function client.Deliver(snapshot: any)
		if client.Connected then
			table.insert(client.Received, Harness.DeepCopy(snapshot))
		end
	end
	return client
end

local function setupPet()
	local world = Harness.NewWorld()
	local _, dataSystem = world:NewServer()
	local player = world:NewPlayer(42)
	local data = dataSystem.BuildDefaultProfile()
	local client = newClient()
	local sent = 0

	local function remote()
		return {
			OnServerEvent = { Connect = function() end },
			FireClient = function(_self, _target, snapshot)
				sent += 1
				client.Deliver(snapshot)
			end,
		}
	end

	local petSystem = world:LoadModule("src/server/Systems/PetSystem", {
		["src/server/Systems/DataSystem"] = {
			GetData = function()
				return data
			end,
			WaitForData = function()
				return data
			end,
			BuildDefaultProfile = dataSystem.BuildDefaultProfile,
		},
		["src/shared/Remotes"] = {
			HatchCocoon = remote(),
			EquipPet = remote(),
			UnequipPet = remote(),
			PetSnapshot = remote(),
		},
	})
	world.Players = { player }
	petSystem.Init() -- игрок уже на сервере: первый снимок уходит сразу
	return {
		World = world,
		Player = player,
		Data = data,
		Client = client,
		Sent = function()
			return sent
		end,
	}
end

local function setupFactory()
	local world = Harness.NewWorld()
	local _, dataSystem = world:NewServer()
	local player = world:NewPlayer(42)
	local data = dataSystem.BuildDefaultProfile()
	local client = newClient()
	local sent = 0

	local factory = world:LoadModule("src/server/Systems/FactorySystem", {
		["src/server/Systems/DataSystem"] = {
			GetData = function()
				return data
			end,
			BuildDefaultProfile = dataSystem.BuildDefaultProfile,
		},
		["src/shared/Remotes"] = {
			PurchaseUpgrade = { OnServerEvent = { Connect = function() end } },
			EconomySnapshot = {
				OnServerEvent = { Connect = function() end },
				FireClient = function(_self, _target, snapshot)
					sent += 1
					client.Deliver(snapshot)
				end,
			},
		},
	})
	world.Players = { player }
	factory.Init()
	return {
		World = world,
		Player = player,
		Data = data,
		Client = client,
		Sent = function()
			return sent
		end,
	}
end

------------------------------------------------------------------------------------------
-- PetSystem
------------------------------------------------------------------------------------------

test("PetSnapshot: клиент подключился после первой отправки — повтор доносит актуальные данные", function()
	local t = setupPet()
	assert(t.Sent() == 1, "первый снимок ушёл сразу")
	assert(#t.Client.Received == 0, "клиент ещё не подписан — первый снимок потерян")

	t.World:Advance(1)
	t.Client.Connect()
	-- Состояние изменилось между первой отправкой и повтором: клиент должен получить свежее.
	table.insert(t.Data.Pets, { Id = "p1", SpeciesId = "DozySheep", Rarity = "Rare", Level = 1, Equipped = false })
	t.World:Advance(2)

	assert(#t.Client.Received == 1, `повтор дошёл, получено {#t.Client.Received}`)
	local snapshot = t.Client.Received[1]
	assert(snapshot.Ack == nil, "это плановый снимок, не ответ на запрос")
	assert(#snapshot.Pets == 1 and snapshot.Pets[1].Id == "p1", "в повторе актуальный список петов")
end)

test("PetSnapshot: повтор ровно один, не цикл", function()
	local t = setupPet()
	t.Client.Connect()
	t.World:Advance(60)
	assert(t.Sent() == 2, `первая отправка + один повтор, было {t.Sent()}`)
end)

test("PetSnapshot: игрок вышел до повтора — повтор не отправляется", function()
	local t = setupPet()
	t.World:Advance(1)
	t.Player.Parent = nil
	t.World:Advance(5)
	assert(t.Sent() == 1, `только первая отправка, было {t.Sent()}`)
end)

------------------------------------------------------------------------------------------
-- FactorySystem
------------------------------------------------------------------------------------------

test("EconomySnapshot: клиент подключился после первого снимка — повтор доносит актуальные данные", function()
	local t = setupFactory()
	t.World:Advance(0.5)
	assert(t.Sent() >= 1, "первый снимок ушёл на тике")
	assert(#t.Client.Received == 0, "клиент ещё не подписан — первый снимок потерян")

	t.Client.Connect()
	t.Data.Currency.Essence = 777
	t.World:Advance(3)

	assert(#t.Client.Received >= 1, "повтор дошёл")
	assert(t.Client.Received[#t.Client.Received].Essence == 777, "в повторе актуальный Essence")
end)

test("EconomySnapshot: повтор первого снимка — один, дальше только по изменениям", function()
	local t = setupFactory()
	t.Client.Connect()
	t.World:Advance(60) -- данные не меняются: тик ничего не шлёт
	assert(t.Sent() == 2, `первый снимок + один повтор, было {t.Sent()}`)
end)

test("EconomySnapshot: игрок вышел до повтора — повтор не отправляется", function()
	local t = setupFactory()
	t.World:Advance(1)
	local before = t.Sent()
	t.Player.Parent = nil
	t.World:Advance(5)
	assert(t.Sent() == before, "после выхода игрока снимки не шлются")
end)

return tests
