--!strict

--[[
	Авто-сборщик (геймпасс): сервер сам собирает фрагменты в радиусе сбора владельца, без
	RequestCollect от клиента. Не секрет — лежит в shared. Логика — CollectionSystem.

	Владение — только Monetization.GamePassesOwned (пишет MonetizationSystem по ответу Roblox).
	Радиус — тот же, что у ручного сбора (апгрейд CollectionRadius × Nostalgic-петы).

	TickInterval = 1.5 с (заглушка для economy-balancer). Пассивный сбор идёт через ту же
	транзакцию, что и ручной, с общим кулдауном — за тик собирается не больше одного фрагмента.
	Итого ~0.67 фрагмента/с «на автомате» против ~3.3/с при активном ручном сборе
	(кулдаун CollectionSpeed 0.3 с): геймпасс — удобство и AFK-доход, а не множитель поверх
	активной игры; ручной сбор + авто вместе всё равно упираются в тот же кулдаун.
	Чаще 1 с — лишняя работа сервера на каждого владельца и слишком «пылесосная» зона
	(фрагментов в зоне всего MaxFragments); реже 2 с — геймпасс ощущается бесполезным.
]]

local MonetizationConfig = require(script.Parent.MonetizationConfig)
local UpgradeEffects = require(script.Parent.Parent.UpgradeEffects)

export type AutoCollectorDefinition = {
	GamePassId: string, -- Id записи в MonetizationConfig.GamePasses (и в GamePassesOwned)
	TickInterval: number, -- секунд между тиками пассивного сбора
}

local AutoCollectorConfig: AutoCollectorDefinition = {
	GamePassId = "AutoCollector",
	TickInterval = 1.5,
}

-- Проверки при загрузке: опечатка в Id тихо отключила бы геймпасс, а 0/NaN в интервале
-- превратили бы тик в busy-loop.
do
	local found = false
	for _, pass in MonetizationConfig.GamePasses do
		if pass.Id == AutoCollectorConfig.GamePassId then
			found = true
			break
		end
	end
	assert(
		found,
		`AutoCollectorConfig: геймпасс {AutoCollectorConfig.GamePassId} отсутствует в MonetizationConfig`
	)
	assert(
		UpgradeEffects.IsFinite(AutoCollectorConfig.TickInterval) and AutoCollectorConfig.TickInterval >= 0.25,
		`AutoCollectorConfig: некорректный TickInterval {AutoCollectorConfig.TickInterval}`
	)
end

return AutoCollectorConfig
