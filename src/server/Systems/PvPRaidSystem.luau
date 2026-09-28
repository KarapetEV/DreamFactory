--!strict

--[[
	PvPRaidSystem — «Вторжение в сон» (раздел 5.6 ТЗ/GDD, анти-чит — раздел 7). Лимиты кражи,
	щит, кулдауны — PvPConfig; формула защиты (стражи + Fearful-петы цели) — GuardConfig.

	Область (S17): рейд только на цель, которая ПРЯМО СЕЙЧАС на этом же сервере. Оба профиля
	session-locked здесь и лежат в памяти (DataSystem.GetData), поэтому перенос Essence — обычная
	запись в две таблицы без DataStore-обращений. Асинхронный рейд на офлайн-цель сознательно
	НЕ реализован: чужой профиль без session-lock этого сервера читать/писать небезопасно —
	отдельная будущая задача.

	RequestRaidStart(targetUserId):
	- клиент присылает только UserId цели; сумму кражи, защиту, дистанцию сервер считает сам,
	  лишние аргументы игнорируются;
	- tryRaid — одна функция без yield: проверки → перенос Essence между профилями → запись
	  PvP.LastRaidedAt цели и кулдауна пары. Между проверкой и записью не может вклиниться
	  ни второй запрос, ни выход цели;
	- проверки: цель на этом сервере (Players:GetPlayerByUserId) и с загруженным профилем,
	  цель ≠ атакующий, кулдаун пары attacker→target, щит цели (PvP.ShieldExpiresAt), grace-окно
	  после недавнего рейда (PvP.LastRaidedAt — от любого атакующего), дистанция от серверной
	  позиции атакующего до плейсхолдер-Part рейд-инстанса цели;
	- кумулятивный лимит потерь цели за StolenWindowDuration от всех атакующих вместе — более
	  строгий из абсолютного (MaxStolenPerTargetWindow) и относительного (EssenceAtWindowStart ×
	  MaxStolenPercentPerTargetWindow): окно ротируется лениво здесь же (истекло или не
	  начиналось — StolenInWindow = 0, начало nowTime, EssenceAtWindowStart = баланс цели до
	  кражи этого рейда); stolen урезается до остатка лимита, остатка нет — отказ
	  "target-loss-cap"; после записи StolenInWindow += stolen;
	- битый раздел PvP/Currency у цели — отказ (не грабим профиль, который не можем прочитать);
	  у атакующего — отказ; ошибка любого вида изолирована pcall в обработчике.

	Щит при входе: после загрузки профиля ShieldExpiresAt = max(текущий, now + ShieldDuration).
	Успешный рейд снимает щит атакующего (напал — открыт для ответа). Щит после апгрейда
	(опция GDD) не выставляется.

	Рейд-инстанс: пока плейсхолдер — анкерный Part на каждого игрока на сервере (слоты по
	PvPConfig), создаётся после загрузки профиля, удаляется при выходе. Клон модели фабрики
	цели — отдельная сессия.

	Время: щит и grace — os.time() (персистятся в профиле), кулдаун пары — os.clock() в памяти
	по UserId (переживает реджойн на этот же сервер, но не смену сервера — там его заменяет
	grace-окно цели).

	После успешного рейда — FactorySystem.PushSnapshot обоим (каждый в своём pcall) и
	OnRaidCompleted. На отказ клиенту ничего не шлётся (UI рейда — отдельная сессия).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Types = require(ReplicatedStorage.shared.Types)
local Remotes = require(ReplicatedStorage.shared.Remotes)
local Signal = require(ReplicatedStorage.shared.Signal)
local UpgradeEffects = require(ReplicatedStorage.shared.UpgradeEffects)
local PvPConfig = require(ReplicatedStorage.shared.Config.PvPConfig)
local GuardConfig = require(ReplicatedStorage.shared.Config.GuardConfig)
local DataSystem = require(script.Parent.DataSystem)
local FactorySystem = require(script.Parent.FactorySystem)
local PetSystem = require(script.Parent.PetSystem)
local AnalyticsSystem = require(script.Parent.AnalyticsSystem)
local RateLimiter = require(script.Parent.Parent.Services.RateLimiter)

type PlayerProfile = Types.PlayerProfile

type PlayerState = {
	RequestTimes: { number }, -- метки вызовов RequestRaidStart в окне rate limit
	Rejects: number,
	RejectWindowStart: number,
}

local FOLDER_NAME = "RaidInstances"
local REJECT_LOG_WINDOW = 60
-- Отказы, обычные для честного игрока (цель под щитом/только что ограблена, повторный клик,
-- цель вышла): в счётчик подозрительной активности не идут.
local BENIGN_REJECTS: { [string]: true } = {
	cooldown = true,
	shielded = true,
	["recently-raided"] = true,
	["target-offline"] = true,
	["nothing-to-steal"] = true,
	["target-loss-cap"] = true, -- цель активно грабят — обычный исход, не эксплойт
	-- Битый профиль цели — не вина атакующего (порча уже в логе через reportCorruption).
	["corrupt-target"] = true,
}

local isFinite = UpgradeEffects.IsFinite

local PvPRaidSystem = {}

-- (attacker: Player, target: Player, stolen: number) — рейд выполнен, Essence перенесена.
PvPRaidSystem.OnRaidCompleted = Signal.new()

local playerStates: { [Player]: PlayerState } = {}
-- attackerUserId -> targetUserId -> os.clock() последнего успешного рейда этой пары.
local pairCooldowns: { [number]: { [number]: number } } = {}
-- UserId -> плейсхолдер рейд-инстанса; slot -> UserId (занятые слоты позиций).
local raidInstances: { [number]: BasePart } = {}
local slots: { [number]: number } = {}
local folder: Instance? = nil
-- Предупреждение о битом PvP-разделе — один раз за сессию на UserId.
local corruptionReported: { [number]: true } = {}

local function getPlayerState(player: Player): PlayerState
	local state = playerStates[player]
	if not state then
		state = {
			RequestTimes = {},
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
	if state.Rejects == PvPConfig.SuspiciousRejectThreshold then
		warn(
			`[PvPRaidSystem] Подозрительная активность: {player.Name} ({player.UserId}), `
				.. `{state.Rejects} отклонённых RequestRaidStart за {REJECT_LOG_WINDOW} с, последняя причина: {reason}`
		)
	end
end

local function reportCorruption(userId: number, reason: string)
	if not corruptionReported[userId] then
		corruptionReported[userId] = true
		warn(`[PvPRaidSystem] Некорректные данные профиля {userId}: {reason}`)
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

------------------------------------------------------------------------------------------
-- Формула кражи (чистые функции, экспортируются для тестов)
------------------------------------------------------------------------------------------

-- Доля защиты цели в [0, MaxReduction] по GuardConfig. guardsPlaced — PvP.GuardsPlaced
-- (массив строк); fearfulDefense — PetSystem.GetCachedBonuses(target).FearfulDefense.
function PvPRaidSystem.ComputeDefense(guardsPlaced: { string }, fearfulDefense: number): number
	local defense = 0
	for i = 1, math.min(#guardsPlaced, GuardConfig.MaxGuards) do
		local id = guardsPlaced[i]
		local guard = if type(id) == "string" then GuardConfig.Types[id] else nil
		if guard then
			defense += guard.Defense
		end
	end
	if isFinite(fearfulDefense) and fearfulDefense > 0 then
		defense += fearfulDefense * GuardConfig.FearfulPetDefenseScale
	end
	if not isFinite(defense) then
		return GuardConfig.MaxReduction
	end
	return math.clamp(defense, 0, GuardConfig.MaxReduction)
end

-- Сколько Essence уносит рейд: floor(min(essence × StealPercent, HardCap) × (1 − защита)).
function PvPRaidSystem.ComputeStolen(targetEssence: number, defense: number): number
	local base = math.min(targetEssence * PvPConfig.StealPercent, PvPConfig.HardCap)
	local stolen = math.floor(base * (1 - math.clamp(defense, 0, GuardConfig.MaxReduction)))
	if not isFinite(stolen) or stolen < 0 then
		return 0
	end
	return math.min(stolen, targetEssence)
end

------------------------------------------------------------------------------------------
-- Рейд-инстансы (плейсхолдеры)
------------------------------------------------------------------------------------------

local function getFolder(): Instance
	if folder == nil then
		local created = Instance.new("Folder")
		created.Name = FOLDER_NAME
		created.Parent = Workspace
		folder = created
	end
	return folder :: Instance
end

local function createRaidInstance(player: Player)
	local userId = player.UserId
	if raidInstances[userId] then
		return
	end
	local slot = 1
	while slots[slot] ~= nil do
		slot += 1
	end

	local origin = PvPConfig.RaidInstanceOrigin
	local part = Instance.new("Part")
	part.Name = `RaidInstance_{userId}`
	part.Size = PvPConfig.RaidInstanceSize
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.Transparency = 0.6
	part.Position = Vector3.new(origin.X + (slot - 1) * PvPConfig.RaidInstanceSpacing, origin.Y, origin.Z)
	part:SetAttribute("OwnerUserId", userId)
	part.Parent = getFolder()

	slots[slot] = userId
	raidInstances[userId] = part
end

local function destroyRaidInstance(userId: number)
	local part = raidInstances[userId]
	raidInstances[userId] = nil
	for slot, owner in slots do
		if owner == userId then
			slots[slot] = nil
		end
	end
	if part then
		part:Destroy()
	end
end

------------------------------------------------------------------------------------------
-- Транзакция рейда
------------------------------------------------------------------------------------------

-- Кулдауны пар, у которых окно уже прошло, — удаляются (карта не растёт бесконечно).
local function sweepCooldowns(now: number)
	for attackerId, targets in pairCooldowns do
		for targetId, at in targets do
			if now - at >= PvPConfig.AttackCooldownPerTarget then
				targets[targetId] = nil
			end
		end
		if next(targets) == nil then
			pairCooldowns[attackerId] = nil
		end
	end
end

local function validEssence(value: unknown): boolean
	return isFinite(value) and (value :: number) >= 0
end

-- Необязательная метка времени профиля: nil или конечное число; иначе — битое поле.
local function optionalTime(value: unknown): (boolean, number?)
	if value == nil then
		return true, nil
	end
	if isFinite(value) then
		return true, value :: number
	end
	return false, nil
end

-- Единая транзакция рейда: проверки и запись без yield. Возвращает (nil, цель, украдено)
-- при успехе или (причина отказа) — для лога; клиенту не отправляется.
local function tryRaid(attacker: Player, targetUserId: unknown, now: number, nowTime: number): (string?, Player?, number?)
	if not isFinite(targetUserId) or (targetUserId :: number) % 1 ~= 0 or (targetUserId :: number) <= 0 then
		return "bad-argument"
	end
	local targetId = targetUserId :: number
	if targetId == attacker.UserId then
		return "self"
	end

	-- Только цель на этом сервере: её профиль session-locked здесь же.
	local target = Players:GetPlayerByUserId(targetId)
	if not target or target.Parent == nil then
		return "target-offline"
	end

	local attackerData = DataSystem.GetData(attacker)
	if not attackerData then
		return "no-profile"
	end
	local targetData = DataSystem.GetData(target)
	if not targetData then
		-- Профиль ещё грузится или уже освобождён (цель выходит) — писать некуда.
		return "target-offline"
	end

	local cooldowns = pairCooldowns[attacker.UserId]
	local lastPairRaid = cooldowns and cooldowns[targetId]
	if lastPairRaid and now - lastPairRaid < PvPConfig.AttackCooldownPerTarget then
		return "cooldown"
	end

	local pvp: any = targetData.PvP
	if type(pvp) ~= "table" then
		reportCorruption(targetId, `PvP = {pvp}`)
		return "corrupt-target"
	end
	local shieldOk, shieldExpiresAt = optionalTime(pvp.ShieldExpiresAt)
	local raidedOk, lastRaidedAt = optionalTime(pvp.LastRaidedAt)
	local guards = pvp.GuardsPlaced
	local windowOk, windowStartsAt = optionalTime(pvp.StolenWindowStartsAt)
	local stolenInWindow = pvp.StolenInWindow
	local essenceAtWindowStart = pvp.EssenceAtWindowStart
	if
		not shieldOk
		or not raidedOk
		or type(guards) ~= "table"
		or not windowOk
		or not validEssence(stolenInWindow)
		or not validEssence(essenceAtWindowStart)
	then
		reportCorruption(targetId, "раздел PvP повреждён")
		return "corrupt-target"
	end
	if shieldExpiresAt and nowTime < shieldExpiresAt then
		return "shielded"
	end
	-- Разница может быть отрицательной (метка с другого сервера со сдвигом часов) — тоже grace.
	if lastRaidedAt and nowTime - lastRaidedAt < PvPConfig.RaidedGraceDuration then
		return "recently-raided"
	end

	-- «Вошёл в рейд-инстанс»: серверная позиция атакующего у Part'а цели.
	local instance = raidInstances[targetId]
	if not instance then
		return "no-instance"
	end
	local rootPosition = getRootPosition(attacker)
	if not rootPosition then
		return "no-character"
	end
	if (rootPosition - instance.Position).Magnitude > PvPConfig.RaidRange + PvPConfig.DistanceTolerance then
		return "too-far"
	end

	local attackerPvP: any = attackerData.PvP
	if type(attackerPvP) ~= "table" then
		reportCorruption(attacker.UserId, `PvP = {attackerPvP}`)
		return "corrupt-attacker"
	end
	local attackerCurrency: any = attackerData.Currency
	local targetCurrency: any = targetData.Currency
	if type(attackerCurrency) ~= "table" or not validEssence(attackerCurrency.Essence) then
		reportCorruption(attacker.UserId, "Currency.Essence повреждён")
		return "corrupt-attacker"
	end
	if type(targetCurrency) ~= "table" or not validEssence(targetCurrency.Essence) then
		reportCorruption(targetId, "Currency.Essence повреждён")
		return "corrupt-target"
	end

	local targetEssence: number = targetCurrency.Essence
	local defense = PvPRaidSystem.ComputeDefense(guards, PetSystem.GetCachedBonuses(target).FearfulDefense)
	local stolen = PvPRaidSystem.ComputeStolen(targetEssence, defense)
	if stolen <= 0 then
		return "nothing-to-steal"
	end

	-- Окно лимита потерь цели: ротация — только локальные значения, запишутся вместе с рейдом.
	-- Отрицательная разница (метка с другого сервера со сдвигом часов) окно не сбрасывает.
	if windowStartsAt == nil or nowTime - windowStartsAt >= PvPConfig.StolenWindowDuration then
		windowStartsAt = nowTime
		stolenInWindow = 0
		essenceAtWindowStart = targetEssence -- «сколько было в начале периода»: до кражи этого рейда
	end
	local relativeCap = essenceAtWindowStart * PvPConfig.MaxStolenPercentPerTargetWindow
	local remaining = math.min(PvPConfig.MaxStolenPerTargetWindow, relativeCap) - stolenInWindow
	if remaining <= 0 then
		return "target-loss-cap"
	end
	stolen = math.min(stolen, math.floor(remaining))
	if stolen <= 0 then
		return "target-loss-cap"
	end
	local newTargetEssence = targetEssence - stolen
	local newAttackerEssence = attackerCurrency.Essence + stolen
	if not validEssence(newTargetEssence) or not isFinite(newAttackerEssence) then
		return "non-finite-result"
	end

	-- Запись: все проверки пройдены, дальше ничего не бросает.
	targetCurrency.Essence = newTargetEssence
	attackerCurrency.Essence = newAttackerEssence
	pvp.LastRaidedAt = nowTime
	pvp.StolenWindowStartsAt = windowStartsAt
	pvp.EssenceAtWindowStart = essenceAtWindowStart
	pvp.StolenInWindow = stolenInWindow + stolen
	-- Напавший теряет свой щит: иначе щит входа (обновляемый реджойном) давал бы
	-- «граблю всех, ответить мне нельзя».
	attackerPvP.ShieldExpiresAt = nil
	sweepCooldowns(now)
	local attackerCooldowns = pairCooldowns[attacker.UserId]
	if not attackerCooldowns then
		attackerCooldowns = {}
		pairCooldowns[attacker.UserId] = attackerCooldowns
	end
	attackerCooldowns[targetId] = now
	return nil, target, stolen
end

local function pushSnapshot(player: Player)
	local ok, err = pcall(FactorySystem.PushSnapshot, player)
	if not ok then
		warn(`[PvPRaidSystem] Снимок после рейда игроку {player.UserId} не отправлен: {err}`)
	end
end

local function onRequestRaidStart(player: Player, targetUserId: unknown)
	-- Запрос после PlayerRemoving: getPlayerState пересоздал бы запись (утечка).
	if player.Parent == nil then
		return
	end

	local now = os.clock()
	local state = getPlayerState(player)
	if not RateLimiter.Allow(state.RequestTimes, now, PvPConfig.RequestWindow, PvPConfig.MaxRequestsPerWindow) then
		registerReject(player, "rate-limit", now)
		return
	end

	-- Транзакция не мутирует профили до последней проверки: ошибка на битом разделе ничего
	-- не портит — ловим, чтобы она не уронила обработчик.
	local ok, reason, target, stolen = pcall(tryRaid, player, targetUserId, now, os.time())
	if not ok then
		reportCorruption(player.UserId, `ошибка обработки RequestRaidStart: {reason}`)
		registerReject(player, "error", now)
		return
	end
	if reason or not target or not stolen then
		registerReject(player, reason or "error", now)
		return
	end

	-- Перенос уже в обоих профилях: ошибки снимков/подписчиков его не отменяют.
	pushSnapshot(player)
	pushSnapshot(target)
	AnalyticsSystem.LogEvent(player, AnalyticsSystem.Events.PvPRaid, stolen)
	PvPRaidSystem.OnRaidCompleted:Fire(player, target, stolen)
end

-- Щит при входе: ShieldExpiresAt = max(текущий, now + ShieldDuration).
local function applyJoinShield(player: Player, data: PlayerProfile)
	local pvp: any = data.PvP
	if type(pvp) ~= "table" then
		reportCorruption(player.UserId, `PvP = {pvp}`)
		return
	end
	local expiresAt = os.time() + PvPConfig.ShieldDuration
	local current = pvp.ShieldExpiresAt
	if isFinite(current) and current > expiresAt then
		return
	end
	pvp.ShieldExpiresAt = expiresAt
end

local function onPlayerAdded(player: Player)
	task.spawn(function()
		-- Без таймаута (ждём, пока игрок на сервере): загрузка профиля с ожиданием чужого лока
		-- бывает дольше 60 с, а без инстанса игрок был бы неуязвим всю сессию.
		local data = DataSystem.WaitForData(player, math.huge)
		if not data or player.Parent == nil then
			return
		end
		applyJoinShield(player, data)
		createRaidInstance(player)
	end)
end

-- Позиция рейд-инстанса игрока (для клиента/тестов); nil — игрока нет или профиль не загружен.
function PvPRaidSystem.GetRaidInstancePosition(userId: number): Vector3?
	local part = raidInstances[userId]
	return if part then part.Position else nil
end

function PvPRaidSystem.Init()
	Remotes.RequestRaidStart.OnServerEvent:Connect(onRequestRaidStart)

	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end

	-- Rate limit — по Player; кулдауны пар — по UserId, остаются до истечения (sweepCooldowns).
	Players.PlayerRemoving:Connect(function(player)
		playerStates[player] = nil
		corruptionReported[player.UserId] = nil
		destroyRaidInstance(player.UserId)
	end)
end

return PvPRaidSystem
