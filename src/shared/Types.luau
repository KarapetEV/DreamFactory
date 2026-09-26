--!strict

-- Экземпляр пета в профиле (раздел 4 ТЗ). Создаёт только PetSystem.HatchCocoon.
export type PetRecord = {
	Id: string, -- уникальный GUID экземпляра
	SpeciesId: string,
	Rarity: string,
	Mutation: string?,
	Level: number,
	Equipped: boolean,
}

export type PlayerProfile = {
	Currency: {
		Essence: number,
	},
	Factory: {
		Level: number,
		-- Уровни апгрейдов (0..MaxLevel из UpgradeConfig). Ёмкость/скорость/радиус — не хранятся,
		-- сервер вычисляет их из уровня и конфига (UpgradeEffects).
		StorageCapacityLevel: number,
		-- Буфер «сырых» фрагментов снов (наполняет CollectionSystem, разбирает FactorySystem).
		RawFragments: number,
		ConveyorSpeedLevel: number,
		Decor: { string },
	},
	Collection: {
		RadiusLevel: number,
		SpeedLevel: number,
		AutoCollectorOwned: boolean,
	},
	Pets: { PetRecord },
	Rebirth: {
		Count: number,
		ClarityMultiplier: number,
		CurrentBiome: string,
	},
	Chaos: {
		PersonalContributionToday: number,
	},
	PvP: {
		ShieldExpiresAt: number?,
		LastRaidedAt: number?,
		GuardsPlaced: { string },
	},
	Monetization: {
		GamePassesOwned: { string },
		BattlePassSeasonId: string?,
		BattlePassTier: number,
	},
	Meta: {
		FirstJoinAt: number,
		LastLoginAt: number,
		SchemaVersion: number,
	},
}

-- Снимок экономики, который сервер шлёт владельцу через Remotes.EconomySnapshot (HUD, раздел 5.8).
-- Только данные самого игрока. Цены и значения эффектов клиент берёт из UpgradeConfig/UpgradeEffects.
export type EconomySnapshot = {
	Essence: number,
	-- Буфер сырых фрагментов (Factory.RawFragments). Ёмкость клиент считает сам из
	-- Levels.StorageCapacity через UpgradeEffects.
	RawFragments: number,
	-- Текущий уровень по id апгрейда (ключи UpgradeConfig).
	Levels: { [string]: number },
	-- Id апгрейда, если снимок — ответ сервера на PurchaseUpgrade (успешный или отклонённый).
	PurchaseAck: string?,
}

-- Снимок петов, который сервер шлёт владельцу через Remotes.PetSnapshot (раздел 5.3).
-- Только петы самого игрока; шансов в нём нет. Лимит слотов посчитан сервером.
export type PetSnapshot = {
	-- Все петы игрока. nil — ответ на отклонённый запрос: состав не изменился,
	-- клиент продолжает показывать последний полученный список.
	Pets: { PetRecord }?,
	EquipSlots: number,
	-- Имя ремоуты ("HatchCocoon" / "EquipPet" / "UnequipPet"), если снимок — ответ на запрос
	-- (успешный или отклонённый); nil — плановая отправка (загрузка профиля).
	Ack: string?,
	-- Id только что вылупившегося пета (ответ на успешный HatchCocoon).
	HatchedPetId: string?,
}

return {}
