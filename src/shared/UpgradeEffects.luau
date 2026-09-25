--!strict

--[[
	UpgradeEffects — расчёт значения эффекта апгрейда по уровню из UpgradeConfig.
	Чистые функции без обращений к Instance; используются сервером (FactorySystem,
	CollectionSystem), клиент может брать их для отображения.

	Уровень из профиля не доверяется слепо: для расчёта эффекта он приводится к целому
	в [0, MaxLevel], поэтому даже испорченный профиль не даёт эффекта сверх последней
	ступени (M-1). Покупка же требует строго корректного уровня — IsValidLevel.
]]

local UpgradeConfig = require(script.Parent.Config.UpgradeConfig)

type UpgradeTrack = UpgradeConfig.UpgradeTrack

local UpgradeEffects = {}

-- number, не NaN и не ±inf.
function UpgradeEffects.IsFinite(value: unknown): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local isFinite = UpgradeEffects.IsFinite

for key, track in UpgradeConfig do
	assert(track.Id == key, `UpgradeConfig: ключ {key} не совпадает с Id {track.Id}`)
	assert(
		track.MaxLevel >= 0 and track.MaxLevel % 1 == 0 and track.MaxLevel == #track.Levels,
		`UpgradeConfig: у {key} MaxLevel {track.MaxLevel} не совпадает с числом уровней {#track.Levels}`
	)
	assert(isFinite(track.BaseValue) and track.BaseValue > 0, `UpgradeConfig: у {key} некорректный BaseValue`)
	for level, step in track.Levels do
		assert(isFinite(step.Price) and step.Price > 0, `UpgradeConfig: у {key} уровня {level} некорректная цена`)
		assert(isFinite(step.Value) and step.Value > 0, `UpgradeConfig: у {key} уровня {level} некорректное значение`)
	end
end

function UpgradeEffects.GetTrack(upgradeId: string): UpgradeTrack?
	return UpgradeConfig[upgradeId]
end

local function getTrackOrError(effectType: string): UpgradeTrack
	return assert(UpgradeConfig[effectType], `UpgradeEffects: неизвестный тип апгрейда {effectType}`)
end

-- Сохранённый уровень корректен: целое число в [0, MaxLevel].
function UpgradeEffects.IsValidLevel(effectType: string, level: unknown): boolean
	local track = getTrackOrError(effectType)
	return isFinite(level) and (level :: number) % 1 == 0 and (level :: number) >= 0 and (level :: number) <= track.MaxLevel
end

-- Уровень для расчёта эффекта: не-число/NaN → 0, иначе округление вниз и зажим в [0, MaxLevel].
function UpgradeEffects.ClampLevel(effectType: string, level: unknown): number
	local track = getTrackOrError(effectType)
	if type(level) ~= "number" or level ~= level then
		return 0
	end
	return math.clamp(math.floor(level), 0, track.MaxLevel)
end

-- Значение эффекта на уровне level (после ClampLevel): BaseValue для 0, иначе Levels[level].Value.
function UpgradeEffects.GetEffectValue(effectType: string, level: unknown): number
	local track = getTrackOrError(effectType)
	local clamped = UpgradeEffects.ClampLevel(effectType, level)
	return if clamped == 0 then track.BaseValue else track.Levels[clamped].Value
end

return UpgradeEffects
