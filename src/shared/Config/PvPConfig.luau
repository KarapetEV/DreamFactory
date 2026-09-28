--!strict

--[[
	PvP «Вторжение в сон» (раздел 5.6 ТЗ/GDD). Не секрет — лежит в shared: клиенту понадобятся
	кулдауны/щит для UI. Логика — PvPRaidSystem; всё, что влияет на исход (сумма кражи,
	дистанция, щит, кулдауны), сервер берёт только отсюда и из GuardConfig (формула защиты).

	Область S17: рейд только на цель, которая сейчас на том же сервере (оба профиля
	session-locked здесь). Асинхронный рейд на офлайн-цель — отдельная будущая задача.

	Кража за один рейд:
	    base   = min(target.Currency.Essence × StealPercent, HardCap)
	    stolen = floor(base × (1 − защита цели))       -- защита — GuardConfig
	stolen = 0 → рейд отклоняется без изменения состояния.

	Кумулятивный лимит потерь цели (S19, GDD раздел 12 — «не допускать разорения»): за окно
	StolenWindowDuration у одной цели ВСЕ атакующие вместе уносят не больше
	MaxStolenPerTargetWindow. Остаток лимита урезает stolen (как HardCap); остатка нет —
	отказ. Окно — по os.time() в профиле цели (PvP.StolenInWindow / StolenWindowStartsAt),
	начинается первым рейдом после истечения предыдущего.

	Время:
	- ShieldDuration, RaidedGraceDuration — по os.time(): пишутся в профиль
	  (PvP.ShieldExpiresAt, PvP.LastRaidedAt) и переживают смену сервера;
	- AttackCooldownPerTarget — пара attacker→target, только в памяти сервера (os.clock).

	Каркас: заглушечные значения. Реальный баланс считает economy-balancer.
]]

local UpgradeEffects = require(script.Parent.Parent.UpgradeEffects)

export type PvPDefinition = {
	-- Доля Essence цели, которую можно унести за рейд (до защиты), (0, 1].
	StealPercent: number,
	-- Абсолютный потолок base за один рейд (до защиты).
	HardCap: number,
	-- Потолок суммы, украденной у одной цели всеми атакующими за StolenWindowDuration секунд.
	MaxStolenPerTargetWindow: number,
	StolenWindowDuration: number,
	-- Секунд, в течение которых один атакующий не может снова атаковать ту же цель.
	-- Другие цели этого атакующего и другие атакующие этой цели — не блокируются.
	AttackCooldownPerTarget: number,
	-- Щит при входе в игру: ShieldExpiresAt = max(текущий, now + ShieldDuration).
	ShieldDuration: number,
	-- Защита цели сразу после рейда (по PvP.LastRaidedAt) — от любого атакующего.
	RaidedGraceDuration: number,
	-- «Вход в рейд-инстанс»: корень персонажа атакующего не дальше RaidRange +
	-- DistanceTolerance studs от центра плейсхолдер-Part цели.
	RaidRange: number,
	DistanceTolerance: number,
	-- Плейсхолдер рейд-инстанса (реальный клон фабрики — отдельная сессия): Part на каждого
	-- игрока на сервере, i-й слот — RaidInstanceOrigin + (i − 1) × RaidInstanceSpacing по X.
	RaidInstanceOrigin: Vector3,
	RaidInstanceSpacing: number,
	RaidInstanceSize: Vector3,
	-- Rate limiting RequestRaidStart: не больше MaxRequestsPerWindow вызовов за RequestWindow секунд.
	RequestWindow: number,
	MaxRequestsPerWindow: number,
	-- Сколько отклонённых запросов в окне считается подозрительной активностью (пишется в лог).
	SuspiciousRejectThreshold: number,
}

local PvPConfig: PvPDefinition = {
	StealPercent = 0.15,
	HardCap = 5_000,
	MaxStolenPerTargetWindow = 12_000,
	StolenWindowDuration = 1_800,
	AttackCooldownPerTarget = 600,
	ShieldDuration = 300,
	RaidedGraceDuration = 120,

	RaidRange = 20,
	DistanceTolerance = 4,
	RaidInstanceOrigin = Vector3.new(300, 5, 0),
	RaidInstanceSpacing = 80,
	RaidInstanceSize = Vector3.new(16, 10, 16),

	RequestWindow = 1,
	MaxRequestsPerWindow = 2,
	SuspiciousRejectThreshold = 10,
}

-- Проверки при загрузке: StealPercent > 1 унёс бы больше, чем есть; 0/NaN в кулдауне или
-- grace снимают защиту от повторной кражи — такой конфиг роняет старт сервера.
do
	local c = PvPConfig
	local isFinite = UpgradeEffects.IsFinite

	local function positive(name: string, value: number)
		assert(isFinite(value) and value > 0, `PvPConfig: {name} должен быть > 0, получено {value}`)
	end

	assert(
		isFinite(c.StealPercent) and c.StealPercent > 0 and c.StealPercent <= 1,
		`PvPConfig: StealPercent должен быть в (0, 1], получено {c.StealPercent}`
	)
	positive("HardCap", c.HardCap)
	positive("MaxStolenPerTargetWindow", c.MaxStolenPerTargetWindow)
	positive("StolenWindowDuration", c.StolenWindowDuration)
	positive("AttackCooldownPerTarget", c.AttackCooldownPerTarget)
	positive("ShieldDuration", c.ShieldDuration)
	positive("RaidedGraceDuration", c.RaidedGraceDuration)
	positive("RaidRange", c.RaidRange)
	assert(
		isFinite(c.DistanceTolerance) and c.DistanceTolerance >= 0,
		`PvPConfig: DistanceTolerance должен быть ≥ 0, получено {c.DistanceTolerance}`
	)
	-- Соседние инстансы не должны перекрываться зонами входа: иначе стоя у одной цели
	-- атакующий «вошёл» бы и к соседней.
	assert(
		isFinite(c.RaidInstanceSpacing) and c.RaidInstanceSpacing > 2 * (c.RaidRange + c.DistanceTolerance),
		"PvPConfig: RaidInstanceSpacing должен быть больше 2 × (RaidRange + DistanceTolerance)"
	)
	positive("RequestWindow", c.RequestWindow)
	assert(
		isFinite(c.MaxRequestsPerWindow) and c.MaxRequestsPerWindow >= 1 and c.MaxRequestsPerWindow % 1 == 0,
		"PvPConfig: некорректный MaxRequestsPerWindow"
	)
	positive("SuspiciousRejectThreshold", c.SuspiciousRejectThreshold)
end

return PvPConfig
