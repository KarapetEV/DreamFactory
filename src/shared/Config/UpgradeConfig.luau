--!strict

-- Каркас конфига: структура + заглушечные значения. Реальный баланс считает economy-balancer.

export type UpgradeEffectType = "ConveyorSpeed" | "StorageCapacity" | "CollectionRadius" | "CollectionSpeed"

export type UpgradeDefinition = {
	Id: string,
	DisplayName: string,
	Price: number,
	EffectType: UpgradeEffectType,
	EffectValue: number,
}

local UpgradeConfig: { [string]: UpgradeDefinition } = {
	ConveyorSpeed1 = {
		Id = "ConveyorSpeed1",
		DisplayName = "Ускоренный конвейер I",
		Price = 100,
		EffectType = "ConveyorSpeed",
		EffectValue = 1.2,
	},
	StorageCapacity1 = {
		Id = "StorageCapacity1",
		DisplayName = "Склад I",
		Price = 150,
		EffectType = "StorageCapacity",
		EffectValue = 50,
	},
}

return UpgradeConfig
