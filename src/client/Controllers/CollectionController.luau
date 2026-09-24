--!strict

--[[
	CollectionController — только intent: по клику/касанию на фрагмент шлёт серверу
	RequestCollect(fragmentId). Проверки дистанции/кулдауна здесь нет — их делает сервер;
	локальный троттлинг нужен лишь чтобы не спамить remote.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Remotes = require(ReplicatedStorage.shared.Remotes)

local FOLDER_NAME = "DreamFragments"
local ID_ATTRIBUTE = "FragmentId"
local RAY_LENGTH = 500
local LOCAL_THROTTLE = 0.1

local CollectionController = {}

local lastRequestAt = 0

local function getFragmentAt(screenPosition: Vector2, folder: Folder): number?
	local camera = Workspace.CurrentCamera
	if not camera then
		return nil
	end

	local ray = camera:ScreenPointToRay(screenPosition.X, screenPosition.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { folder }

	local result = Workspace:Raycast(ray.Origin, ray.Direction * RAY_LENGTH, params)
	local id = result and result.Instance:GetAttribute(ID_ATTRIBUTE)
	return if type(id) == "number" then id else nil
end

function CollectionController.Init()
	local folder = Workspace:WaitForChild(FOLDER_NAME) :: Folder

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end

		local now = os.clock()
		if now - lastRequestAt < LOCAL_THROTTLE then
			return
		end

		local fragmentId = getFragmentAt(Vector2.new(input.Position.X, input.Position.Y), folder)
		if fragmentId then
			lastRequestAt = now
			Remotes.RequestCollect:FireServer(fragmentId)
		end
	end)
end

return CollectionController
