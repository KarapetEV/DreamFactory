--!strict

--[[
	CollectionController — автосбор при касании (жанр «симулятор»). Только intent:
	когда HumanoidRootPart локального игрока касается фрагмента, шлёт серверу
	RequestCollect(fragmentId). Дистанцию, кулдаун и ёмкость проверяет сервер (CollectionSystem);
	локальный троттлинг нужен лишь чтобы не спамить remote.

	Touched срабатывает только на само касание, а не пока персонаж стоит на фрагменте. Поэтому
	запрос, который сервер отклонил (кулдаун после соседнего фрагмента, лаг), потерялся бы навсегда.
	Касающиеся фрагменты держатся в наборе, и раз в LOCAL_THROTTLE секунд уходит ровно один запрос:
	по одному фрагменту не чаще RETRY_INTERVAL и не больше MAX_ATTEMPTS раз за касание — иначе при
	полном складе (сервер оставляет фрагмент в мире) игрок, стоящий на фрагменте, слал бы отказы бесконечно.
	Новое касание (вышел и вошёл) начинает попытки заново.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Remotes = require(game:GetService("ReplicatedStorage").shared.Remotes)

local FOLDER_NAME = "DreamFragments"
local ID_ATTRIBUTE = "FragmentId"
local ROOT_PART_NAME = "HumanoidRootPart"
local LOCAL_THROTTLE = 0.1
local RETRY_INTERVAL = 0.4 -- чуть больше серверного кулдауна между сборами
local MAX_ATTEMPTS = 3

type Touching = {
	Id: number,
	Attempts: number,
	LastSentAt: number,
}

local CollectionController = {}

local touching: { [BasePart]: Touching } = {}
local lastRequestAt = 0

-- Касание именно корневой частью персонажа локального игрока, а не чужого игрока или посторонней деталью.
local function isLocalRoot(hit: BasePart): boolean
	local character = Players.LocalPlayer.Character
	return character ~= nil and hit.Name == ROOT_PART_NAME and hit.Parent == character
end

local function trackFragment(instance: Instance)
	if not instance:IsA("BasePart") then
		return
	end
	local part = instance
	local id = part:GetAttribute(ID_ATTRIBUTE)
	if type(id) ~= "number" then
		return
	end

	-- Сервер создаёт фрагменты с CanTouch = false (они были рассчитаны на клик). Локальное
	-- включение влияет только на события касания у этого клиента; CanCollide остаётся false,
	-- поэтому персонаж проходит сквозь фрагмент, а не упирается в него.
	part.CanTouch = true

	part.Touched:Connect(function(hit: BasePart)
		if touching[part] == nil and isLocalRoot(hit) then
			touching[part] = { Id = id, Attempts = 0, LastSentAt = -math.huge }
		end
	end)
	part.TouchEnded:Connect(function(hit: BasePart)
		if isLocalRoot(hit) then
			touching[part] = nil
		end
	end)
end

-- Один запрос за вызов: под общим локальным троттлингом, по фрагментам, чья очередь пришла.
local function pump()
	local now = os.clock()
	if now - lastRequestAt < LOCAL_THROTTLE then
		return
	end

	for part, entry in touching do
		if part.Parent == nil then
			touching[part] = nil -- фрагмент собран (уничтожен сервером)
		elseif entry.Attempts < MAX_ATTEMPTS and now - entry.LastSentAt >= RETRY_INTERVAL then
			entry.Attempts += 1
			entry.LastSentAt = now
			lastRequestAt = now
			Remotes.RequestCollect:FireServer(entry.Id)
			return
		end
	end
end

function CollectionController.Init()
	local folder = Workspace:WaitForChild(FOLDER_NAME) :: Folder

	for _, child in folder:GetChildren() do
		trackFragment(child)
	end
	folder.ChildAdded:Connect(trackFragment)

	task.spawn(function()
		while true do
			task.wait(LOCAL_THROTTLE)
			pump()
		end
	end)
end

return CollectionController
