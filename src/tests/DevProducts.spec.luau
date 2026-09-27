--[[
	Тесты дев-продуктов (S12, раздел 5.7 ТЗ): идемпотентность MonetizationSystem.ProcessReceipt.
	- повторная доставка одного PurchaseId не выдаёт товар дважды (в т.ч. после сбоя записи
	  профиля / лога, при параллельной доставке и после переноса профиля на другой сервер);
	- покупка при незагруженном профиле не выдаётся и не теряется (NotProcessedYet);
	- битая квитанция / неизвестный ProductId не роняют ProcessReceipt.

	Профиль — настоящий ProfileStoreService над поддельным DataStore мира (world.Records), чтобы
	проверять именно durable-состояние. Сбои DataStore — world.StoreError.
	Запуск: lune run src/tests/run (из корня репозитория).
]]

local Harness = require("./lib/Harness")

type Test = { Name: string, Run: () -> () }

local tests: { Test } = {}

local function test(name: string, run: () -> ())
	table.insert(tests, { Name = name, Run = run })
end

local GRANTED = "PurchaseGranted"
local NOT_YET = "NotProcessedYet"

local PRODUCT_ID = 777001 -- EssencePackS в тестовой копии конфига
local PRODUCT_ID_XL = 777004

-- Реальный конфиг держит ProductId = 0 (заглушки); тестовая копия — с настоящими числами.
local function testConfig(world, history: number?)
	local config = Harness.DeepCopy(world:LoadModule("src/shared/Config/DevProductConfig"))
	for index, product in config.Products do
		product.ProductId = 777000 + index
	end
	if history then
		config.ProfileReceiptHistory = history
	end
	return config
end

-- Один «процесс сервера»: ProfileStoreService + MonetizationSystem. DataSystem — тонкая
-- обёртка над загруженными профилями (GetData/SaveNow с той же семантикой, что у настоящего).
local function newServer(world, config: any?)
	local profileStore, dataSystem = world:NewServer()
	local profiles = {}
	local snapshots = 0

	local overrides = {
		["src/server/Systems/DataSystem"] = {
			GetData = function(p)
				local profile = profiles[p]
				return if profile and profile.Active then profile.Data else nil
			end,
			WaitForData = function(p)
				local profile = profiles[p]
				return if profile and profile.Active then profile.Data else nil
			end,
			SaveNow = function(p)
				local profile = profiles[p]
				if profile == nil or not profile.Active then
					return false
				end
				return profileStore.SaveProfile(p)
			end,
			BuildDefaultProfile = dataSystem.BuildDefaultProfile,
		},
		["src/server/Systems/FactorySystem"] = {
			PushSnapshot = function()
				snapshots += 1
			end,
		},
		["src/server/Systems/PetSystem"] = {
			RefreshBonuses = function() end,
		},
		["src/shared/Config/DevProductConfig"] = config or testConfig(world),
	}
	local monetization = world:LoadModule("src/server/Systems/MonetizationSystem", overrides)

	local server = {}
	server.Monetization = monetization

	function server.Load(player)
		local profile
		world:Spawn(function()
			profile = profileStore.LoadProfile(player)
		end)
		world:Advance(120) -- с запасом на ожидание/перехват чужого лока
		assert(profile, "профиль загрузился")
		local migrated = assert(dataSystem.MigrateProfileData(profile.Data))
		profile.Data = migrated
		profiles[player] = profile
		return profile.Data
	end

	function server.Release(player)
		profiles[player] = nil
		world:Spawn(function()
			profileStore.ReleaseProfile(player)
		end)
		world:Advance(30)
	end

	function server.Data(player)
		local profile = profiles[player]
		return profile and profile.Data
	end

	-- ProcessReceipt в отдельной корутине (он yield'ит на DataStore); ждёт завершения.
	function server.Receipt(info: any, wait: number?): string?
		local result
		world:Spawn(function()
			result = monetization.ProcessReceipt(info)
		end)
		world:Advance(wait or 30)
		return result
	end

	function server.Snapshots()
		return snapshots
	end

	return server
end

local function receipt(playerId: number, purchaseId: string, productId: number?): any
	return {
		PlayerId = playerId,
		ProductId = productId or PRODUCT_ID,
		PurchaseId = purchaseId,
		CurrencySpent = 49,
		CurrencyType = "Robux",
		PlaceIdWherePurchased = 1,
	}
end

local function setup()
	local world = Harness.NewWorld()
	local config = testConfig(world)
	local server = newServer(world, config)
	local player = world:NewPlayer(42)
	world.Players = { player }
	local data = server.Load(player)
	return {
		World = world,
		Config = config,
		Server = server,
		Player = player,
		Data = data,
		StartEssence = data.Currency.Essence,
		Amount = config.Products[1].Reward.Amount,
	}
end

-- Эссенция в DataStore (durable), а не в памяти сервера.
local function storedEssence(world, userId: number): number
	return world.Records[`Player_{userId}`].Data.Currency.Essence
end

local function markerIds(list): string
	local ids = {}
	for _, marker in list do
		table.insert(ids, `{marker.Id}{if marker.Closed then "" else "*"}`)
	end
	return table.concat(ids, ",")
end

local function logRecord(world, purchaseId: string): any
	return world.Records[`Receipt_{purchaseId}`]
end

local function failKeys(world, op: string, prefix: string)
	world.StoreError = function(requestOp: string, key: string): string?
		if requestOp == op and string.sub(key, 1, #prefix) == prefix then
			return "DataStore: 502 Bad Gateway (тест)"
		end
		return nil
	end
end

local function warningsAbout(world, text: string): number
	local n = 0
	for _, warning in world.Warnings do
		if string.find(warning, text, 1, true) then
			n += 1
		end
	end
	return n
end

------------------------------------------------------------------------------------------
-- Конфиг
------------------------------------------------------------------------------------------

test("DevProductConfig: паки Эссенции S/M/L/XL (объём растёт) + премиум пропуска, ProductId — заглушки 0", function()
	local world = Harness.NewWorld()
	local config = world:LoadModule("src/shared/Config/DevProductConfig")
	local ids = {}
	local previous = 0
	for _, product in config.Products do
		table.insert(ids, product.Id)
		if product.Reward.Kind == "Essence" then
			assert(product.Reward.Amount > previous, `{product.Id}: объём больше предыдущего`)
			previous = product.Reward.Amount
		else
			assert(product.Reward.Kind == "BattlePassPremium" and product.Reward.Amount == nil, product.Id)
		end
		assert(product.ProductId == 0, `{product.Id}: ProductId заглушка`)
		assert(product.Price == nil, "цены в Robux в конфиге нет")
	end
	assert(
		table.concat(ids, ",") == "EssencePackS,EssencePackM,EssencePackL,EssencePackXL,BattlePassPremium",
		table.concat(ids, ",")
	)
end)

test("профиль v4 мигрирует в v5 с пустым ProcessedReceipts, остальное не тронуто", function()
	local world = Harness.NewWorld()
	local _, dataSystem = world:NewServer()
	local v4 = {
		Meta = { SchemaVersion = 4 },
		Monetization = { GamePassesOwned = { "ExtraPetSlots" }, BattlePassTier = 0 },
	}
	local migrated = assert(dataSystem.MigrateProfileData(v4))
	assert(migrated.Meta.SchemaVersion == dataSystem.CURRENT_SCHEMA_VERSION)
	assert(type(migrated.Monetization.ProcessedReceipts) == "table" and #migrated.Monetization.ProcessedReceipts == 0)
	assert(migrated.Monetization.GamePassesOwned[1] == "ExtraPetSlots")
end)

------------------------------------------------------------------------------------------
-- Выдача и повторная доставка
------------------------------------------------------------------------------------------

test("покупка: PurchaseGranted только после записи профиля и лога; награда из конфига", function()
	local t = setup()
	local result = t.Server.Receipt(receipt(42, "purchase-1"))
	assert(result == GRANTED, tostring(result))
	assert(t.Data.Currency.Essence == t.StartEssence + t.Amount, "начислено ровно Amount")
	assert(storedEssence(t.World, 42) == t.StartEssence + t.Amount, "выдача уже в DataStore")
	local stored = t.World.Records.Player_42.Data.Monetization.ProcessedReceipts
	assert(markerIds(stored) == "purchase-1*", "маркер в DataStore (ещё не закрыт на момент сохранения)")
	assert(markerIds(t.Data.Monetization.ProcessedReceipts) == "purchase-1", "после записи лога маркер закрыт")
	local log = logRecord(t.World, "purchase-1")
	assert(log and log.PlayerId == 42 and log.ProductId == PRODUCT_ID and log.Product == "EssencePackS", "лог записан")
	assert(t.Server.Snapshots() == 1, "HUD получил снимок")
end)

test("повторная доставка того же PurchaseId не выдаёт товар второй раз", function()
	local t = setup()
	assert(t.Server.Receipt(receipt(42, "purchase-1")) == GRANTED)
	for _ = 1, 3 do
		assert(t.Server.Receipt(receipt(42, "purchase-1")) == GRANTED, "повтор закрывается")
	end
	assert(t.Data.Currency.Essence == t.StartEssence + t.Amount, "выдано один раз")
	assert(#t.Data.Monetization.ProcessedReceipts == 1)

	-- Другой PurchaseId того же продукта — новая покупка.
	assert(t.Server.Receipt(receipt(42, "purchase-2")) == GRANTED)
	assert(t.Data.Currency.Essence == t.StartEssence + 2 * t.Amount, "вторая покупка выдана")
end)

test("сбой записи лога: NotProcessedYet, повтор не выдаёт второй раз и дописывает лог", function()
	local t = setup()
	failKeys(t.World, "UpdateAsync", "Receipt_")
	assert(t.Server.Receipt(receipt(42, "p-log")) == NOT_YET, "без лога покупка не закрыта")
	assert(logRecord(t.World, "p-log") == nil)
	assert(storedEssence(t.World, 42) == t.StartEssence + t.Amount, "выдача уже сохранена вместе с маркером")

	t.World.StoreError = nil
	assert(t.Server.Receipt(receipt(42, "p-log")) == GRANTED)
	assert(t.Data.Currency.Essence == t.StartEssence + t.Amount, "повтор не выдал второй раз")
	assert(logRecord(t.World, "p-log"), "лог дописан")
end)

test("сбой сохранения профиля: NotProcessedYet, повтор досохраняет без второй выдачи", function()
	local t = setup()
	failKeys(t.World, "UpdateAsync", "Player_")
	assert(t.Server.Receipt(receipt(42, "p-save")) == NOT_YET)
	assert(storedEssence(t.World, 42) == t.StartEssence, "в DataStore ещё ничего")
	assert(logRecord(t.World, "p-save") == nil, "лог не пишется раньше профиля")

	-- Повтор, пока DataStore ещё лежит, — тоже не выдаёт.
	assert(t.Server.Receipt(receipt(42, "p-save")) == NOT_YET)
	assert(t.Data.Currency.Essence == t.StartEssence + t.Amount, "в памяти выдано один раз")

	t.World.StoreError = nil
	assert(t.Server.Receipt(receipt(42, "p-save")) == GRANTED)
	assert(storedEssence(t.World, 42) == t.StartEssence + t.Amount, "сохранено ровно одно начисление")
end)

test("краш сервера до сохранения выдачи: покупка не теряется, новый сервер выдаёт ровно один раз", function()
	local t = setup()
	failKeys(t.World, "UpdateAsync", "Player_")
	assert(t.Server.Receipt(receipt(42, "p-crash")) == NOT_YET)
	t.World.StoreError = nil
	-- Сервер A умер без релиза: выдача в памяти пропала вместе с ним, лок висит.

	local serverB = newServer(t.World, t.Config)
	local dataB = serverB.Load(t.Player) -- перехват брошенного лока
	assert(dataB.Currency.Essence == t.StartEssence, "в сохранении выдачи не было")
	assert(serverB.Receipt(receipt(42, "p-crash")) == GRANTED)
	assert(dataB.Currency.Essence == t.StartEssence + t.Amount, "выдано ровно один раз")
	assert(storedEssence(t.World, 42) == t.StartEssence + t.Amount)
end)

test("профиль сохранён, лог — нет, игрок перешёл на другой сервер: без второй выдачи", function()
	local t = setup()
	failKeys(t.World, "UpdateAsync", "Receipt_")
	assert(t.Server.Receipt(receipt(42, "p-move")) == NOT_YET)
	t.World.StoreError = nil
	t.Server.Release(t.Player)

	local serverB = newServer(t.World, t.Config)
	local dataB = serverB.Load(t.Player)
	assert(serverB.Receipt(receipt(42, "p-move")) == GRANTED)
	assert(dataB.Currency.Essence == t.StartEssence + t.Amount, "маркер в профиле не дал выдать второй раз")
	assert(logRecord(t.World, "p-move"), "лог дописан новым сервером")
end)

test("закрытая квитанция на другом сервере — PurchaseGranted даже без загруженного профиля", function()
	local t = setup()
	assert(t.Server.Receipt(receipt(42, "p-done")) == GRANTED)
	t.Server.Release(t.Player)

	local serverB = newServer(t.World, t.Config)
	assert(serverB.Receipt(receipt(42, "p-done")) == GRANTED, "лог закрывает повтор без профиля")
	assert(storedEssence(t.World, 42) == t.StartEssence + t.Amount)
end)

test("параллельная доставка одного PurchaseId: вторая ждёт, выдача одна", function()
	local t = setup()
	local results = {}
	table.insert(t.World.StoreDelays, 5) -- первая доставка зависнет на сохранении профиля
	t.World:Spawn(function()
		results[1] = t.Server.Monetization.ProcessReceipt(receipt(42, "p-par"))
	end)
	t.World:Spawn(function()
		results[2] = t.Server.Monetization.ProcessReceipt(receipt(42, "p-par"))
	end)
	assert(results[2] == NOT_YET, "вторая доставка во время первой — повтор позже")
	t.World:Advance(30)
	assert(results[1] == GRANTED)
	assert(t.Data.Currency.Essence == t.StartEssence + t.Amount, "выдано один раз")
	assert(t.Server.Receipt(receipt(42, "p-par")) == GRANTED)
	assert(t.Data.Currency.Essence == t.StartEssence + t.Amount)
end)

test("история маркеров в профиле ограничена ProfileReceiptHistory", function()
	local world = Harness.NewWorld()
	local config = testConfig(world, 3)
	local server = newServer(world, config)
	local player = world:NewPlayer(42)
	world.Players = { player }
	local data = server.Load(player)
	local start = data.Currency.Essence
	for i = 1, 5 do
		assert(server.Receipt(receipt(42, `p{i}`)) == GRANTED)
	end
	local list = data.Monetization.ProcessedReceipts
	assert(markerIds(list) == "p3,p4,p5", markerIds(list))
	-- Вытесненный из профиля PurchaseId закрыт логом.
	assert(server.Receipt(receipt(42, "p1")) == GRANTED)
	assert(data.Currency.Essence == start + 5 * config.Products[1].Reward.Amount, "пять выдач, повтор не выдан")
	assert(#list == 3)
end)

test("незакрытый маркер (лог не записан) не вытесняется новыми покупками — повтор не выдаёт дважды", function()
	local world = Harness.NewWorld()
	local config = testConfig(world, 3)
	local server = newServer(world, config)
	local player = world:NewPlayer(42)
	world.Players = { player }
	local data = server.Load(player)
	local start = data.Currency.Essence
	local amount = config.Products[1].Reward.Amount

	failKeys(world, "UpdateAsync", "Receipt_p-stuck")
	assert(server.Receipt(receipt(42, "p-stuck")) == NOT_YET)
	world.StoreError = function(op: string, key: string): string?
		return if op == "UpdateAsync" and key == "Receipt_p-stuck" then "DataStore: throttled (тест)" else nil
	end
	for i = 1, 5 do
		assert(server.Receipt(receipt(42, `p{i}`)) == GRANTED)
	end
	local list = data.Monetization.ProcessedReceipts
	assert(markerIds(list) == "p-stuck*,p4,p5", markerIds(list))

	world.StoreError = nil
	assert(server.Receipt(receipt(42, "p-stuck")) == GRANTED)
	assert(data.Currency.Essence == start + 6 * amount, "p-stuck выдан один раз")
	assert(markerIds(list) == "p-stuck,p4,p5", "маркер закрыт после записи лога")
	assert(server.Receipt(receipt(42, "p6")) == GRANTED)
	assert(markerIds(list) == "p4,p5,p6", "закрытый — вытесняется как обычный")
end)

------------------------------------------------------------------------------------------
-- Незагруженный профиль
------------------------------------------------------------------------------------------

test("профиль не загружен: NotProcessedYet, ничего не выдано; после загрузки — выдача одна", function()
	local world = Harness.NewWorld()
	local config = testConfig(world)
	local server = newServer(world, config)
	local player = world:NewPlayer(42)
	world.Players = { player } -- игрок на сервере, профиль ещё грузится

	assert(server.Receipt(receipt(42, "p-early")) == NOT_YET)
	assert(logRecord(world, "p-early") == nil, "покупка не закрыта — Roblox повторит")
	assert(world.Records.Player_42 == nil, "профиль не трогали")

	local data = server.Load(player)
	local start = data.Currency.Essence
	assert(server.Receipt(receipt(42, "p-early")) == GRANTED)
	assert(data.Currency.Essence == start + config.Products[1].Reward.Amount)
end)

test("игрока нет на сервере / профиль уже освобождён: NotProcessedYet", function()
	local t = setup()
	assert(t.Server.Receipt(receipt(99, "p-other")) == NOT_YET, "чужой UserId")
	t.Server.Release(t.Player)
	assert(t.Server.Receipt(receipt(42, "p-left")) == NOT_YET, "игрок вышел")
	assert(storedEssence(t.World, 42) == t.StartEssence)
	assert(logRecord(t.World, "p-other") == nil and logRecord(t.World, "p-left") == nil)
end)

test("сбой чтения лога: NotProcessedYet без выдачи", function()
	local t = setup()
	failKeys(t.World, "GetAsync", "Receipt_")
	assert(t.Server.Receipt(receipt(42, "p-read")) == NOT_YET)
	assert(t.Data.Currency.Essence == t.StartEssence, "без чтения лога ничего не выдаём")
	t.World.StoreError = nil
	assert(t.Server.Receipt(receipt(42, "p-read")) == GRANTED)
	assert(t.Data.Currency.Essence == t.StartEssence + t.Amount)
end)

------------------------------------------------------------------------------------------
-- Битые квитанции
------------------------------------------------------------------------------------------

test("битые квитанции и неизвестный ProductId не роняют ProcessReceipt и ничего не выдают", function()
	local t = setup()
	local cases: { any } = {
		nil,
		"receipt",
		42,
		{},
		{ PlayerId = "42", ProductId = PRODUCT_ID, PurchaseId = "x" },
		{ PlayerId = 42.5, ProductId = PRODUCT_ID, PurchaseId = "x" },
		{ PlayerId = -1, ProductId = PRODUCT_ID, PurchaseId = "x" },
		{ PlayerId = 42, ProductId = 0 / 0, PurchaseId = "x" },
		{ PlayerId = 42, ProductId = math.huge, PurchaseId = "x" },
		{ PlayerId = 42, ProductId = PRODUCT_ID, PurchaseId = 123 },
		{ PlayerId = 42, ProductId = PRODUCT_ID, PurchaseId = "" },
		{ PlayerId = 42, ProductId = PRODUCT_ID, PurchaseId = string.rep("a", 60) },
		receipt(42, "p-unknown", 123456), -- нет в конфиге
		receipt(42, "p-stub", 0), -- заглушка ProductId = 0
	}
	for index = 1, 14 do
		local ok, result = pcall(t.Server.Receipt, cases[index])
		assert(ok, `случай {index} уронил ProcessReceipt: {result}`)
		assert(result == NOT_YET, `случай {index}: {tostring(result)}`)
	end
	assert(t.Data.Currency.Essence == t.StartEssence, "ничего не выдано")
	assert(#t.Data.Monetization.ProcessedReceipts == 0)

	-- Неизвестный продукт пишется в лог один раз, а не на каждый повтор.
	t.Server.Receipt(receipt(42, "p-unknown", 123456))
	assert(warningsAbout(t.World, "неизвестный ProductId 123456") == 1)

	-- Система после мусора работает.
	assert(t.Server.Receipt(receipt(42, "p-ok", PRODUCT_ID_XL)) == GRANTED)
	assert(t.Data.Currency.Essence == t.StartEssence + t.Config.Products[4].Reward.Amount)
end)

test("PurchaseId ровно на границе длины ключа DataStore (50 симв.) выдаётся; на 1 больше — нет", function()
	local t = setup()
	-- Ключ лога — RECEIPT_KEY_PREFIX ("Receipt_", 8 симв.) .. PurchaseId, лимит ключа DataStore 50.
	local maxId = string.rep("a", 42)
	assert(t.Server.Receipt(receipt(42, maxId)) == GRANTED, "ровно на границе — выдача, не отказ по длине")
	assert(t.Data.Currency.Essence == t.StartEssence + t.Amount)
	assert(logRecord(t.World, maxId), "лог записан ровно на границе")

	local overId = string.rep("b", 43)
	assert(t.Server.Receipt(receipt(42, overId)) == NOT_YET, "на 1 больше границы — отклонено")
	assert(t.Data.Currency.Essence == t.StartEssence + t.Amount, "за отклонённую квитанцию ничего не выдано")
	assert(logRecord(t.World, overId) == nil)
end)

test("реальный конфиг (ProductId = 0): любая квитанция — NotProcessedYet, не выдача", function()
	local world = Harness.NewWorld()
	local server = newServer(world, world:LoadModule("src/shared/Config/DevProductConfig"))
	local player = world:NewPlayer(42)
	world.Players = { player }
	local data = server.Load(player)
	local start = data.Currency.Essence
	assert(server.Receipt(receipt(42, "p", 0)) == NOT_YET)
	assert(server.Receipt(receipt(42, "p", PRODUCT_ID)) == NOT_YET)
	assert(data.Currency.Essence == start)
end)

test("повреждённая Essence или ProcessedReceipts: NotProcessedYet, профиль не тронут", function()
	local t = setup()
	t.Data.Currency.Essence = "много"
	assert(t.Server.Receipt(receipt(42, "p-bad")) == NOT_YET)
	assert(t.Data.Currency.Essence == "много" and #t.Data.Monetization.ProcessedReceipts == 0, "маркер без выдачи не ставится")

	t.Data.Currency.Essence = t.StartEssence
	t.Data.Monetization.ProcessedReceipts = "сломано"
	assert(t.Server.Receipt(receipt(42, "p-bad")) == NOT_YET)
	assert(t.Data.Currency.Essence == t.StartEssence, "без маркеров не выдаём")
	assert(logRecord(t.World, "p-bad") == nil)
end)

------------------------------------------------------------------------------------------
-- Аналитика (S18)
------------------------------------------------------------------------------------------

test("Выдача дев-продукта: DevProductPurchased один раз, после записи лога; повтор доставки — без события", function()
	local t = setup()
	failKeys(t.World, "UpdateAsync", "Receipt_")
	assert(t.Server.Receipt(receipt(42, "p-a")) == NOT_YET)
	assert(#t.World.AnalyticsEvents == 0, "квитанция не закрыта — ещё не покупка")

	t.World.StoreError = nil
	assert(t.Server.Receipt(receipt(42, "p-a")) == GRANTED)
	assert(t.Server.Receipt(receipt(42, "p-a")) == GRANTED)
	local events = t.World.AnalyticsEvents
	assert(#events == 1 and events[1].Name == "DevProductPurchased", `событий {#events}`)
	assert(events[1].Player == t.Player and events[1].CustomFields.CustomField01 == "EssencePackS")
end)

return tests
