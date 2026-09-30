--!strict

-- Каркас конфига: структура + заглушечные значения. Реальный баланс считает economy-balancer.
-- Зоны спавна — временные списки точек-заглушек; настоящие зоны появятся вместе с артом локаций.

export type ZoneDefinition = {
	Id: string,
	-- Должен существовать в BiomeConfig (проверяется при загрузке CollectionSystem).
	BiomeId: string,
	SpawnPoints: { Vector3 },
	MaxFragments: number,
}

export type CollectionDefinition = {
	SpawnInterval: number, -- секунд между тиками спавна (в каждой зоне за тик — не больше SpawnPerTick)
	SpawnPerTick: number,
	FragmentValue: number, -- сколько «сырых фрагментов» даёт один фрагмент снов
	-- Радиус сбора и кулдаун по уровням Collection.RadiusLevel/SpeedLevel — в UpgradeConfig
	-- (CollectionRadius/CollectionSpeed), с явным MaxLevel.
	DistanceTolerance: number, -- запас на лаг между позицией клиента и сервера
	-- Rate limiting: не больше MaxRequestsPerWindow вызовов RequestCollect за RequestWindow секунд.
	RequestWindow: number,
	MaxRequestsPerWindow: number,
	-- Сколько отклонённых запросов в окне считается подозрительной активностью (пишется в лог).
	SuspiciousRejectThreshold: number,
	Zones: { ZoneDefinition },
}

local CollectionConfig: CollectionDefinition = {
	SpawnInterval = 3,
	SpawnPerTick = 2,
	FragmentValue = 1,
	DistanceTolerance = 4,
	RequestWindow = 1,
	MaxRequestsPerWindow = 10,
	SuspiciousRejectThreshold = 30,
	Zones = {
		{
			Id = "DreamMeadowZone1",
			BiomeId = "DreamMeadow",
			SpawnPoints = {
				Vector3.new(0, 3, 20),
				Vector3.new(15, 3, 30),
				Vector3.new(-15, 3, 30),
				Vector3.new(25, 3, 10),
				Vector3.new(-25, 3, 10),
				Vector3.new(0, 3, 45),
			},
			MaxFragments = 5,
		},
		-- Смещена по Z на +100 относительно DreamMeadowZone1 — точки спавна не пересекаются.
		{
			Id = "NightmaresZone1",
			BiomeId = "Nightmares",
			SpawnPoints = {
				Vector3.new(0, 3, 120),
				Vector3.new(15, 3, 130),
				Vector3.new(-15, 3, 130),
				Vector3.new(25, 3, 110),
				Vector3.new(-25, 3, 110),
				Vector3.new(0, 3, 145),
			},
			MaxFragments = 5,
		},
		-- Смещена по Z на +200 относительно DreamMeadowZone1 — точки спавна не пересекаются.
		{
			Id = "LucidDreamsZone1",
			BiomeId = "LucidDreams",
			SpawnPoints = {
				Vector3.new(0, 3, 220),
				Vector3.new(15, 3, 230),
				Vector3.new(-15, 3, 230),
				Vector3.new(25, 3, 210),
				Vector3.new(-25, 3, 210),
				Vector3.new(0, 3, 245),
			},
			MaxFragments = 5,
		},
	},
}

return CollectionConfig
