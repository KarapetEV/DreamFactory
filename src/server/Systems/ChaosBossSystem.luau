--!strict

--[[
	ChaosBossSystem — шкала Хаоса сервера и ивент «Вторжение Кошмара» (раздел 5.5 ТЗ/GDD,
	анти-чит — раздел 7). Формулы и числа — ChaosBossConfig.

	Шкала:
	- ServerChaosLevel — одна на сервер, только в памяти процесса (не в DataStore);
	- растёт от FactorySystem.OnEssenceProduced(player, amount, emotionType) с "Fearful",
	  падает от "Joyful" (подписка одна на весь сервер, сигнал общий для всех игроков);
	- во время боя шкала заморожена; при достижении порога — старт ивента.

	Бой:
	- босс — анкеренный Part-плейсхолдер в Workspace (атрибуты Health/MaxHealth — для
	  клиентского UI в S14; клиент их только отображает);
	- RequestAttackBoss() — без аргументов: клиент присылает только намерение. Урон
	  (ChaosBossConfig.DamagePerHit), дистанцию (позиция персонажа на сервере до центра
	  босса) и кулдаун удара сервер проверяет сам; rate limit — как в других системах;
	- tryAttack — одна функция без yield: урон урезается до остатка HP (добивающий не
	  получает вклад сверх него), HP не уходит ниже нуля, при HP = 0 ивент завершается
	  синхронно в том же вызове — следующий удар уже получает «no-event»;
	- вклад — Map<UserId, damageDealt>: переживает выход игрока с сервера.

	Завершение (победа или таймаут EventDuration):
	- сначала сбрасывается всё состояние ивента (боевой режим, шкала, вклад, босс), затем
	  по снятой копии вклада выдаётся бонус к Currency.Essence — каждому игроку в своём
	  pcall, битый профиль одного не мешает остальным;
	- награду получают только те, кто на сервере в момент завершения. Начисление вышедшим
	  при следующем входе (опция ТЗ) сознательно не реализовано;
	- таймер таймаута привязан к номеру ивента: устаревший таймер не завершает следующий ивент.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Remotes = require(ReplicatedStorage.shared.Remotes)
local Signal = require(ReplicatedStorage.shared.Signal)
local UpgradeEffects = require(ReplicatedStorage.shared.UpgradeEffects)
local ChaosBossConfig = require(ReplicatedStorage.shared.Config.ChaosBossConfig)
local DataSystem = require(script.Parent.DataSystem)
local FactorySystem = require(script.Parent.FactorySystem)
local RateLimiter = require(script.Parent.Parent.Services.RateLimiter)

export type Outcome = "Victory" | "Timeout"

-- Публичный снимок состояния (для тестов и будущей рассылки клиентам в S14).
export type ChaosState = {
	ChaosLevel: number,
	ActivationThreshold: number,
	Active: boolean,
	BossHealth: number,
	BossMaxHealth: number,
	EventId: number, -- номер текущего/последнего ивента (0 — ещё не было)
}

type PlayerState = {
	RequestTimes: { number }, -- метки вызовов RequestAttackBoss в окне rate limit
	LastAttackAt: number, -- момент последнего засчитанного удара
	Rejects: number,
	RejectWindowStart: number,
}

local BOSS_NAME = "ChaosBoss"
local REJECT_LOG_WINDOW = 60
-- Отказы, обычные для честного игрока (клик чаще кулдауна, клик после смерти босса):
-- в счётчик подозрительной активности не идут, иначе лог тонет в шуме.
local BENIGN_REJECTS: { [string]: true } = { cooldown = true, ["no-event"] = true }

local isFinite = UpgradeEffects.IsFinite

local ChaosBossSystem = {}

-- (eventId: number) — босс появился.
ChaosBossSystem.OnEventStarted = Signal.new()
-- (eventId: number, outcome: Outcome, rewards: { [number]: number }) — ивент завершён;
-- rewards — выданная Essence по UserId (только реально начисленное).
ChaosBossSystem.OnEventEnded = Signal.new()

local chaosLevel = 0
local active = false
local bossHealth = 0
local eventId = 0
local bossPart: Part? = nil
-- UserId -> урон, засчитанный в текущем ивенте.
local contributions: { [number]: number } = {}
local playerStates: { [Player]: PlayerState } = {}

local function getPlayerState(player: Player): PlayerState
	local state = playerStates[player]
	if not state then
		state = {
			RequestTimes = {},
			LastAttackAt = -math.huge,
			Rejects = 0,
			RejectWindowStart = 0,
		}
		playerStates[player] = state
	end
	return state
end

local function registerReject(player: Player, reason: string, now: number)
	if BENIGN_REJECTS[reason] then
		return
	end
	local state = getPlayerState(player)
	if now - state.RejectWindowStart > REJECT_LOG_WINDOW then
		state.RejectWindowStart = now
		state.Rejects = 0
	end

	state.Rejects += 1
	if state.Rejects == ChaosBossConfig.SuspiciousRejectThreshold then
		warn(
			`[ChaosBossSystem] Подозрительная активность: {player.Name} ({player.UserId}), `
				.. `{state.Rejects} отклонённых RequestAttackBoss за {REJECT_LOG_WINDOW} с, последняя причина: {reason}`
		)
	end
end

-- Позиция корня живого персонажа на сервере (клиентской позиции не доверяем).
local function getRootPosition(player: Player): Vector3?
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
		return nil
	end
	return root.Position
end

local function createBossPart(): Part
	local part = Instance.new("Part")
	part.Name = BOSS_NAME
	part.Size = ChaosBossConfig.BossSize
	part.Material = Enum.Material.Neon
	part.Color = Color3.fromRGB(90, 20, 110)
	part.Anchored = true
	part.CanCollide = true
	part.CanTouch = false
	part.Position = ChaosBossConfig.BossPosition
	part:SetAttribute("MaxHealth", ChaosBossConfig.BossMaxHealth)
	part:SetAttribute("Health", ChaosBossConfig.BossMaxHealth)
	part.Parent = Workspace
	return part
end

-- Выдача награды игроку на сервере: проверки и запись без yield. Возвращает выданную сумму;
-- nil — нет профиля; битые данные — ошибка (до записи). Снимок отправляет вызывающий.
local function grantReward(player: Player, damage: number, outcome: Outcome): number?
	local data = DataSystem.GetData(player)
	if not data then
		return nil
	end

	local multiplier = if outcome == "Victory" then ChaosBossConfig.VictoryRewardMultiplier else 1
	local reward = damage * ChaosBossConfig.RewardEssencePerDamage * multiplier
	local currency: any = data.Currency
	if type(currency) ~= "table" then
		error("Currency не таблица")
	end
	local essence = currency.Essence
	if not isFinite(essence) or essence < 0 then
		error(`Essence = {essence}`)
	end
	local newEssence = essence + reward
	if not isFinite(reward) or reward < 0 or not isFinite(newEssence) then
		error(`награда {reward} при Essence {essence}`)
	end

	currency.Essence = newEssence
	return reward
end

local function finishEvent(outcome: Outcome)
	if not active then
		return
	end

	-- Сначала — сброс всего состояния ивента: ошибка при выдаче не должна оставить
	-- сервер в боевом режиме или позволить выдать награду повторно.
	local finished = contributions
	local finishedId = eventId
	contributions = {}
	active = false
	bossHealth = 0
	chaosLevel = 0
	if bossPart then
		bossPart:Destroy()
		bossPart = nil
	end

	local rewards: { [number]: number } = {}
	for userId, damage in finished do
		local player = Players:GetPlayerByUserId(userId)
		if player and player.Parent ~= nil then -- вышедшему награда не выдаётся (сознательное упрощение)
			local ok, result = pcall(grantReward, player, damage, outcome)
			if not ok then
				warn(`[ChaosBossSystem] Не удалось выдать награду за ивент {finishedId} игроку {userId}: {result}`)
			elseif result then
				-- Награда уже в профиле: ошибка снимка ниже её не отменяет и в rewards не прячет.
				rewards[userId] = result
				local pushed, err = pcall(FactorySystem.PushSnapshot, player)
				if not pushed then
					warn(`[ChaosBossSystem] Снимок после награды игроку {userId} не отправлен: {err}`)
				end
			end
		end
	end

	ChaosBossSystem.OnEventEnded:Fire(finishedId, outcome, rewards)
end

local function startEvent()
	-- Part — до записи состояния: если создание бросит, сервер не застрянет в боевом режиме
	-- без босса и таймера (шкала остаётся на пороге, следующий Fearful попробует снова).
	bossPart = createBossPart()
	eventId += 1
	active = true
	bossHealth = ChaosBossConfig.BossMaxHealth
	contributions = {}

	local startedId = eventId
	task.delay(ChaosBossConfig.EventDuration, function()
		-- Таймер прошлого ивента (уже завершённого победой) текущий не трогает.
		if active and eventId == startedId then
			finishEvent("Timeout")
		end
	end)

	ChaosBossSystem.OnEventStarted:Fire(startedId)
end

local function onEssenceProduced(_player: Player, _amount: number, emotionType: unknown)
	if active then
		return
	end

	if emotionType == "Fearful" then
		chaosLevel = math.min(chaosLevel + ChaosBossConfig.FearfulGainPerEvent, ChaosBossConfig.ActivationThreshold)
	elseif emotionType == "Joyful" then
		chaosLevel = math.max(chaosLevel - ChaosBossConfig.JoyfulDecayPerEvent, 0)
	else
		return
	end

	if chaosLevel >= ChaosBossConfig.ActivationThreshold then
		startEvent()
	end
end

-- Единая транзакция удара: проверки и запись без yield. Возвращает nil при успехе или
-- причину отказа (для лога; клиенту не отправляется).
local function tryAttack(player: Player, now: number): string?
	if not active then
		return "no-event"
	end

	local state = getPlayerState(player)
	if now - state.LastAttackAt < ChaosBossConfig.AttackCooldown then
		return "cooldown"
	end

	-- Без профиля награду не выдать, а удар съел бы общий пул HP у остальных.
	if not DataSystem.GetData(player) then
		return "no-profile"
	end

	local rootPosition = getRootPosition(player)
	if not rootPosition or not bossPart then
		return "no-character"
	end
	-- Дистанция — до серверной позиции босса (анкерный Part; клиент её не двигает).
	local maxDistance = ChaosBossConfig.AttackRange + ChaosBossConfig.DistanceTolerance
	if (rootPosition - bossPart.Position).Magnitude > maxDistance then
		return "too-far"
	end

	local dealt = math.min(ChaosBossConfig.DamagePerHit, bossHealth)
	if dealt <= 0 then
		return "no-event"
	end

	state.LastAttackAt = now
	bossHealth -= dealt
	contributions[player.UserId] = (contributions[player.UserId] or 0) + dealt
	if bossPart then
		bossPart:SetAttribute("Health", bossHealth)
	end

	if bossHealth <= 0 then
		finishEvent("Victory")
	end
	return nil
end

local function onRequestAttackBoss(player: Player)
	-- Запрос после PlayerRemoving: getPlayerState пересоздал бы запись (утечка).
	if player.Parent == nil then
		return
	end

	local now = os.clock()
	local state = getPlayerState(player)
	if
		not RateLimiter.Allow(
			state.RequestTimes,
			now,
			ChaosBossConfig.RequestWindow,
			ChaosBossConfig.MaxRequestsPerWindow
		)
	then
		registerReject(player, "rate-limit", now)
		return
	end

	local reason = tryAttack(player, now)
	if reason then
		registerReject(player, reason, now)
	end
end

function ChaosBossSystem.GetState(): ChaosState
	return {
		ChaosLevel = chaosLevel,
		ActivationThreshold = ChaosBossConfig.ActivationThreshold,
		Active = active,
		BossHealth = bossHealth,
		BossMaxHealth = ChaosBossConfig.BossMaxHealth,
		EventId = eventId,
	}
end

-- Урон игрока в текущем ивенте (0 — не участвовал или ивента нет).
function ChaosBossSystem.GetContribution(userId: number): number
	return contributions[userId] or 0
end

function ChaosBossSystem.Init()
	FactorySystem.OnEssenceProduced:Connect(onEssenceProduced)
	Remotes.RequestAttackBoss.OnServerEvent:Connect(onRequestAttackBoss)

	-- Кулдаун/rate limit — по Player и уходят вместе с ним; вклад (по UserId) остаётся до завершения.
	Players.PlayerRemoving:Connect(function(player)
		playerStates[player] = nil
	end)
end

return ChaosBossSystem
