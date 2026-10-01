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

	TickInterval = 0.25 с (плейтест S22: при 1.5 с магнит «не срабатывал» — игрок успевал
	пробежать мимо фрагмента или коснуться его раньше тика, и сбор шёл касанием). Пассивный
	сбор идёт через ту же транзакцию, что и ручной, с общим кулдауном — за тик не больше одного
	фрагмента, и магнит + касание вместе не быстрее кулдауна CollectionSpeed (0.3 с, ~3.3/с).
	AFK-доход при этом ограничен не тиком, а спавном: зона даёт ~SpawnPerTick / SpawnInterval
	фрагментов в секунду (сейчас ~0.67/с) и держит не больше MaxFragments. Тик — лишь поиск
	ближайшего фрагмента по реестру у игроков с магнитом (десятки фрагментов), 4 раза в секунду.
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
	TickInterval = 0.25,
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
