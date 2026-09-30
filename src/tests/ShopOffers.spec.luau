--[[
	Тесты вкладки «Разовые покупки» (чистый OneTimeOffers, логика ShopUI): состав из
	DevProductConfig (паки Эссенции + баффы, без премиума пропуска), состояние кнопки
	(заглушка ProductId = 0, цена, дебаунс окна покупки, Magnet Boost у владельца Авто-сборщика)
	и остаток действующего баффа по атрибуту игрока.

	Запуск: lune run src/tests/run (из корня репозитория).
]]

local Harness = require("./lib/Harness")

type Test = { Name: string, Run: () -> () }

local tests: { Test } = {}

local function test(name: string, run: () -> ())
	table.insert(tests, { Name = name, Run = run })
end

local function setup()
	local world = Harness.NewWorld()
	local load = world:ModuleLoader()
	local offers = load("src/client/UI/OneTimeOffers")
	local config = load("src/shared/Config/DevProductConfig")
	local byId = {}
	for _, product in config.Products do
		byId[product.Id] = product
	end
	-- Копия продукта с «настоящим» ProductId (в реальном конфиге — заглушки 0).
	local function configured(id: string)
		local product = Harness.DeepCopy(byId[id])
		product.ProductId = 555
		return product
	end
	return {
		Offers = offers,
		ById = byId,
		Configured = configured,
		AutoCollector = load("src/shared/Config/AutoCollectorConfig").GamePassId,
	}
end

test("Состав вкладки: паки Эссенции и баффы в порядке конфига, без премиума пропуска", function()
	local t = setup()
	local ids = {}
	for _, product in t.Offers.List() do
		table.insert(ids, product.Id)
	end
	assert(
		table.concat(ids, ",") == "EssencePackS,EssencePackM,EssencePackL,EssencePackXL,MagnetBoost,SpeedBoost",
		table.concat(ids, ",")
	)
end)

test("Атрибут срока — только у баффов и совпадает с тем, что пишет BuffSystem", function()
	local t = setup()
	assert(t.Offers.BuffAttribute(t.ById.MagnetBoost) == "MagnetBoostExpiresAt")
	assert(t.Offers.BuffAttribute(t.ById.SpeedBoost) == "SpeedBoostExpiresAt")
	assert(t.Offers.BuffAttribute(t.ById.EssencePackS) == nil)
end)

test("Кнопка: заглушка ProductId = 0 недоступна при любой цене", function()
	local t = setup()
	for _, id in { "EssencePackS", "SpeedBoost", "MagnetBoost" } do
		assert(t.Offers.ButtonState(t.ById[id], "Ready", {}, false) == "Unavailable", id)
	end
end)

test("Кнопка: без явной цены — недоступно; дебаунс окна покупки — ожидание; иначе — купить", function()
	local t = setup()
	local pack = t.Configured("EssencePackM")
	for _, status in { "Idle", "Loading", "Failed", "NotForSale" } do
		assert(t.Offers.ButtonState(pack, status, {}, false) == "Unavailable", status)
	end
	assert(t.Offers.ButtonState(pack, "Ready", {}, true) == "Waiting")
	assert(t.Offers.ButtonState(pack, "Ready", {}, false) == "Buy")
	assert(t.Offers.ButtonState(pack, "Ready", nil, false) == "Buy", "паку Эссенции снимок владения не нужен")
end)

test("Кнопка: Magnet Boost владельцу Авто-сборщика — «есть в геймпассе»; без снимка — ожидание", function()
	local t = setup()
	local magnet = t.Configured("MagnetBoost")
	local speed = t.Configured("SpeedBoost")
	assert(t.Offers.ButtonState(magnet, "Ready", { t.AutoCollector }, false) == "Included")
	assert(t.Offers.ButtonState(magnet, "Ready", nil, false) == "Waiting", "владение ещё неизвестно")
	assert(t.Offers.ButtonState(magnet, "Ready", { "ExtraPetSlots" }, false) == "Buy")
	assert(t.Offers.ButtonState(speed, "Ready", { t.AutoCollector }, false) == "Buy", "Speed Boost геймпасс не заменяет")
end)

test("Остаток баффа: целые секунды вверх; истёкший, битый или отсутствующий — nil", function()
	local t = setup()
	local left = t.Offers.BuffSecondsLeft
	assert(left(1_000_020, 1_000_000) == 20)
	assert(left(1_000_020, 1_000_019.2) == 1, "0.8 с показываются как 1")
	assert(left(1_000_020, 1_000_020) == nil, "ровно истёк")
	assert(left(1_000_000, 1_000_020) == nil, "давно истёк")
	assert(left(nil, 0) == nil and left("20", 0) == nil)
	assert(left(0 / 0, 0) == nil and left(math.huge, 0) == nil)
end)

return tests
