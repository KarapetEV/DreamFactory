--!strict

--[[
	Дев-продукты — повторные покупки за Robux (раздел 7.2 GDD, раздел 5.7 ТЗ; S12). Не секрет —
	лежит в shared, как MonetizationConfig.GamePasses: магазин на клиенте берёт отсюда список.
	Цена в Robux здесь НЕ хранится — её магазин запрашивает живьём (GetProductInfo).

	Выдачу делает ТОЛЬКО сервер в MonetizationSystem.ProcessReceipt по ProductId из квитанции
	Roblox; клиент лишь открывает окно покупки (PromptProductPurchase) и ничего серверу не
	докладывает. Размер награды берётся отсюда, не из квитанции.

	В S12 — только паки Эссенции. «Быстрое пробуждение», реролл мутаций, косметика и
	кокон-паки — отдельные сессии (новый Reward.Kind + ветка выдачи в MonetizationSystem).

	Ориентир цены в Robux (для заведения продукта в Creator Dashboard): S 49, M 149, L 349,
	XL 699 — объём за Robux растёт с размером пака. Баланс объёмов — economy-balancer;
	сейчас отсчёт от RebirthConfig.MinEssence = 10 000 (XL — чуть больше одного порога).
]]

local UpgradeEffects = require(script.Parent.Parent.UpgradeEffects)

export type RewardKind = "Essence"

export type DevProductReward = {
	Kind: RewardKind,
	Amount: number, -- для "Essence" — сколько начислить в Currency.Essence
}

export type DevProductDefinition = {
	Id: string, -- внутренний Id (логи, магазин)
	DisplayName: string,
	-- Числовой id дев-продукта Roblox. 0 = НЕ НАСТРОЕН: сервер такой продукт не выдаёт,
	-- магазин показывает его недоступным.
	ProductId: number,
	Reward: DevProductReward,
}

export type DevProductConfigDefinition = {
	Products: { DevProductDefinition }, -- порядок = порядок в магазине
	-- Сколько маркеров выдачи хранится в профиле (Monetization.ProcessedReceipts) — «выдача уже
	-- в профиле», записывается атомарно с самой выдачей. Вытесняются только закрытые логом
	-- маркеры, поэтому незакрытых может быть и больше.
	ProfileReceiptHistory: number,
}

local DevProductConfig: DevProductConfigDefinition = {
	Products = {
		{
			Id = "EssencePackS",
			DisplayName = "Пак Эссенции S",
			-- ЗАГЛУШКА. Перед публикацией заведите продукт в Creator Dashboard
			-- (Creations → игра → Monetization → Developer Products) и впишите его id.
			ProductId = 0,
			Reward = { Kind = "Essence", Amount = 1_000 },
		},
		{
			Id = "EssencePackM",
			DisplayName = "Пак Эссенции M",
			ProductId = 0, -- ЗАГЛУШКА, как у EssencePackS
			Reward = { Kind = "Essence", Amount = 3_500 },
		},
		{
			Id = "EssencePackL",
			DisplayName = "Пак Эссенции L",
			ProductId = 0, -- ЗАГЛУШКА
			Reward = { Kind = "Essence", Amount = 9_000 },
		},
		{
			Id = "EssencePackXL",
			DisplayName = "Пак Эссенции XL",
			ProductId = 0, -- ЗАГЛУШКА
			Reward = { Kind = "Essence", Amount = 20_000 },
		},
	},
	ProfileReceiptHistory = 50,
}

-- Проверки при загрузке: битая таблица должна ронять сервер при старте, а не выдавать
-- NaN/отрицательную Эссенцию за реальные Robux.
do
	local isFinite = UpgradeEffects.IsFinite
	local seenIds: { [string]: true } = {}
	local seenProductIds: { [number]: string } = {}
	for index, product in DevProductConfig.Products do
		assert(type(product.Id) == "string" and product.Id ~= "", `DevProductConfig: у продукта #{index} нет Id`)
		assert(not seenIds[product.Id], `DevProductConfig: Id {product.Id} повторяется`)
		seenIds[product.Id] = true
		assert(
			type(product.DisplayName) == "string" and product.DisplayName ~= "",
			`DevProductConfig: у {product.Id} нет DisplayName`
		)
		assert(
			isFinite(product.ProductId) and product.ProductId >= 0 and product.ProductId % 1 == 0,
			`DevProductConfig: у {product.Id} некорректный ProductId {product.ProductId}`
		)
		if product.ProductId ~= 0 then
			assert(
				not seenProductIds[product.ProductId],
				`DevProductConfig: ProductId {product.ProductId} у {product.Id} совпадает с {seenProductIds[product.ProductId]}`
			)
			seenProductIds[product.ProductId] = product.Id
		end
		local reward = product.Reward
		assert(type(reward) == "table", `DevProductConfig: у {product.Id} нет Reward`)
		assert(reward.Kind == "Essence", `DevProductConfig: у {product.Id} неизвестный Reward.Kind {reward.Kind}`)
		assert(
			isFinite(reward.Amount) and reward.Amount > 0,
			`DevProductConfig: у {product.Id} некорректный Reward.Amount {reward.Amount}`
		)
	end
	local history = DevProductConfig.ProfileReceiptHistory
	assert(
		isFinite(history) and history >= 1 and history % 1 == 0,
		"DevProductConfig: некорректный ProfileReceiptHistory"
	)
end

return DevProductConfig
