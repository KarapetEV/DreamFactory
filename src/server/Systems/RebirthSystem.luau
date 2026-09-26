--!strict

--[[
	RebirthSystem — перерождение (раздел 5.4 ТЗ, анти-чит — раздел 7).

	PerformRebirth() — без аргументов: клиент присылает только намерение, всё остальное
	(порог, множитель, биом, стартовые значения) сервер берёт из конфигов и профиля.

	tryRebirth — единая транзакция без yield: все проверки до первой записи, затем одним
	блоком запись нового состояния.
	- порог: Currency.Essence ≥ RebirthConfig.MinEssence (одна метрика, см. RebirthConfig);
	- Rebirth.Count + 1;
	- ClarityMultiplier = StartingProfileConfig.ClarityMultiplier + Σ ClarityMultiplierBonus
	  всех биомов с RebirthThreshold ≤ нового Count (пересчёт с нуля, не накопление, —
	  повторный или битый множитель в профиле не «разгоняется»);
	- CurrentBiome — открытый биом с наибольшим порогом (пороги уникальны — BiomeConfig);
	- сброс к StartingProfileConfig: Essence, уровни фабрики и сбора; RawFragments → 0.
	  НЕ сбрасываются: Factory.Decor (исключение ТЗ), Collection.AutoCollectorOwned
	  (потенциально платная фича), петы, монетизация, PvP.

	Множитель применяет FactorySystem к выходу конвейера (Rebirth.ClarityMultiplier) — здесь
	его только пишут. Ответ клиенту — EconomySnapshot через FactorySystem.PushSnapshot с
	RebirthAck (успех/отказ); отдельного снимка нет.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.shared.Types)
local Remotes = require(ReplicatedStorage.shared.Remotes)
local UpgradeEffects = require(ReplicatedStorage.shared.UpgradeEffects)
local RebirthProgress = require(ReplicatedStorage.shared.RebirthProgress)
local BiomeConfig = require(ReplicatedStorage.shared.Config.BiomeConfig)
local RebirthConfig = require(ReplicatedStorage.shared.Config.RebirthConfig)
local StartingProfileConfig = require(ReplicatedStorage.shared.Config.StartingProfileConfig)
local DataSystem = require(script.Parent.DataSystem)
local FactorySystem = require(script.Parent.FactorySystem)
local RateLimiter = require(script.Parent.Parent.Services.RateLimiter)

type PlayerProfile = Types.PlayerProfile

type PlayerState = {
	RequestTimes: { number }, -- метки вызовов PerformRebirth в окне rate limit
	Rejects: number,
	RejectWindowStart: number,
	CorruptionReported: boolean, -- предупреждение о битом профиле уже записано
}

local REJECT_LOG_WINDOW = 60

local isFinite = UpgradeEffects.IsFinite

assert(
	isFinite(RebirthConfig.MinEssence) and RebirthConfig.MinEssence > 0,
	`RebirthConfig: некорректный MinEssence {RebirthConfig.MinEssence}`
)
assert(
	isFinite(RebirthConfig.RequestWindow) and RebirthConfig.RequestWindow > 0,
	"RebirthConfig: некорректный RequestWindow"
)
assert(
	isFinite(RebirthConfig.MaxRequestsPerWindow)
		and RebirthConfig.MaxRequestsPerWindow >= 1
		and RebirthConfig.MaxRequestsPerWindow % 1 == 0,
	"RebirthConfig: некорректный MaxRequestsPerWindow"
)
-- Защита от повторного rebirth держится на том, что после сброса Essence ниже порога:
-- иначе каждый PerformRebirth (и двойная доставка) проходил бы бесплатно.
assert(
	StartingProfileConfig.Essence < RebirthConfig.MinEssence,
	`RebirthSystem: стартовая Essence {StartingProfileConfig.Essence} не меньше порога {RebirthConfig.MinEssence}`
)
assert(
	isFinite(StartingProfileConfig.ClarityMultiplier) and StartingProfileConfig.ClarityMultiplier > 0,
	"RebirthSystem: некорректный StartingProfileConfig.ClarityMultiplier"
)
-- Стартовый биом нового игрока = биом с порогом 0 (гарантированный пол BiomeConfig):
-- иначе игрок до и после первого rebirth «жил» бы в разных системах отсчёта.
do
	local start = BiomeConfig[StartingProfileConfig.StartingBiomeId]
	assert(
		start and start.RebirthThreshold == 0,
		`RebirthSystem: стартовый биом {StartingProfileConfig.StartingBiomeId} должен иметь RebirthThreshold = 0`
	)
end

local RebirthSystem = {}

local playerStates: { [Player]: PlayerState } = {}

local function getPlayerState(player: Player): PlayerState
	local state = playerStates[player]
	if not state then
		state = {
			RequestTimes = {},
			Rejects = 0,
			RejectWindowStart = 0,
			CorruptionReported = false,
		}
		playerStates[player] = state
	end
	return state
end

local function registerReject(player: Player, reason: string, now: number)
	local state = getPlayerState(player)
	if now - state.RejectWindowStart > REJECT_LOG_WINDOW then
		state.RejectWindowStart = now
		state.Rejects = 0
	end

	state.Rejects += 1
	if state.Rejects == RebirthConfig.SuspiciousRejectThreshold then
		warn(
			`[RebirthSystem] Подозрительная активность: {player.Name} ({player.UserId}), `
				.. `{state.Rejects} отклонённых PerformRebirth за {REJECT_LOG_WINDOW} с, последняя причина: {reason}`
		)
	end
end

local function reportCorruption(player: Player, reason: string)
	local state = getPlayerState(player)
	if not state.CorruptionReported then
		state.CorruptionReported = true
		warn(`[RebirthSystem] Некорректные данные профиля {player.Name} ({player.UserId}): {reason}`)
	end
end

-- Множитель и биом для заданного числа rebirth (логика — в shared/RebirthProgress).
function RebirthSystem.ComputeProgress(rebirthCount: number): RebirthProgress.RebirthProgress
	return RebirthProgress.Compute(rebirthCount)
end

-- Единая транзакция rebirth: проверки и запись без yield. Возвращает nil при успехе
-- или причину отказа (для лога; клиенту причина не отправляется).
local function tryRebirth(player: Player): string?
	local data = DataSystem.GetData(player)
	if not data then
		return "no-profile"
	end

	-- reconcile() не чинит неверные типы — проверяем разделы, которые будем писать.
	local rebirth, currency, factory, collection = data.Rebirth, data.Currency, data.Factory, data.Collection
	if
		type(rebirth) ~= "table"
		or type(currency) ~= "table"
		or type(factory) ~= "table"
		or type(collection) ~= "table"
	then
		reportCorruption(player, "раздел Rebirth/Currency/Factory/Collection не таблица")
		return "corrupt-profile"
	end

	local count = rebirth.Count
	if not isFinite(count) or count < 0 or count % 1 ~= 0 then
		reportCorruption(player, `Rebirth.Count = {count}`)
		return "corrupt-count"
	end
	local essence = currency.Essence
	if not isFinite(essence) or essence < 0 then
		reportCorruption(player, `Essence = {essence}`)
		return "corrupt-essence"
	end
	if essence < RebirthConfig.MinEssence then
		return "below-threshold"
	end

	local newCount = count + 1
	local progress = RebirthSystem.ComputeProgress(newCount)
	if not isFinite(newCount) or not isFinite(progress.ClarityMultiplier) or progress.ClarityMultiplier <= 0 then
		return "non-finite-result"
	end

	-- Запись одним блоком. Decor и AutoCollectorOwned не трогаем намеренно.
	local start = StartingProfileConfig
	currency.Essence = start.Essence
	factory.Level = start.FactoryLevel
	factory.StorageCapacityLevel = start.StorageCapacityLevel
	factory.ConveyorSpeedLevel = start.ConveyorSpeedLevel
	factory.RawFragments = 0
	collection.RadiusLevel = start.CollectionRadiusLevel
	collection.SpeedLevel = start.CollectionSpeedLevel
	rebirth.ClarityMultiplier = progress.ClarityMultiplier
	rebirth.CurrentBiome = progress.CurrentBiome
	rebirth.Count = newCount
	return nil
end

local function onPerformRebirth(player: Player)
	-- Запрос после PlayerRemoving: getPlayerState пересоздал бы запись (утечка).
	if player.Parent == nil then
		return
	end

	local now = os.clock()
	local state = getPlayerState(player)
	if not RateLimiter.Allow(state.RequestTimes, now, RebirthConfig.RequestWindow, RebirthConfig.MaxRequestsPerWindow) then
		-- Без ответа: не даём спамеру усиление исходящего трафика.
		registerReject(player, "rate-limit", now)
		return
	end

	-- tryRebirth не пишет в профиль до последней проверки, поэтому исключение на
	-- неожиданно битых данных ничего не портит; ловим, чтобы ответить и не спамить лог.
	local ok, result = pcall(tryRebirth, player)
	local reason: string? = if ok then result else "error"
	if not ok then
		reportCorruption(player, `ошибка PerformRebirth: {result}`)
	end
	if reason then
		registerReject(player, reason, now)
	end

	FactorySystem.PushSnapshot(player, reason == nil)
end

function RebirthSystem.Init()
	Remotes.PerformRebirth.OnServerEvent:Connect(onPerformRebirth)

	Players.PlayerRemoving:Connect(function(player)
		playerStates[player] = nil
	end)
end

return RebirthSystem
