--!strict

--[[
	FactorySystem — конвейер переработки и покупка апгрейдов (раздел 5.2 ТЗ, анти-чит — раздел 7;
	находки M-1/M-4 security-ревью персистентности).

	Конвейер:
	- серверный тик раз в FactoryConfig.TickInterval; у каждого игрока за цикл
	  FragmentsPerCycle сырых фрагментов (Factory.RawFragments) превращаются в Essence;
	- задержка цикла на каждом тике заново вычисляется из Factory.ConveyorSpeedLevel
	  и UpgradeConfig (не кэшируется) — апгрейд действует со следующего тика;
	- выход умножается на Rebirth.ClarityMultiplier (раздел 5.4) и перед записью
	  проверяется на конечность; после записи — событие OnEssenceProduced(player, amount).

	PurchaseUpgrade(upgradeId, targetLevel):
	- клиент присылает только намерение: id апгрейда и уровень, который хочет купить;
	  цену, значение эффекта и текущий уровень сервер берёт из UpgradeConfig и профиля;
	- покупается строго «текущий уровень + 1» и не выше MaxLevel — повторная доставка
	  того же запроса (двойной клик, ретрай) отклоняется, двойного списания нет;
	- все проверки и запись — одна функция без yield. Эффект применяется записью уровня:
	  ёмкость/скорость/радиус вычисляются из него на каждое обращение (UpgradeEffects).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.shared.Types)
local Remotes = require(ReplicatedStorage.shared.Remotes)
local Signal = require(ReplicatedStorage.shared.Signal)
local UpgradeEffects = require(ReplicatedStorage.shared.UpgradeEffects)
local UpgradeConfig = require(ReplicatedStorage.shared.Config.UpgradeConfig)
local FactoryConfig = require(ReplicatedStorage.shared.Config.FactoryConfig)
local DataSystem = require(script.Parent.DataSystem)
local RateLimiter = require(script.Parent.Parent.Services.RateLimiter)

type PlayerProfile = Types.PlayerProfile
type UpgradeEffectType = UpgradeConfig.UpgradeEffectType

type PlayerState = {
	RequestTimes: { number }, -- метки времени вызовов PurchaseUpgrade в текущем окне rate limit
	LastCycleAt: number, -- момент последнего цикла конвейера (или простоя с пустым буфером)
	Rejects: number,
	RejectWindowStart: number,
	CorruptionReported: boolean, -- предупреждение о битом профиле уже записано
	TickErrorReported: boolean, -- предупреждение об ошибке тика конвейера уже записано
}

local REJECT_LOG_WINDOW = 60

local isFinite = UpgradeEffects.IsFinite

do
	local conveyor = assert(UpgradeConfig.ConveyorSpeed, "FactorySystem: в UpgradeConfig нет ConveyorSpeed")
	local minDelay = conveyor.BaseValue
	for _, step in conveyor.Levels do
		minDelay = math.min(minDelay, step.Value)
	end
	assert(
		minDelay >= FactoryConfig.TickInterval,
		`FactorySystem: задержка конвейера {minDelay} меньше TickInterval {FactoryConfig.TickInterval}`
	)
end
assert(
	isFinite(FactoryConfig.FragmentsPerCycle) and FactoryConfig.FragmentsPerCycle > 0,
	"FactorySystem: некорректный FragmentsPerCycle"
)
assert(
	isFinite(FactoryConfig.EssencePerFragment) and FactoryConfig.EssencePerFragment > 0,
	"FactorySystem: некорректный EssencePerFragment"
)

local FactorySystem = {}

-- (player: Player, amount: number) — после каждого начисления Essence конвейером.
-- Подписчик — будущий ChaosBossSystem (раздел 5.5).
FactorySystem.OnEssenceProduced = Signal.new()

local playerStates: { [Player]: PlayerState } = {}

local function getPlayerState(player: Player): PlayerState
	local state = playerStates[player]
	if not state then
		state = {
			RequestTimes = {},
			LastCycleAt = os.clock(),
			Rejects = 0,
			RejectWindowStart = 0,
			CorruptionReported = false,
			TickErrorReported = false,
		}
		playerStates[player] = state
	end
	return state
end

-- Уровень апгрейда в профиле. Каждый тип из UpgradeConfig обязан быть здесь и в setLevel.
local function getLevel(data: PlayerProfile, effectType: UpgradeEffectType): number
	if effectType == "ConveyorSpeed" then
		return data.Factory.ConveyorSpeedLevel
	elseif effectType == "StorageCapacity" then
		return data.Factory.StorageCapacityLevel
	elseif effectType == "CollectionRadius" then
		return data.Collection.RadiusLevel
	elseif effectType == "CollectionSpeed" then
		return data.Collection.SpeedLevel
	end
	error(`FactorySystem: нет поля уровня для апгрейда {effectType}`)
end

local function setLevel(data: PlayerProfile, effectType: UpgradeEffectType, level: number)
	if effectType == "ConveyorSpeed" then
		data.Factory.ConveyorSpeedLevel = level
	elseif effectType == "StorageCapacity" then
		data.Factory.StorageCapacityLevel = level
	elseif effectType == "CollectionRadius" then
		data.Collection.RadiusLevel = level
	elseif effectType == "CollectionSpeed" then
		data.Collection.SpeedLevel = level
	else
		error(`FactorySystem: нет поля уровня для апгрейда {effectType}`)
	end
end

-- Каждый апгрейд из конфига должен иметь поле уровня в профиле — иначе падаем при загрузке, а не при покупке.
do
	local template = DataSystem.BuildDefaultProfile()
	for _, track in UpgradeConfig do
		getLevel(template, track.Id)
	end
end

-- Учёт отклонённых запросов. Достижение порога за окно — запись подозрительной активности
-- (раздел 7 ТЗ; внешний лог/DataStore подключится позже, пока warn).
local function registerReject(player: Player, reason: string, now: number)
	local state = getPlayerState(player)
	if now - state.RejectWindowStart > REJECT_LOG_WINDOW then
		state.RejectWindowStart = now
		state.Rejects = 0
	end

	state.Rejects += 1
	if state.Rejects == FactoryConfig.SuspiciousRejectThreshold then
		warn(
			`[FactorySystem] Подозрительная активность: {player.Name} ({player.UserId}), `
				.. `{state.Rejects} отклонённых PurchaseUpgrade за {REJECT_LOG_WINDOW} с, последняя причина: {reason}`
		)
	end
end

-- Битые числа в профиле не чиним молча (это признак бага или порчи данных) — пропускаем
-- операцию и один раз пишем в лог.
local function reportCorruption(player: Player, reason: string)
	local state = getPlayerState(player)
	if not state.CorruptionReported then
		state.CorruptionReported = true
		warn(`[FactorySystem] Некорректные данные профиля {player.Name} ({player.UserId}): {reason}`)
	end
end

-- Единая транзакция покупки: проверки и запись без yield. Возвращает nil при успехе
-- или причину отказа (для лога; клиенту причина не отправляется).
local function tryPurchase(player: Player, upgradeId: unknown, targetLevel: unknown): string?
	if type(upgradeId) ~= "string" then
		return "bad-argument"
	end

	local track = UpgradeEffects.GetTrack(upgradeId)
	if not track then
		return "unknown-upgrade"
	end

	if not isFinite(targetLevel) or (targetLevel :: number) % 1 ~= 0 then
		return "bad-argument"
	end

	local data = DataSystem.GetData(player)
	if not data then
		return "no-profile"
	end

	local currentLevel = getLevel(data, track.Id)
	if not UpgradeEffects.IsValidLevel(track.Id, currentLevel) then
		reportCorruption(player, `уровень {track.Id} = {currentLevel}`)
		return "corrupt-level"
	end
	if currentLevel >= track.MaxLevel then
		return "max-level"
	end
	if targetLevel ~= currentLevel + 1 then
		return "level-mismatch" -- повтор уже обработанного запроса или попытка перескочить уровень
	end

	local step = track.Levels[currentLevel + 1]
	local essence = data.Currency.Essence
	if not isFinite(essence) or essence < 0 then
		reportCorruption(player, `Essence = {essence}`)
		return "corrupt-essence"
	end
	if essence < step.Price then
		return "insufficient-essence"
	end

	local newEssence = essence - step.Price
	local newEffect = UpgradeEffects.GetEffectValue(track.Id, currentLevel + 1)
	if not isFinite(newEssence) or not isFinite(newEffect) then
		return "non-finite-result"
	end

	data.Currency.Essence = newEssence
	setLevel(data, track.Id, currentLevel + 1)
	return nil
end

local function onPurchaseUpgrade(player: Player, upgradeId: unknown, targetLevel: unknown)
	local now = os.clock()
	local state = getPlayerState(player)

	if not RateLimiter.Allow(state.RequestTimes, now, FactoryConfig.RequestWindow, FactoryConfig.MaxRequestsPerWindow) then
		registerReject(player, "rate-limit", now)
		return
	end

	local reason = tryPurchase(player, upgradeId, targetLevel)
	if reason then
		registerReject(player, reason, now)
	end
end

-- Один тик конвейера игрока: не больше одного цикла переработки. Без yield.
local function runConveyor(player: Player, data: PlayerProfile, now: number)
	local state = getPlayerState(player)
	local factory = data.Factory

	local raw = factory.RawFragments
	if not isFinite(raw) or raw < 0 then
		reportCorruption(player, `RawFragments = {raw}`)
		return
	end
	if raw == 0 then
		-- Конвейер простаивает: новый фрагмент ждёт полную задержку с момента поступления.
		state.LastCycleAt = now
		return
	end

	-- Задержка — из текущего уровня на каждом тике (уровень зажат в [0, MaxLevel]).
	local delay = UpgradeEffects.GetEffectValue("ConveyorSpeed", factory.ConveyorSpeedLevel)
	if now - state.LastCycleAt < delay then
		return
	end

	local batch = math.min(raw, FactoryConfig.FragmentsPerCycle)
	local amount = batch * FactoryConfig.EssencePerFragment * data.Rebirth.ClarityMultiplier
	local newEssence = data.Currency.Essence + amount
	if not isFinite(amount) or amount <= 0 or not isFinite(newEssence) then
		reportCorruption(
			player,
			`выход конвейера {amount} (ClarityMultiplier = {data.Rebirth.ClarityMultiplier}, Essence = {data.Currency.Essence})`
		)
		return
	end

	factory.RawFragments = raw - batch
	data.Currency.Essence = newEssence
	-- Сдвиг расписания на delay, а не на now: иначе каждый цикл округлялся бы вверх до шага тика.
	-- Отставание больше чем на цикл (лаг сервера) не копим — «догонять» пачкой не даём.
	state.LastCycleAt = if now - state.LastCycleAt >= 2 * delay then now else state.LastCycleAt + delay
	FactorySystem.OnEssenceProduced:Fire(player, amount)
end

-- Каждый игрок — под своим pcall: ошибка на битом профиле (например, Rebirth или Factory
-- не таблица — reconcile() неверные типы не чинит) не должна останавливать конвейер остальным.
-- Предупреждение — один раз на игрока за сессию, чтобы не спамить лог на каждом тике.
local function conveyorTick()
	local now = os.clock()
	for _, player in Players:GetPlayers() do
		local ok, err = pcall(function()
			local data = DataSystem.GetData(player)
			if data then
				runConveyor(player, data, now)
			end
		end)
		if not ok then
			local state = getPlayerState(player)
			if not state.TickErrorReported then
				state.TickErrorReported = true
				warn(`[FactorySystem] Ошибка конвейера у {player.Name} ({player.UserId}): {err}`)
			end
		end
	end
end

function FactorySystem.Init()
	Remotes.PurchaseUpgrade.OnServerEvent:Connect(onPurchaseUpgrade)

	Players.PlayerRemoving:Connect(function(player)
		playerStates[player] = nil
	end)

	task.spawn(function()
		while true do
			task.wait(FactoryConfig.TickInterval)
			-- Страховка: поток конвейера не должен умереть ни при каких ошибках
			-- (например, если бросит Players:GetPlayers). Ошибки игроков ловятся внутри.
			local ok, err = pcall(conveyorTick)
			if not ok then
				warn(`[FactorySystem] Ошибка тика конвейера: {err}`)
			end
		end
	end)
end

return FactorySystem
