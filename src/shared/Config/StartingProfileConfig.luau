--!strict

-- Стартовые значения профиля нового игрока (DataSystem.BuildDefaultProfile).
-- Каркас: структура + заглушечные значения. Реальный баланс считает economy-balancer.
-- Уровни апгрейдов начинаются с 0 = «ничего не куплено» (первый апгрейд в UpgradeConfig — уровень 1).

export type StartingProfileDefinition = {
	Essence: number,
	FactoryLevel: number,
	StorageCapacity: number,
	ConveyorSpeedLevel: number,
	CollectionRadiusLevel: number,
	CollectionSpeedLevel: number,
	ClarityMultiplier: number,
	-- Должен существовать в BiomeConfig (проверяется при загрузке DataSystem).
	StartingBiomeId: string,
	BattlePassTier: number,
}

local StartingProfileConfig: StartingProfileDefinition = {
	Essence = 0,
	FactoryLevel = 1,
	StorageCapacity = 100,
	ConveyorSpeedLevel = 0,
	CollectionRadiusLevel = 0,
	CollectionSpeedLevel = 0,
	ClarityMultiplier = 1,
	StartingBiomeId = "DreamMeadow",
	BattlePassTier = 0,
}

return StartingProfileConfig
