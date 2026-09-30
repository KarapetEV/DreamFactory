--!strict

--[[
	Временные платные баффы — дев-продукты MagnetBoost/SpeedBoost (DevProductConfig,
	Reward.Kind "Buff"). Не секрет — лежит в shared. Логика — BuffSystem.

	Выдаёт только сервер: BuffSystem.Grant из MonetizationSystem.ProcessReceipt (идемпотентность
	покупки — там же, маркером квитанции). Профиль хранит os.time() конца баффа
	(Buffs.MagnetBoostExpiresAt / Buffs.SpeedBoostExpiresAt) — по образцу PvP.ShieldExpiresAt:
	время идёт и офлайн, смена сервера бафф не сбрасывает.

	Стекинг: покупка при активном баффе продлевает его — ExpiresAt = max(ExpiresAt, now) + Duration;
	истёкший бафф начинается заново от now.

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
	Duration: number, -- секунд за одну покупку
	WalkSpeed: number?, -- только SpeedBoost: скорость персонажа под баффом
}

export type BuffConfigDefinition = {
	-- Скорость без баффа — должна совпадать с StarterPlayer.CharacterWalkSpeed (дефолт Roblox 16).
	BaseWalkSpeed: number,
	-- Как часто сервер применяет/снимает эффекты баффов (WalkSpeed, потолок MovementGuard), сек.
	TickInterval: number,
	Buffs: { [BuffId]: BuffDefinition },
	-- Порядок обхода (детерминированный, для проверок и тестов).
	BuffIds: { BuffId },
}

local BuffConfig: BuffConfigDefinition = {
	BaseWalkSpeed = 16,
	TickInterval = 0.25,
	Buffs = {
		MagnetBoost = { Duration = 20 },
		SpeedBoost = { Duration = 20, WalkSpeed = 32 },
	},
	BuffIds = { "MagnetBoost", "SpeedBoost" },
}

-- Проверки при загрузке: NaN/0 в длительности — бафф за Robux, который ничего не даёт или
-- не кончается; WalkSpeed ниже базовой — «бафф», замедляющий игрока.
do
	local isFinite = UpgradeEffects.IsFinite
	assert(
		isFinite(BuffConfig.BaseWalkSpeed) and BuffConfig.BaseWalkSpeed > 0,
		"BuffConfig: некорректный BaseWalkSpeed"
	)
	assert(
		isFinite(BuffConfig.TickInterval) and BuffConfig.TickInterval >= 0.1,
		"BuffConfig: некорректный TickInterval"
	)
	local listed: { [string]: true } = {}
	for _, id in BuffConfig.BuffIds do
		assert(BuffConfig.Buffs[id], `BuffConfig: бафф {id} из BuffIds не описан`)
		listed[id] = true
	end
	for id, buff in BuffConfig.Buffs :: { [string]: BuffDefinition } do
		assert(listed[id], `BuffConfig: бафф {id} отсутствует в BuffIds`)
		assert(isFinite(buff.Duration) and buff.Duration >= 1, `BuffConfig: у {id} некорректный Duration`)
	end
	local speed = BuffConfig.Buffs.SpeedBoost.WalkSpeed
	assert(
		isFinite(speed) and (speed :: number) > BuffConfig.BaseWalkSpeed,
		"BuffConfig: WalkSpeed у SpeedBoost должен быть выше BaseWalkSpeed"
	)
	assert(BuffConfig.Buffs.MagnetBoost.WalkSpeed == nil, "BuffConfig: WalkSpeed только у SpeedBoost")
end

return BuffConfig
