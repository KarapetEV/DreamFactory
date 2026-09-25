--!strict

-- Каркас конфига: структура + заглушечные значения. Реальный баланс считает economy-balancer.
-- Задержка конвейера по уровням — в UpgradeConfig.ConveyorSpeed; здесь — всё, что от уровня не зависит.

export type FactoryDefinition = {
	-- Как часто сервер проверяет конвейеры всех игроков, секунд. Не больше минимальной
	-- задержки конвейера (иначе цикл не успевает за апгрейдом; проверяется при загрузке FactorySystem).
	TickInterval: number,
	FragmentsPerCycle: number, -- сколько сырых фрагментов перерабатывается за один цикл
	EssencePerFragment: number, -- Essence за фрагмент до множителя Rebirth.ClarityMultiplier
	-- Rate limiting PurchaseUpgrade: не больше MaxRequestsPerWindow вызовов за RequestWindow секунд.
	RequestWindow: number,
	MaxRequestsPerWindow: number,
	-- Сколько отклонённых PurchaseUpgrade в окне считается подозрительной активностью (пишется в лог).
	SuspiciousRejectThreshold: number,
	-- Как часто, не чаще, отправлять клиенту снимок при изменении только Essence/RawFragments, секунд.
	-- Смена уровней и ответ на покупку уходят сразу, без троттлинга.
	SnapshotInterval: number,
}

local FactoryConfig: FactoryDefinition = {
	TickInterval = 0.1,
	FragmentsPerCycle = 1,
	EssencePerFragment = 1,
	RequestWindow = 1,
	MaxRequestsPerWindow = 5,
	SuspiciousRejectThreshold = 15,
	SnapshotInterval = 0.5,
}

return FactoryConfig
