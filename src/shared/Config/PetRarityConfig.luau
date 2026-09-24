--!strict

-- Каркас конфига: структура + заглушечные значения. Реальный баланс считает economy-balancer.
-- DropChance по всем редкостям одного кокона должен суммироваться в 1 — это единственный
-- источник правды и для серверного ролла (PetSystem.HatchCocoon), и для текста odds в UI.

export type PetRarityDefinition = {
	Id: string,
	DisplayName: string,
	DropChance: number,
}

local PetRarityConfig: { [string]: PetRarityDefinition } = {
	Common = {
		Id = "Common",
		DisplayName = "Обычный",
		DropChance = 0.7,
	},
	Rare = {
		Id = "Rare",
		DisplayName = "Редкий",
		DropChance = 0.25,
	},
	Legendary = {
		Id = "Legendary",
		DisplayName = "Легендарный",
		DropChance = 0.05,
	},
}

return PetRarityConfig
