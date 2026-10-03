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
	-- Копии продукта с заданным ProductId: независимо от того, заведён ли он уже в конфиге.
	local function withProductId(id: string, productId: number)
		local product = Harness.DeepCopy(byId[id])
		product.ProductId = productId
		return product
	end
	return {
		Offers = offers,
		ById = byId,
		Configured = function(id: string)
			return withProductId(id, 555)
		end,
		Stub = function(id: string)
			return withProductId(id, 0)
		end,
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

test("Атрибут зарядов — только у баффов и совпадает с тем, что пишет BuffSystem", function()
	local t = setup()
	assert(t.Offers.ChargesAttribute(t.ById.MagnetBoost) == "MagnetBoostCharges")
	assert(t.Offers.ChargesAttribute(t.ById.SpeedBoost) == "SpeedBoostCharges")
	assert(t.Offers.ChargesAttribute(t.ById.EssencePackS) == nil)
end)

test("Строки баффов продают пак: «×5» в названии совпадает с BuffConfig.PackSize", function()
	local t = setup()
	local buffConfig = Harness.NewWorld():LoadModule("src/shared/Config/BuffConfig")
	for _, id in { "MagnetBoost", "SpeedBoost" } do
		local suffix = `×{buffConfig.Buffs[id].PackSize}`
		assert(string.find(t.ById[id].DisplayName, suffix, 1, true), `{id}: {t.ById[id].DisplayName}`)
	end
end)

test("Кнопка: заглушка ProductId = 0 недоступна при любой цене", function()
	local t = setup()
	for _, id in { "EssencePackS", "SpeedBoost", "MagnetBoost" } do
		assert(t.Offers.ButtonState(t.Stub(id), "Ready", {}, false) == "Unavailable", id)
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

test("Заряды в строке пака: сколько есть из потолка; предупреждение, только если пак не влезет целиком", function()
	local t = setup()
	local magnet = t.ById.MagnetBoost
	local info = t.Offers.ChargesInfo(magnet, 3)
	assert(info.Charges == 3 and info.MaxCharges == 20 and not info.Overflow, "3 + 5 ≤ 20")
	assert(not t.Offers.ChargesInfo(magnet, 15).Overflow, "15 + 5 = 20 — влезает ровно")
	assert(t.Offers.ChargesInfo(magnet, 16).Overflow, "16 + 5 > 20 — часть сгорит")
	assert(t.Offers.ChargesInfo(magnet, 20).Overflow, "на потолке — сгорит весь пак")
	assert(t.Offers.ButtonState(t.Configured("MagnetBoost"), "Ready", {}, false) == "Buy", "предупреждение кнопку не блокирует")

	for _, junk in { nil, "7", 0 / 0, -2, math.huge } do
		local j = t.Offers.ChargesInfo(magnet, junk)
		assert(j.Charges == 0 and not j.Overflow, tostring(junk))
	end
	assert(t.Offers.ChargesInfo(t.ById.EssencePackS, 3) == nil, "пак Эссенции — без зарядов")
end)

return tests
