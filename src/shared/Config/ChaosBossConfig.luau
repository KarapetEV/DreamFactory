--!strict

--[[
	Хаос-босс (раздел 5.5 ТЗ, раздел 5.5 GDD). Не секрет — лежит в shared: порог шкалы и
	HP босса понадобятся клиенту для индикатора Хаоса и ChaosEventUI (S14). Логика —
	ChaosBossSystem; всё, что влияет на исход (урон, дистанция, кулдаун, награда), сервер
	берёт только отсюда.

	Шкала ServerChaosLevel (общая на сервер, живёт только в памяти процесса):
	- каждое событие FactorySystem.OnEssenceProduced с emotionType == "Fearful":
	    level = min(level + FearfulGainPerEvent, ActivationThreshold);
	- каждое с "Joyful":
	    level = max(level - JoyfulDecayPerEvent, 0);
	- Nostalgic не влияет; во время боя события не меняют шкалу;
	- level ≥ ActivationThreshold → старт ивента, по завершении level = 0.
	Счёт — по событию (циклу конвейера), а не по amount: amount умножен на
	ClarityMultiplier, и игрок с большим числом rebirth иначе в одиночку «заливал» бы шкалу.

	Награда (бонус к Currency.Essence, только тем, кто на сервере в момент завершения):
	    reward = damageDealt × RewardEssencePerDamage × (VictoryRewardMultiplier при победе, иначе 1).
	Сумма damageDealt всех игроков ≤ BossMaxHealth (добивающий удар урезается до остатка HP),
	поэтому общая выдача за ивент ограничена сверху.

	Каркас: заглушечные значения. Реальный баланс считает economy-balancer.
]]

local UpgradeEffects = require(script.Parent.Parent.UpgradeEffects)

export type ChaosBossDefinition = {
	-- Шкала
	ActivationThreshold: number,
	FearfulGainPerEvent: number,
	JoyfulDecayPerEvent: number, -- «немного»: строго меньше FearfulGainPerEvent
	-- Бой
	BossMaxHealth: number,
	EventDuration: number, -- секунд до таймаута ивента
	DamagePerHit: number, -- урон одного RequestAttackBoss (клиент урон не присылает)
	AttackCooldown: number, -- секунд между засчитанными ударами одного игрока
	AttackRange: number, -- studs от корня персонажа до центра босса
	DistanceTolerance: number, -- запас на лаг между позицией клиента и сервера
	-- Rate limiting: не больше MaxRequestsPerWindow вызовов RequestAttackBoss за RequestWindow секунд.
	RequestWindow: number,
	MaxRequestsPerWindow: number,
	-- Сколько отклонённых запросов в окне считается подозрительной активностью (пишется в лог).
	SuspiciousRejectThreshold: number,
	-- Награда
	RewardEssencePerDamage: number,
	VictoryRewardMultiplier: number,
	-- Плейсхолдер геометрии (реальный ассет — отдельная сессия).
	BossPosition: Vector3,
	BossSize: Vector3,
}

local ChaosBossConfig: ChaosBossDefinition = {
	ActivationThreshold = 500,
	FearfulGainPerEvent = 1,
	JoyfulDecayPerEvent = 0.25,

	BossMaxHealth = 1000,
	EventDuration = 180,
	DamagePerHit = 10,
	AttackCooldown = 0.5,
	AttackRange = 25,
	DistanceTolerance = 4,
	RequestWindow = 1,
	MaxRequestsPerWindow = 10,
	SuspiciousRejectThreshold = 30,

	RewardEssencePerDamage = 1,
	VictoryRewardMultiplier = 1.5,

	BossPosition = Vector3.new(0, 10, -60),
	BossSize = Vector3.new(12, 16, 12),
}

-- Проверки при загрузке: 0/NaN в пороге или уроне делают ивент недостижимым или вечным,
-- нулевой кулдаун снимает защиту от двойной доставки удара — такой конфиг роняет старт сервера.
do
	local c = ChaosBossConfig
	local isFinite = UpgradeEffects.IsFinite

	local function positive(name: string, value: number)
		assert(isFinite(value) and value > 0, `ChaosBossConfig: {name} должен быть > 0, получено {value}`)
	end
	local function nonNegative(name: string, value: number)
		assert(isFinite(value) and value >= 0, `ChaosBossConfig: {name} должен быть ≥ 0, получено {value}`)
	end

	positive("ActivationThreshold", c.ActivationThreshold)
	positive("FearfulGainPerEvent", c.FearfulGainPerEvent)
	nonNegative("JoyfulDecayPerEvent", c.JoyfulDecayPerEvent)
	assert(
		c.JoyfulDecayPerEvent < c.FearfulGainPerEvent,
		"ChaosBossConfig: JoyfulDecayPerEvent должен быть меньше FearfulGainPerEvent (Joyful лишь замедляет Хаос)"
	)
	positive("BossMaxHealth", c.BossMaxHealth)
	positive("EventDuration", c.EventDuration)
	positive("DamagePerHit", c.DamagePerHit)
	positive("AttackCooldown", c.AttackCooldown)
	positive("AttackRange", c.AttackRange)
	nonNegative("DistanceTolerance", c.DistanceTolerance)
	positive("RequestWindow", c.RequestWindow)
	assert(
		isFinite(c.MaxRequestsPerWindow) and c.MaxRequestsPerWindow >= 1 and c.MaxRequestsPerWindow % 1 == 0,
		"ChaosBossConfig: некорректный MaxRequestsPerWindow"
	)
	positive("SuspiciousRejectThreshold", c.SuspiciousRejectThreshold)
	nonNegative("RewardEssencePerDamage", c.RewardEssencePerDamage)
	assert(
		isFinite(c.VictoryRewardMultiplier) and c.VictoryRewardMultiplier >= 1,
		"ChaosBossConfig: VictoryRewardMultiplier должен быть ≥ 1 (победа не хуже таймаута)"
	)
end

return ChaosBossConfig
