--!strict

-- Центральный реестр RemoteEvent'ов: инстансы создаются один раз (сервером) под
-- ReplicatedStorage.Remotes, клиент и сервер берут их отсюда, а не создают заново по имени.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local FOLDER_NAME = "Remotes"

local function getRemotesFolder(): Folder
	if RunService:IsServer() then
		local existing = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
		if existing then
			return existing :: Folder
		end

		local folder = Instance.new("Folder")
		folder.Name = FOLDER_NAME
		folder.Parent = ReplicatedStorage
		return folder
	end

	return ReplicatedStorage:WaitForChild(FOLDER_NAME) :: Folder
end

local function getRemoteEvent(folder: Folder, name: string): RemoteEvent
	if RunService:IsServer() then
		local existing = folder:FindFirstChild(name)
		if existing then
			return existing :: RemoteEvent
		end

		local remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = folder
		return remote
	end

	return folder:WaitForChild(name) :: RemoteEvent
end

local folder = getRemotesFolder()

export type RemoteRegistry = {
	-- CollectionSystem (раздел 5.1)
	RequestCollect: RemoteEvent,
	-- FactorySystem (раздел 5.2)
	PurchaseUpgrade: RemoteEvent,
	-- Сервер → клиент: снимок экономики игрока (Types.EconomySnapshot), шлёт FactorySystem.
	EconomySnapshot: RemoteEvent,
	-- PetSystem (раздел 5.3)
	HatchCocoon: RemoteEvent,
	EquipPet: RemoteEvent,
	UnequipPet: RemoteEvent,
	-- Сервер → клиент: петы игрока и лимит слотов (Types.PetSnapshot), шлёт PetSystem.
	PetSnapshot: RemoteEvent,
	-- RebirthSystem (раздел 5.4)
	PerformRebirth: RemoteEvent,
	-- ChaosBossSystem (раздел 5.5)
	RequestAttackBoss: RemoteEvent,
	-- PvPRaidSystem (раздел 5.6)
	RequestRaidStart: RemoteEvent,
}

local Remotes: RemoteRegistry = {
	RequestCollect = getRemoteEvent(folder, "RequestCollect"),
	PurchaseUpgrade = getRemoteEvent(folder, "PurchaseUpgrade"),
	EconomySnapshot = getRemoteEvent(folder, "EconomySnapshot"),
	HatchCocoon = getRemoteEvent(folder, "HatchCocoon"),
	EquipPet = getRemoteEvent(folder, "EquipPet"),
	UnequipPet = getRemoteEvent(folder, "UnequipPet"),
	PetSnapshot = getRemoteEvent(folder, "PetSnapshot"),
	PerformRebirth = getRemoteEvent(folder, "PerformRebirth"),
	RequestAttackBoss = getRemoteEvent(folder, "RequestAttackBoss"),
	RequestRaidStart = getRemoteEvent(folder, "RequestRaidStart"),
}

return Remotes
