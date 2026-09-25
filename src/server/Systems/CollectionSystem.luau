--!strict

--[[
	CollectionSystem — спавн и сбор фрагментов снов (раздел 5.1 ТЗ, анти-чит — раздел 7).

	- Сервер по таймеру спавнит фрагменты (анкеренные Part) в зонах из CollectionConfig
	  в Workspace.DreamFragments; клиент их только видит и присылает intent RequestCollect(fragmentId).
	- Клиенту не доверяем ничего, кроме id: позиция фрагмента берётся из серверного реестра,
	  позиция игрока — из его персонажа на сервере, радиус/кулдаун/ёмкость — из уровней профиля
	  и UpgradeConfig (UpgradeEffects зажимает уровень в [0, MaxLevel] — эффект не растёт без предела).
	- Сбор — одна функция без yield между проверками и записью: фрагмент забирает ровно один игрок,
	  буфер не выходит за ёмкость склада.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Types = require(ReplicatedStorage.shared.Types)
local Remotes = require(ReplicatedStorage.shared.Remotes)
local BiomeConfig = require(ReplicatedStorage.shared.Config.BiomeConfig)
local CollectionConfig = require(ReplicatedStorage.shared.Config.CollectionConfig)
local UpgradeEffects = require(ReplicatedStorage.shared.UpgradeEffects)
local DataSystem = require(script.Parent.DataSystem)
local RateLimiter = require(script.Parent.Parent.Services.RateLimiter)

type PlayerProfile = Types.PlayerProfile

type Fragment = {
	Id: number,
	Part: Part,
	Position: Vector3,
	ZoneId: string,
	PointIndex: number,
}

type PlayerState = {
	RequestTimes: { number }, -- метки времени вызовов в текущем окне rate limit
	LastCollectAt: number,
	Rejects: number,
	RejectWindowStart: number,
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

local function getPlayerState(player: Player): PlayerState
	local state = playerStates[player]
	if not state then
		state = {
			RequestTimes = {},
			LastCollectAt = -math.huge,
			Rejects = 0,
			RejectWindowStart = 0,
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

local function removeFragment(fragment: Fragment)
	fragments[fragment.Id] = nil
	occupiedPoints[fragment.ZoneId][fragment.PointIndex] = nil
	zoneCounts[fragment.ZoneId] -= 1
	fragment.Part:Destroy()
end

local function createFragmentPart(id: number, position: Vector3): Part
	local part = Instance.new("Part")
	part.Name = `DreamFragment_{id}`
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.new(2, 2, 2)
	part.Material = Enum.Material.Neon
	part.Color = Color3.fromRGB(170, 140, 255)
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.Position = position
	part:SetAttribute(ID_ATTRIBUTE, id)

	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(100, 30)
	gui.StudsOffset = Vector3.new(0, 2.5, 0)
	gui.AlwaysOnTop = true
	gui.Parent = part

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = CollectionConfig.PromptText
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.5
	label.TextScaled = true
	label.Parent = gui

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

	local part = createFragmentPart(id, position)
	fragments[id] = {
		Id = id,
		Part = part,
		Position = position,
		ZoneId = zone.Id,
		PointIndex = pointIndex,
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

-- Радиус не больше значения на MaxLevel: уровень из профиля зажимается в UpgradeEffects (M-1).
local function getCollectRadius(data: PlayerProfile): number
	return UpgradeEffects.GetEffectValue("CollectionRadius", data.Collection.RadiusLevel)
end

local function getCooldown(data: PlayerProfile): number
	return UpgradeEffects.GetEffectValue("CollectionSpeed", data.Collection.SpeedLevel)
end

local function getStorageCapacity(data: PlayerProfile): number
	return UpgradeEffects.GetEffectValue("StorageCapacity", data.Factory.StorageCapacityLevel)
end

-- Единая транзакция сбора: проверки и запись без yield. Возвращает nil при успехе
-- или причину отказа (для лога; клиенту причина не отправляется).
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

	local state = getPlayerState(player)
	if now - state.LastCollectAt < getCooldown(data) then
		return "cooldown"
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
		return "no-character"
	end

	local maxDistance = getCollectRadius(data) + CollectionConfig.DistanceTolerance
	if (root.Position - fragment.Position).Magnitude > maxDistance then
		return "too-far"
	end

	local space = getStorageCapacity(data) - data.Factory.RawFragments
	if space <= 0 then
		return "storage-full" -- фрагмент остаётся в мире
	end

	data.Factory.RawFragments += math.min(CollectionConfig.FragmentValue, space)
	state.LastCollectAt = now
	removeFragment(fragment)
	return nil
end

local function onRequestCollect(player: Player, fragmentId: unknown)
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
end

return CollectionSystem
