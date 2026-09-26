--!strict

-- Rebirth (раздел 5.4 ТЗ). Каркас: заглушечные значения. Реальный баланс считает economy-balancer.
--
-- Порог — одна метрика: текущий баланс Currency.Essence. Essence при rebirth сбрасывается
-- к стартовому значению, поэтому следующий rebirth снова требует накопить порог.
-- Множитель и биом — не здесь, а в BiomeConfig (ClarityMultiplierBonus, RebirthThreshold).

export type RebirthDefinition = {
	-- Сколько Essence нужно иметь на балансе для rebirth (не списывается отдельно — весь
	-- баланс сбрасывается к StartingProfileConfig.Essence).
	MinEssence: number,
	-- Rate limiting PerformRebirth: не больше MaxRequestsPerWindow вызовов за RequestWindow секунд.
	RequestWindow: number,
	MaxRequestsPerWindow: number,
	-- Сколько отклонённых PerformRebirth в окне считается подозрительной активностью (пишется в лог).
	SuspiciousRejectThreshold: number,
}

local RebirthConfig: RebirthDefinition = {
	MinEssence = 10_000,
	RequestWindow = 1,
	MaxRequestsPerWindow = 2,
	SuspiciousRejectThreshold = 10,
}

return RebirthConfig
