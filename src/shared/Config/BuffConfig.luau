--!strict

--[[
	Временные платные баффы — дев-продукты MagnetBoost/SpeedBoost (DevProductConfig,
	Reward.Kind "Buff"). Не секрет — лежит в shared. Логика — BuffSystem.

	Модель зарядов: покупка не включает бафф, а даёт пак из PackSize зарядов; игрок сам тратит
	заряд кликом по иконке баффа в HUD (Remotes.ActivateBuff), и бафф действует Duration секунд.
	- Начисляет только сервер: BuffSystem.Grant из MonetizationSystem.ProcessReceipt
	  (идемпотентность покупки — там же, маркером квитанции). Заряды зажимаются в [0, MaxCharges]:
	  избыток сверх потолка сгорает, квитанция всё равно считается обработанной (магазин
	  предупреждает об этом до покупки).
	- Активация — BuffSystem.Activate: только если заряд есть и бафф сейчас не действует
	  (во время действия повторный клик ничего не тратит). Профиль хранит число зарядов
	  (Buffs.<Id>Charges) и os.time() конца действия (Buffs.<Id>ExpiresAt) — по образцу
	  PvP.ShieldExpiresAt: время идёт и офлайн, смена сервера бафф не сбрасывает.

	- MagnetBoost — магнит сбора на Duration секунд: тот же, что у геймпасса Авто-сборщика
	  (AutoCollectorConfig.Radius × Nostalgic-петы, тик AutoCollectorConfig.TickInterval).
	  Владельцу геймпасса ничего не добавляет.
	- SpeedBoost — Humanoid.WalkSpeed = WalkSpeed вместо BaseWalkSpeed на Duration секунд.
	  MovementGuard на время баффа поднимает потолки скорости в WalkSpeed / BaseWalkSpeed раз
	  (не больше server-only MovementGuardConfig.MaxSpeedMultiplier — проверяется при старте
	  BuffSystem).

	Значения — заглушки для economy-balancer. WalkSpeed 32 = ×2 от дефолта Roblox: заметно
	быстрее, но в пределах типичных «спид-бустов» симуляторов.
]]

local UpgradeEffects = require(script.Parent.Parent.UpgradeEffects)

export type BuffId = "MagnetBoost" | "SpeedBoost"

export type BuffDefinition = {
	Duration: number, -- секунд действия одной активации (одного заряда)
	PackSize: number, -- зарядов за одну покупку дев-продукта
	MaxCharges: number, -- потолок хранимых зарядов; избыток при начислении сгорает
	WalkSpeed: number?, -- только SpeedBoost: скорость персонажа под баффом
}

export type BuffConfigDefinition = {
	-- Скорость без баффа — должна совпадать с StarterPlayer.CharacterWalkSpeed (дефолт Roblox 16).
	BaseWalkSpeed: number,
	-- Как часто сервер применяет/снимает эффекты баффов (WalkSpeed, потолок MovementGuard), сек.
	TickInterval: number,
	-- Rate limit Remotes.ActivateBuff: не больше MaxActivateRequestsPerWindow вызовов за
	-- ActivateRequestWindow секунд (тот же RateLimiter, что у RequestCollect).
	ActivateRequestWindow: number,
	MaxActivateRequestsPerWindow: number,
	Buffs: { [BuffId]: BuffDefinition },
	-- Порядок обхода (детерминированный, для проверок, тестов и порядка иконок в HUD).
	BuffIds: { BuffId },
}

local BuffConfig: BuffConfigDefinition = {
	BaseWalkSpeed = 16,
	TickInterval = 0.25,
	ActivateRequestWindow = 1,
	MaxActivateRequestsPerWindow = 4,
	Buffs = {
		MagnetBoost = { Duration = 60, PackSize = 5, MaxCharges = 20 },
		SpeedBoost = { Duration = 60, PackSize = 5, MaxCharges = 20, WalkSpeed = 32 },
	},
	BuffIds = { "MagnetBoost", "SpeedBoost" },
}

-- Проверки при загрузке: NaN/0 в длительности — бафф за Robux, который ничего не даёт или
-- не кончается; пак больше потолка — покупка, часть которой сгорает всегда; WalkSpeed ниже
-- базовой — «бафф», замедляющий игрока.
do
	local isFinite = UpgradeEffects.IsFinite
	local function isCount(value: unknown): boolean
		return isFinite(value) and (value :: number) >= 1 and (value :: number) % 1 == 0
	end
	assert(
		isFinite(BuffConfig.BaseWalkSpeed) and BuffConfig.BaseWalkSpeed > 0,
		"BuffConfig: некорректный BaseWalkSpeed"
	)
	assert(
		isFinite(BuffConfig.TickInterval) and BuffConfig.TickInterval >= 0.1,
		"BuffConfig: некорректный TickInterval"
	)
	assert(
		isFinite(BuffConfig.ActivateRequestWindow) and BuffConfig.ActivateRequestWindow > 0,
		"BuffConfig: некорректный ActivateRequestWindow"
	)
	assert(isCount(BuffConfig.MaxActivateRequestsPerWindow), "BuffConfig: некорректный MaxActivateRequestsPerWindow")
	local listed: { [string]: true } = {}
	for _, id in BuffConfig.BuffIds do
		assert(BuffConfig.Buffs[id], `BuffConfig: бафф {id} из BuffIds не описан`)
		listed[id] = true
	end
	for id, buff in BuffConfig.Buffs :: { [string]: BuffDefinition } do
		assert(listed[id], `BuffConfig: бафф {id} отсутствует в BuffIds`)
		assert(isFinite(buff.Duration) and buff.Duration >= 1, `BuffConfig: у {id} некорректный Duration`)
		assert(isCount(buff.PackSize), `BuffConfig: у {id} некорректный PackSize`)
		assert(isCount(buff.MaxCharges), `BuffConfig: у {id} некорректный MaxCharges`)
		assert(buff.PackSize <= buff.MaxCharges, `BuffConfig: у {id} PackSize больше MaxCharges`)
	end
	local speed = BuffConfig.Buffs.SpeedBoost.WalkSpeed
	assert(
		isFinite(speed) and (speed :: number) > BuffConfig.BaseWalkSpeed,
		"BuffConfig: WalkSpeed у SpeedBoost должен быть выше BaseWalkSpeed"
	)
	assert(BuffConfig.Buffs.MagnetBoost.WalkSpeed == nil, "BuffConfig: WalkSpeed только у SpeedBoost")
end

return BuffConfig
