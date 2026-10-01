--!strict

--[[
	CollectionSystem — спавн и сбор фрагментов снов (раздел 5.1 ТЗ, анти-чит — раздел 7).

	- Сервер по таймеру спавнит фрагменты (анкеренные Part) в зонах из CollectionConfig
	  в Workspace.DreamFragments; клиент их только видит и присылает intent RequestCollect(fragmentId).
	- Клиенту не доверяем ничего, кроме id: позиция фрагмента берётся из серверного реестра,
	  позиция игрока — доверенная из MovementGuard (телепорт её не сдвигает), кулдаун/ёмкость —
	  из уровней профиля и UpgradeConfig (UpgradeEffects зажимает уровень в [0, MaxLevel] —
	  эффект не растёт без предела).
	- Радиус сбора (getCollectRadius) — одна формула для магнита и для ручного сбора:
	  фиксированный AutoCollectorConfig.Radius × CollectionRadiusMultiplier надетых
	  Nostalgic-петов из кэша PetSystem (без кэша — 1; на каждый запрос не пересчитывается).
	  Апгрейд CollectionRadius снят с продажи и здесь не читается.
	- Сбор — одна функция без yield между проверками и записью (collectFragment): фрагмент
	  забирает ровно один игрок, буфер не выходит за ёмкость склада.
	- Ручной сбор — касанием: CollectionController шлёт RequestCollect(id), когда корень
	  персонажа касается хитбокса. Серверная граница дистанции — тот же getCollectRadius.
	- Магнит: у владельца геймпасса Авто-сборщика (AutoCollectorConfig.GamePassId в
	  Monetization.GamePassesOwned) и у игрока с действующим баффом Magnet Boost
	  (BuffSystem.IsActive — по Buffs.MagnetBoostExpiresAt). Отдельный серверный тик раз в
	  AutoCollectorConfig.TickInterval берёт ближайший фрагмент в getCollectRadius и проводит его через ту же collectFragment —
	  те же проверки (склад, кулдаун, MovementGuard-позиция), общий с ручным сбором кулдаун.
	  Клиент в этом пути не участвует; каждый игрок обрабатывается в своём pcall — битый
	  профиль одного не останавливает тик для остальных.
	- Сигнал клиентам о способе сбора: при сборе сервер ставит на Part фрагмента атрибуты
	  FragmentCollectMode ("Touch"/"Magnet") и FragmentCollectedBy (UserId), а сам Part
	  уничтожает через кадр — атрибут, выставленный в одном кадре с Destroy, клиенту не
	  реплицируется. При "Magnet" кристалл летит к собравшему (клиент реагирует на появление
	  атрибута), при "Touch" — прежняя вспышка при исчезновении.
	- Эмоциональный тип фрагмента (GDD раздел 3) выбирает сервер при спавне по весам
	  FragmentEmotionConfig.SpawnWeights (серверный Random). При сборе фрагмент ложится в
	  Factory.RawFragments[тип] — тип берётся из серверного реестра. Ёмкость склада
	  ограничивает сумму по типам (FragmentBuffer.Total); битый буфер — отказ без записи.
	- Визуал: тип — основной видимый сигнал фрагмента. Part красится в
	  VisualConfig.EmotionColors[тип], тип и биом зоны выставляются атрибутами
	  (Attributes.FragmentEmotion/FragmentBiome) — клиент строит по ним кристалл и частицы.
	  Атрибуты только для отображения: сбор их не читает, подмена на клиенте ничего не даёт.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Types = require(ReplicatedStorage.shared.Types)
local Remotes = require(ReplicatedStorage.shared.Remotes)
local BiomeConfig = require(ReplicatedStorage.shared.Config.BiomeConfig)
local CollectionConfig = require(ReplicatedStorage.shared.Config.CollectionConfig)
local AutoCollectorConfig = require(ReplicatedStorage.shared.Config.AutoCollectorConfig)
local FragmentEmotionConfig = require(ReplicatedStorage.shared.Config.FragmentEmotionConfig)
local PetSpeciesConfig = require(ReplicatedStorage.shared.Config.PetSpeciesConfig)
local VisualConfig = require(ReplicatedStorage.shared.Config.VisualConfig)
local UpgradeEffects = require(ReplicatedStorage.shared.UpgradeEffects)
local Attributes = require(ReplicatedStorage.shared.Attributes)
local FragmentBuffer = require(ReplicatedStorage.shared.FragmentBuffer)
local DataSystem = require(script.Parent.DataSystem)
local PetSystem = require(script.Parent.PetSystem)
local AnalyticsSystem = require(script.Parent.AnalyticsSystem)
local BuffSystem = require(script.Parent.BuffSystem)
local RateLimiter = require(script.Parent.Parent.Services.RateLimiter)
local MovementGuard = require(script.Parent.Parent.Services.MovementGuard)

type PlayerProfile = Types.PlayerProfile
type EmotionType = Types.EmotionType
type CollectMode = Types.CollectMode

type Fragment = {
	Id: number,
	Part: Part,
	Position: Vector3,
	ZoneId: string,
	PointIndex: number,
	EmotionType: EmotionType, -- выбран сервером при спавне; клиенту — только атрибутом для визуала
}

type PlayerState = {
	RequestTimes: { number }, -- метки времени вызовов в текущем окне rate limit
	LastCollectAt: number,
	Rejects: number,
	RejectWindowStart: number,
	AutoTickErrorReported: boolean, -- ошибка пассивного сбора уже записана в лог
}

local FOLDER_NAME = "DreamFragments"
local ID_ATTRIBUTE = "FragmentId"
local REJECT_LOG_WINDOW = 60

for _, zone in CollectionConfig.Zones do
	assert(BiomeConfig[zone.BiomeId], `CollectionSystem: биом {zone.BiomeId} зоны {zone.Id} отсутствует в BiomeConfig`)
	assert(#zone.SpawnPoints > 0, `CollectionSystem: у зоны {zone.Id} нет точек спавна`)
end

local CollectionSystem = {}

local fragments: { [number]: Fragment } = {}
-- zoneId -> pointIndex -> занята ли точка
local occupiedPoints: { [string]: { [number]: boolean } } = {}
local zoneCounts: { [string]: number } = {}
local nextFragmentId = 1
local playerStates: { [Player]: PlayerState } = {}
local rng = Random.new()

-- Тип фрагмента по весам FragmentEmotionConfig.SpawnWeights. unit — случайное число в [0, 1)
-- (в игре — серверный Random). Чистая функция: тесты проверяют распределение на выборке.
function CollectionSystem.RollEmotionType(unit: number): EmotionType
	local weights = FragmentEmotionConfig.SpawnWeights
	local total = 0
	for _, emotion in PetSpeciesConfig.EmotionTypes do
		total += weights[emotion]
	end
	local target = math.clamp(unit, 0, 1) * total
	local last: EmotionType? = nil
	for _, emotion in PetSpeciesConfig.EmotionTypes do
		local weight = weights[emotion]
		if weight > 0 then
			last = emotion
			if target < weight then
				return emotion
			end
			target -= weight
		end
	end
	-- unit = 1 или погрешность суммы: последний тип с ненулевым весом (сумма > 0 — проверено в конфиге).
	return last :: EmotionType
end

local function getPlayerState(player: Player): PlayerState
	local state = playerStates[player]
	if not state then
		state = {
			RequestTimes = {},
			LastCollectAt = -math.huge,
			Rejects = 0,
			RejectWindowStart = 0,
			AutoTickErrorReported = false,
		}
		playerStates[player] = state
	end
	return state
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
	if state.Rejects == CollectionConfig.SuspiciousRejectThreshold then
		warn(
			`[CollectionSystem] Подозрительная активность: {player.Name} ({player.UserId}), `
				.. `{state.Rejects} отклонённых RequestCollect за {REJECT_LOG_WINDOW} с, последняя причина: {reason}`
		)
	end
end

-- Из реестра — сразу (второй сбор того же фрагмента невозможен), Part — через кадр: атрибуты,
-- выставленные в том же кадре, что и Destroy / Parent = nil, до клиента не доходят (проверено
-- в Studio: task.defer тоже не помогает, task.wait() — да). Запрос RequestCollect к уже
-- собранному, но ещё видимому Part получает обычный отказ no-such-fragment.
local function removeFragment(fragment: Fragment)
	fragments[fragment.Id] = nil
	occupiedPoints[fragment.ZoneId][fragment.PointIndex] = nil
	zoneCounts[fragment.ZoneId] -= 1
	local part = fragment.Part
	task.spawn(function()
		task.wait()
		part:Destroy()
	end)
end

-- Part — хитбокс касания и запасной визуал (шар цвета эмоции), если клиентский кристалл
-- (Visuals/FragmentVisuals) ещё не построен.
local function createFragmentPart(id: number, position: Vector3, emotionType: EmotionType, biomeId: string): Part
	local part = Instance.new("Part")
	part.Name = `DreamFragment_{id}`
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.new(2, 2, 2)
	part.Material = Enum.Material.Neon
	part.Color = VisualConfig.EmotionColors[emotionType]
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.Position = position
	part:SetAttribute(ID_ATTRIBUTE, id)
	part:SetAttribute(Attributes.FragmentEmotion, emotionType)
	part:SetAttribute(Attributes.FragmentBiome, biomeId)
	-- Подписи над фрагментом нет: сбор — касанием (CollectionController), сигнал «можно
	-- собрать» — сам светящийся кристалл с частицами.
	return part
end

local function spawnFragmentInZone(zone: CollectionConfig.ZoneDefinition, folder: Folder): boolean
	local occupied = occupiedPoints[zone.Id]

	local free: { number } = {}
	for index in zone.SpawnPoints do
		if not occupied[index] then
			table.insert(free, index)
		end
	end
	if #free == 0 then
		return false
	end

	local pointIndex = free[math.random(#free)]
	local position = zone.SpawnPoints[pointIndex]
	local id = nextFragmentId
	nextFragmentId += 1

	local emotionType = CollectionSystem.RollEmotionType(rng:NextNumber())
	local part = createFragmentPart(id, position, emotionType, zone.BiomeId)
	fragments[id] = {
		Id = id,
		Part = part,
		Position = position,
		ZoneId = zone.Id,
		PointIndex = pointIndex,
		EmotionType = emotionType,
	}
	occupied[pointIndex] = true
	zoneCounts[zone.Id] += 1
	part.Parent = folder
	return true
end

local function spawnTick(folder: Folder)
	for _, zone in CollectionConfig.Zones do
		local spawned = 0
		while
			spawned < CollectionConfig.SpawnPerTick
			and zoneCounts[zone.Id] < zone.MaxFragments
			and spawnFragmentInZone(zone, folder)
		do
			spawned += 1
		end
	end
end

-- Радиус сбора — одна формула для магнита и ручного сбора: фиксированный радиус магнита
-- из конфига × бонус Nostalgic-петов (зажат PetSpeciesConfig.MaxMultiplier). Профиль не
-- участвует: апгрейд CollectionRadius снят с продажи, Collection.RadiusLevel не читается.
local function getCollectRadius(player: Player): number
	return AutoCollectorConfig.Radius * PetSystem.GetCachedBonuses(player).CollectionRadiusMultiplier
end

local function getCooldown(data: PlayerProfile): number
	return UpgradeEffects.GetEffectValue("CollectionSpeed", data.Collection.SpeedLevel)
end

local function getStorageCapacity(data: PlayerProfile): number
	return UpgradeEffects.GetEffectValue("StorageCapacity", data.Factory.StorageCapacityLevel)
end

-- Единая транзакция сбора — и для RequestCollect (mode "Touch"), и для магнита ("Magnet"):
-- проверки и запись без yield. Возвращает nil при успехе или причину отказа (для лога;
-- клиенту не отправляется). Первая проверка — фрагмент всё ещё в реестре: собранный
-- (кем угодно и каким угодно путём) фрагмент второй раз не засчитывается.
local function collectFragment(
	player: Player,
	data: PlayerProfile,
	fragment: Fragment,
	now: number,
	mode: CollectMode
): string?
	if fragments[fragment.Id] ~= fragment then
		return "no-such-fragment"
	end

	local state = getPlayerState(player)
	if now - state.LastCollectAt < getCooldown(data) then
		return "cooldown"
	end

	local rootPosition = MovementGuard.GetTrustedPosition(player)
	if not rootPosition then
		return "no-character"
	end

	local maxDistance = getCollectRadius(player) + CollectionConfig.DistanceTolerance
	-- «не (≤)», а не «>»: NaN-дистанция — отказ, а не проход.
	if not ((rootPosition - fragment.Position).Magnitude <= maxDistance) then
		return "too-far"
	end

	local buffer = data.Factory.RawFragments
	local stored = FragmentBuffer.Total(buffer)
	if stored == nil then
		return "corrupt-buffer" -- о порче сообщит конвейер; фрагмент остаётся в мире
	end
	local space = getStorageCapacity(data) - stored
	if space <= 0 then
		return "storage-full" -- фрагмент остаётся в мире
	end

	buffer[fragment.EmotionType] += math.min(CollectionConfig.FragmentValue, space)
	state.LastCollectAt = now
	-- Только визуал: Part уничтожается через кадр (removeFragment), атрибуты успевают дойти.
	fragment.Part:SetAttribute(Attributes.FragmentCollectMode, mode)
	fragment.Part:SetAttribute(Attributes.FragmentCollectedBy, player.UserId)
	removeFragment(fragment)
	AnalyticsSystem.RecordFunnelStep(player, data, "FirstCollect")
	return nil
end

-- Ручной сбор по id от клиента: разбор аргумента и поиск в реестре, дальше — collectFragment.
local function tryCollect(player: Player, fragmentId: unknown, now: number): string?
	if type(fragmentId) ~= "number" or fragmentId ~= fragmentId or fragmentId % 1 ~= 0 then
		return "bad-argument"
	end

	local fragment = fragments[fragmentId]
	if not fragment then
		return "no-such-fragment" -- не существует или уже собран
	end

	local data = DataSystem.GetData(player)
	if not data then
		return "no-profile"
	end

	return collectFragment(player, data, fragment, now, "Touch")
end

-- Владение авто-сборщиком — только по Monetization.GamePassesOwned; битый раздел = не владеет.
local function ownsAutoCollector(data: PlayerProfile): boolean
	local monetization = (data :: any).Monetization
	if type(monetization) ~= "table" then
		return false
	end
	local owned = monetization.GamePassesOwned
	if type(owned) ~= "table" then
		return false
	end
	for _, id in owned do
		if id == AutoCollectorConfig.GamePassId then
			return true
		end
	end
	return false
end

-- Есть ли у игрока магнит сейчас: геймпасс Авто-сборщика или действующий бафф Magnet Boost.
local function hasMagnet(data: PlayerProfile): boolean
	return ownsAutoCollector(data) or BuffSystem.IsActive(data, "MagnetBoost")
end

-- Магнит одного игрока: ближайший фрагмент в радиусе → collectFragment.
-- Один кандидат за тик: общий кулдаун всё равно пропустит не больше одного сбора,
-- а при отказе по складу/персонажу откажут и все остальные.
local function autoCollectFor(player: Player, now: number)
	local data = DataSystem.GetData(player)
	if not data or not hasMagnet(data) then
		return
	end

	local rootPosition = MovementGuard.GetTrustedPosition(player)
	if not rootPosition then
		return
	end

	local nearest: Fragment? = nil
	local nearestDistance = getCollectRadius(player)
	for _, fragment in fragments do
		local distance = (rootPosition - fragment.Position).Magnitude
		if distance <= nearestDistance then
			nearest = fragment
			nearestDistance = distance
		end
	end

	if nearest then
		-- Отказ здесь не подозрителен (инициатор — сервер), в registerReject не пишем.
		collectFragment(player, data, nearest, now, "Magnet")
	end
end

local function autoCollectTick()
	local now = os.clock()
	for _, player in Players:GetPlayers() do
		local ok, err = pcall(autoCollectFor, player, now)
		if not ok then
			-- Состояние вышедшего игрока (Parent = nil) не воскрешаем — иначе утечка в playerStates.
			local state = if player.Parent then getPlayerState(player) else nil
			if state and not state.AutoTickErrorReported then
				state.AutoTickErrorReported = true
				warn(`[CollectionSystem] Ошибка авто-сборщика у {player.Name} ({player.UserId}): {err}`)
			end
		end
	end
end

local function onRequestCollect(player: Player, fragmentId: unknown)
	-- Запрос после PlayerRemoving: getPlayerState пересоздал бы запись, которую уже никто
	-- не очистит (утечка).
	if player.Parent == nil then
		return
	end
	local now = os.clock()
	local state = getPlayerState(player)

	if not RateLimiter.Allow(state.RequestTimes, now, CollectionConfig.RequestWindow, CollectionConfig.MaxRequestsPerWindow) then
		registerReject(player, "rate-limit", now)
		return
	end

	local reason = tryCollect(player, fragmentId, now)
	if reason then
		registerReject(player, reason, now)
	end
end

function CollectionSystem.Init()
	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = Workspace

	for _, zone in CollectionConfig.Zones do
		occupiedPoints[zone.Id] = {}
		zoneCounts[zone.Id] = 0
	end

	Remotes.RequestCollect.OnServerEvent:Connect(onRequestCollect)

	Players.PlayerRemoving:Connect(function(player)
		playerStates[player] = nil
	end)

	task.spawn(function()
		while true do
			spawnTick(folder)
			task.wait(CollectionConfig.SpawnInterval)
		end
	end)

	task.spawn(function()
		while true do
			task.wait(AutoCollectorConfig.TickInterval)
			local ok, err = pcall(autoCollectTick)
			if not ok then
				warn(`[CollectionSystem] Ошибка тика авто-сборщика: {err}`)
			end
		end
	end)
end

return CollectionSystem
