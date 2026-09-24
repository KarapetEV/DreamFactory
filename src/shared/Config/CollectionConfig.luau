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
	BaseCollectRadius: number, -- studs
	RadiusPerLevel: number, -- прибавка к радиусу за Collection.RadiusLevel
	DistanceTolerance: number, -- запас на лаг между позицией клиента и сервера
	BaseCooldown: number, -- секунд между успешными сборами одного игрока
	CooldownReductionPerLevel: number, -- уменьшение за Collection.SpeedLevel
	MinCooldown: number,
	-- Rate limiting: не больше MaxRequestsPerWindow вызовов RequestCollect за RequestWindow секунд.
	RequestWindow: number,
	MaxRequestsPerWindow: number,
	-- Сколько отклонённых запросов в окне считается подозрительной активностью (пишется в лог).
	SuspiciousRejectThreshold: number,
	PromptText: string, -- подсказка над фрагментом (клиент показывает как есть)
	Zones: { ZoneDefinition },
}

local CollectionConfig: CollectionDefinition = {
	SpawnInterval = 3,
	SpawnPerTick = 2,
	FragmentValue = 1,
	BaseCollectRadius = 12,
	RadiusPerLevel = 2,
	DistanceTolerance = 4,
	BaseCooldown = 0.3,
	CooldownReductionPerLevel = 0.03,
	MinCooldown = 0.05,
	RequestWindow = 1,
	MaxRequestsPerWindow = 10,
	SuspiciousRejectThreshold = 30,
	PromptText = "Собрать",
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
	},
}

return CollectionConfig
