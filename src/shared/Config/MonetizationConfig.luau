--!strict

--[[
	Монетизация (раздел 5.7 ТЗ). Не секрет — лежит в shared: магазин на клиенте берёт отсюда
	список геймпассов. Цена в Robux здесь НЕ хранится: её магазин каждый раз запрашивает живьём
	(MarketplaceService:GetProductInfo), чтобы в UI не разошлись цифры при смене цены.

	Владение геймпассом сервер перечитывает у Roblox (UserOwnsGamePassAsync) и кэширует в профиль
	(Monetization.GamePassesOwned хранит Id из этой таблицы, не числовой GamePassId).

	Дев-продукты и сезонный пропуск (ProcessReceipt, идемпотентность) — S12, здесь их нет.
]]

local UpgradeEffects = require(script.Parent.Parent.UpgradeEffects)

export type GamePassDefinition = {
	Id: string, -- Id в профиле и в игровой логике (например PetConfig.ExtraSlotsGamePassId)
	DisplayName: string,
	-- Числовой id геймпасса Roblox. 0 = НЕ НАСТРОЕН: сервер такой геймпасс не проверяет
	-- (владение остаётся тем, что в профиле), магазин показывает его недоступным.
	GamePassId: number,
}

export type MonetizationDefinition = {
	GamePasses: { GamePassDefinition }, -- порядок = порядок в магазине
	-- После PromptGamePassPurchaseFinished(wasPurchased = true) владение Roblox иногда отдаёт
	-- с задержкой: перепроверяем до PurchaseRecheckAttempts раз с паузой PurchaseRecheckDelay секунд.
	PurchaseRecheckAttempts: number,
	PurchaseRecheckDelay: number,
}

local MonetizationConfig: MonetizationDefinition = {
	GamePasses = {
		{
			Id = "ExtraPetSlots",
			DisplayName = "Доп. слоты петов (+3)",
			-- ЗАГЛУШКА. Перед публикацией заведите геймпасс в Creator Dashboard
			-- (Creations → игра → Monetization → Passes) и впишите сюда его настоящий id.
			GamePassId = 0,
		},
	},
	PurchaseRecheckAttempts = 3,
	PurchaseRecheckDelay = 2,
}

-- Проверки при загрузке: битая таблица не должна тихо отключать проверку владения.
do
	local isFinite = UpgradeEffects.IsFinite
	local seenIds: { [string]: true } = {}
	local seenGamePassIds: { [number]: string } = {}
	for index, pass in MonetizationConfig.GamePasses do
		assert(type(pass.Id) == "string" and pass.Id ~= "", `MonetizationConfig: у геймпасса #{index} нет Id`)
		assert(not seenIds[pass.Id], `MonetizationConfig: Id {pass.Id} повторяется`)
		seenIds[pass.Id] = true
		assert(
			type(pass.DisplayName) == "string" and pass.DisplayName ~= "",
			`MonetizationConfig: у {pass.Id} нет DisplayName`
		)
		assert(
			isFinite(pass.GamePassId) and pass.GamePassId >= 0 and pass.GamePassId % 1 == 0,
			`MonetizationConfig: у {pass.Id} некорректный GamePassId {pass.GamePassId}`
		)
		if pass.GamePassId ~= 0 then
			assert(
				not seenGamePassIds[pass.GamePassId],
				`MonetizationConfig: GamePassId {pass.GamePassId} у {pass.Id} совпадает с {seenGamePassIds[pass.GamePassId]}`
			)
			seenGamePassIds[pass.GamePassId] = pass.Id
		end
	end
	assert(
		isFinite(MonetizationConfig.PurchaseRecheckAttempts)
			and MonetizationConfig.PurchaseRecheckAttempts >= 1
			and MonetizationConfig.PurchaseRecheckAttempts % 1 == 0,
		"MonetizationConfig: некорректный PurchaseRecheckAttempts"
	)
	assert(
		isFinite(MonetizationConfig.PurchaseRecheckDelay) and MonetizationConfig.PurchaseRecheckDelay >= 0,
		"MonetizationConfig: некорректный PurchaseRecheckDelay"
	)
end

return MonetizationConfig
