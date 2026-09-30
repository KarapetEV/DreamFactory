--!strict

--[[
	Магнит сбора: сервер сам собирает фрагменты в радиусе магнита игрока, без RequestCollect
	от клиента. Не секрет — лежит в shared. Логика — CollectionSystem.

	Магнит есть у владельца геймпасса Авто-сборщика (Monetization.GamePassesOwned, пишет
	MonetizationSystem по ответу Roblox) и у игрока с активным баффом Magnet Boost
	(Buffs.MagnetBoostExpiresAt, BuffSystem). У обоих один и тот же радиус:
	Radius × CollectionRadiusMultiplier надетых Nostalgic-петов. Апгрейд CollectionRadius снят
	с продажи и радиус не меняет. Тот же радиус — верхняя граница дистанции ручного сбора
	касанием (касание и так требует контакта; граница — анти-чит, а не механика).

	Radius = 12 studs (заглушка для economy-balancer; = бывший BaseValue апгрейда CollectionRadius).

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
	Radius: number, -- фиксированный радиус магнита, studs (до множителя Nostalgic-петов)
}

local AutoCollectorConfig: AutoCollectorDefinition = {
	GamePassId = "AutoCollector",
	TickInterval = 1.5,
	Radius = 12,
}

-- Проверки при загрузке: опечатка в Id тихо отключила бы геймпасс, 0/NaN в интервале
-- превратили бы тик в busy-loop, а NaN/inf в радиусе — магнит на всю карту.
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
	assert(
		UpgradeEffects.IsFinite(AutoCollectorConfig.Radius) and AutoCollectorConfig.Radius > 0,
		`AutoCollectorConfig: некорректный Radius {AutoCollectorConfig.Radius}`
	)
end

return AutoCollectorConfig
