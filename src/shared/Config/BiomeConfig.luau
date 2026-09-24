--!strict

-- Каркас конфига: структура + заглушечные значения. Реальный баланс считает economy-balancer.

export type BiomeDefinition = {
	Id: string,
	DisplayName: string,
	RebirthThreshold: number,
	ClarityMultiplierBonus: number,
}

local BiomeConfig: { [string]: BiomeDefinition } = {
	DreamMeadow = {
		Id = "DreamMeadow",
		DisplayName = "Сонный луг",
		RebirthThreshold = 0,
		ClarityMultiplierBonus = 0,
	},
	Nightmares = {
		Id = "Nightmares",
		DisplayName = "Кошмары",
		RebirthThreshold = 5,
		ClarityMultiplierBonus = 0.5,
	},
}

return BiomeConfig
