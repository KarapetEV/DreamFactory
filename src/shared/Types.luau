--!strict

-- Эмоциональный окрас (GDD раздел 3): у видов петов (PetSpeciesConfig) и у фрагментов снов.
export type EmotionType = "Joyful" | "Nostalgic" | "Fearful"

-- Буфер сырых фрагментов по эмоциям (Factory.RawFragments). Сумма по типам ≤ ёмкости склада
-- (апгрейд StorageCapacity). Сумма и проверки — FragmentBuffer.
export type FragmentBuffer = {
	Joyful: number,
	Nostalgic: number,
	Fearful: number,
}

-- Экземпляр пета в профиле (раздел 4 ТЗ). Создаёт только PetSystem.HatchCocoon.
export type PetRecord = {
	Id: string, -- уникальный GUID экземпляра
	SpeciesId: string,
	Rarity: string,
	Mutation: string?,
	Level: number,
	Equipped: boolean,
}

-- Маркер выдачи дев-продукта в профиле. Closed = квитанция уже закрыта в логе PurchaseLog.
export type ReceiptMarker = {
	Id: string, -- PurchaseId квитанции Roblox
	Closed: boolean,
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
		-- Буфер «сырых» фрагментов снов по эмоциям (наполняет CollectionSystem, разбирает FactorySystem).
		RawFragments: FragmentBuffer,
		ConveyorSpeedLevel: number,
		Decor: { string },
	},
	Collection: {
		RadiusLevel: number,
		SpeedLevel: number,
		-- Владение авто-коллектором — Monetization.GamePassesOwned (AutoCollectorConfig.GamePassId).
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
		-- Кумулятивный лимит потерь (PvPConfig.MaxStolenPerTargetWindow): украдено всеми
		-- атакующими в текущем окне и os.time() начала окна (nil — окна ещё не было).
		StolenInWindow: number,
		StolenWindowStartsAt: number?,
		-- Баланс цели на старте текущего окна (база относительного лимита
		-- PvPConfig.MaxStolenPercentPerTargetWindow); перезаписывается при каждой ротации окна.
		EssenceAtWindowStart: number,
	},
	Monetization: {
		GamePassesOwned: { string },
		-- Маркеры выданных дев-продуктов (MonetizationSystem.ProcessReceipt): «выдача уже в
		-- профиле», пишутся одной записью с самой выдачей. Закрытых сверх
		-- DevProductConfig.ProfileReceiptHistory вытесняются старейшие; незакрытые — никогда.
		ProcessedReceipts: { ReceiptMarker },
		-- Сезонный пропуск (BattlePassSystem, BattlePassConfig). SeasonId ≠ BattlePassConfig.SeasonId
		-- (в т.ч. nil — сезона ещё не было) — прогресс сбрасывается при первом начислении XP.
		BattlePassSeasonId: string?,
		BattlePassTier: number, -- 0..MaxTier, достигнутый тир
		BattlePassXP: number, -- XP внутри текущего тира (0 на MaxTier)
		BattlePassPremium: boolean, -- премиум-ветка куплена в сезоне BattlePassSeasonId
	},
	Meta: {
		FirstJoinAt: number,
		LastLoginAt: number,
		SchemaVersion: number,
		-- Воронка первых 10 минут (AnalyticsSystem.RecordFunnelStep): os.time() первого события
		-- каждого вида; nil — ещё не было. Заполненное поле — шаг уже залогирован.
		FirstCollectAt: number?,
		FirstProcessAt: number?,
		FirstUpgradeAt: number?,
		FirstPetAt: number?,
	},
}

-- Снимок экономики, который сервер шлёт владельцу через Remotes.EconomySnapshot (HUD, раздел 5.8).
-- Только данные самого игрока. Цены и значения эффектов клиент берёт из UpgradeConfig/UpgradeEffects.
export type EconomySnapshot = {
	Essence: number,
	-- Буфер сырых фрагментов — СУММА по эмоциям Factory.RawFragments. Ёмкость клиент считает
	-- сам из Levels.StorageCapacity через UpgradeEffects.
	RawFragments: number,
	-- Тот же буфер с разбивкой по эмоциям (визуал: цвета фрагментов на ленте фабрики).
	-- Битый буфер — нули по всем эмоциям (RawFragments в этом случае тоже 0).
	RawFragmentsByEmotion: FragmentBuffer,
	-- Текущий уровень по id апгрейда (ключи UpgradeConfig).
	Levels: { [string]: number },
	-- Id апгрейда, если снимок — ответ сервера на PurchaseUpgrade (успешный или отклонённый).
	PurchaseAck: string?,
	-- Прогресс rebirth (раздел 5.4): для кнопки Rebirth и прогресс-бара (раздел 5.8).
	-- Порог клиент берёт из RebirthConfig, сам rebirth решает только сервер.
	RebirthCount: number,
	ClarityMultiplier: number,
	CurrentBiome: string,
	-- Ответ на PerformRebirth: true — rebirth выполнен, false — отклонён; nil — не ответ на rebirth.
	RebirthAck: boolean?,
	-- Id геймпассов из MonetizationConfig, которыми владеет игрок (кэш серверной проверки Roblox).
	GamePassesOwned: { string },
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
	-- Публикуемый текст шансов редкости по каждому кокону (раздел 5.7 ТЗ, GDD раздел 12):
	-- ключ — CocoonConfig.Id, значение — OddsText.Format от server-only PetRarityConfig.
	-- Присутствует только когда есть Pets (полный снимок); статичен, PetInventoryUI кэширует.
	CocoonOdds: { [string]: string }?,
}

-- Итог ивента Хаос-босса для конкретного игрока (поле ChaosSnapshot.Ended).
export type ChaosEventResult = {
	EventId: number,
	Outcome: "Victory" | "Timeout",
	Damage: number, -- вклад игрока в завершённом ивенте (0 — не участвовал)
	Reward: number, -- выданная Essence (0 — не участвовал)
}

-- Состояние Хаоса, которое сервер шлёт каждому игроку через Remotes.ChaosSnapshot
-- (раздел 5.5/5.8). Всё, кроме Contribution/Ended, общее для сервера; Contribution и
-- Ended — только самого получателя.
export type ChaosSnapshot = {
	ChaosLevel: number,
	ActivationThreshold: number,
	-- Порог достигнут, идёт телеграф появления босса (ChaosBossConfig.SpawnTelegraphDuration);
	-- Active ещё false. Клиент показывает партиклы в BossPosition и затемняет небо.
	Incoming: boolean,
	Active: boolean,
	BossHealth: number,
	BossMaxHealth: number,
	EventId: number, -- номер текущего/последнего ивента (0 — ещё не было)
	Contribution: number, -- урон получателя в текущем ивенте
	-- Только в снимке завершения ивента: итог для получателя.
	Ended: ChaosEventResult?,
}

return {}
