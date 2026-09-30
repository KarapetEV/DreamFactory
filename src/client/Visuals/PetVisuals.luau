--!strict

--[[
	PetVisuals — петы, следующие за игроками. Состав надетых петов каждого игрока сервер пишет
	в атрибут Attributes.EquippedPets (EquippedPetsCodec); клиент строит по модели на пета
	(VisualModels.Pets[вид], одна на вид) и слой редкости (Aura). Все модели — локальные.

	Движение процедурное (CFrame, без Animation Editor):
	- Follow: целевая точка — «строй» за спиной владельца (до 3 в ряд), позиция догоняет её
	  экспоненциально (VisualConfig.Pets.Responsiveness) — отсюда небольшой лаг; пет смотрит
	  по направлению движения, стоя — туда же, куда владелец;
	- Idle: покачивание по синусу; ходящие виды при движении подпрыгивают, летающие парят;
	- Swing/Spin деталей (крылья, хвосты, щупальца) — из спецификации модели (Rig).
	Петы дальше RenderDistance от камеры скрыты и не обновляются; всего моделей не больше
	MaxRendered (свои петы — в приоритете).
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Attributes = require(ReplicatedStorage.shared.Attributes)
local EquippedPetsCodec = require(ReplicatedStorage.shared.EquippedPetsCodec)
local VisualConfig = require(ReplicatedStorage.shared.Config.VisualConfig)
local VisualModels = require(ReplicatedStorage.shared.Config.VisualModels)
local Rig = require(script.Parent.Rig)
local Aura = require(script.Parent.Aura)

local PER_ROW = 3
local ROW_GAP = 3
local WALKER_HOVER_LIMIT = 2 -- Hover ниже — вид ходит по земле, выше — летает

type PetEntry = {
	Rig: Rig.Rig,
	Aura: Aura.Aura,
	Hover: number,
	Flying: boolean,
	Phase: number,
	Position: Vector3?,
	Facing: CFrame,
}

type OwnerState = {
	Player: Player,
	Pets: { PetEntry },
	Connection: RBXScriptConnection,
	Visible: boolean,
}

local PetVisuals = {}

local owners: { [Player]: OwnerState } = {}
local folder: Folder

local function renderedCount(): number
	local count = 0
	for _, state in owners do
		count += #state.Pets
	end
	return count
end

local function clearPets(state: OwnerState)
	for _, pet in state.Pets do
		pet.Rig:Destroy()
	end
	table.clear(state.Pets)
end

-- Модель пета на витрину/для следования: риг + аура редкости. Используется и CocoonEffect.
function PetVisuals.BuildPet(speciesId: string, rarity: string, mutated: boolean, parent: Instance?): (Rig.Rig?, Aura.Aura?)
	local spec = VisualModels.Pets[speciesId]
	if not spec then
		return nil, nil
	end
	local rig = Rig.new(spec, nil, parent or folder, speciesId)
	return rig, Aura.Apply(rig, rarity, mutated)
end

local function rebuild(state: OwnerState)
	clearPets(state)
	local decoded = EquippedPetsCodec.Decode(state.Player:GetAttribute(Attributes.EquippedPets))
	local isLocal = state.Player == Players.LocalPlayer
	for index, pet in decoded do
		if not isLocal and renderedCount() >= VisualConfig.Pets.MaxRendered then
			break
		end
		local rig, aura = PetVisuals.BuildPet(pet.SpeciesId, pet.Rarity, pet.Mutated)
		local spec = VisualModels.Pets[pet.SpeciesId]
		if rig and aura and spec then
			table.insert(state.Pets, {
				Rig = rig,
				Aura = aura,
				Hover = spec.Hover,
				Flying = spec.Hover > WALKER_HOVER_LIMIT,
				Phase = index * 1.3 + state.Player.UserId % 7,
				Position = nil,
				Facing = CFrame.identity,
			})
		end
	end
	state.Visible = true
end

local function addOwner(player: Player)
	if owners[player] then
		return
	end
	local state: OwnerState = {
		Player = player,
		Pets = {},
		Connection = nil :: any,
		Visible = true,
	}
	state.Connection = player:GetAttributeChangedSignal(Attributes.EquippedPets):Connect(function()
		rebuild(state)
	end)
	owners[player] = state
	rebuild(state)
end

local function removeOwner(player: Player)
	local state = owners[player]
	if not state then
		return
	end
	owners[player] = nil
	state.Connection:Disconnect()
	clearPets(state)
end

local function setVisible(state: OwnerState, visible: boolean)
	if state.Visible == visible then
		return
	end
	state.Visible = visible
	for _, pet in state.Pets do
		pet.Rig.Model.Parent = if visible then folder else nil
	end
end

local function stepOwner(state: OwnerState, cameraPosition: Vector3, t: number, dt: number)
	local character = state.Player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not root or #state.Pets == 0 then
		setVisible(state, false)
		return
	end
	local rootCFrame = root.CFrame
	local visible = (rootCFrame.Position - cameraPosition).Magnitude <= VisualConfig.Pets.RenderDistance
	setVisible(state, visible)
	if not visible then
		return
	end

	local cfg = VisualConfig.Pets
	local hipHeight = if humanoid then humanoid.HipHeight else 2
	local groundY = rootCFrame.Position.Y - hipHeight - root.Size.Y / 2
	local ownerLook = Vector3.new(rootCFrame.LookVector.X, 0, rootCFrame.LookVector.Z)
	local alpha = 1 - math.exp(-cfg.Responsiveness * dt)
	local count = #state.Pets

	for index, pet in state.Pets do
		local row = (index - 1) // PER_ROW
		local inRow = math.min(PER_ROW, count - row * PER_ROW)
		local column = (index - 1) % PER_ROW
		local side = (column - (inRow - 1) / 2) * cfg.SideSpacing
		local back = cfg.FollowBack + row * ROW_GAP
		local target = (rootCFrame * CFrame.new(side, 0, back)).Position
		target = Vector3.new(target.X, groundY + pet.Hover, target.Z)

		local previous = pet.Position or target
		local position = previous:Lerp(target, alpha)
		pet.Position = position

		local velocity = if dt > 0 then (position - previous) / dt else Vector3.zero
		local flat = Vector3.new(velocity.X, 0, velocity.Z)
		local moving = flat.Magnitude > 0.5
		local look = if moving then flat.Unit elseif ownerLook.Magnitude > 0 then ownerLook.Unit else Vector3.zAxis
		local desired = CFrame.lookAt(Vector3.zero, look)
		pet.Facing = pet.Facing:Lerp(desired, 1 - math.exp(-8 * dt))

		local bob = math.sin(t * cfg.IdleBobSpeed + pet.Phase) * cfg.IdleBobAmplitude
		if not pet.Flying then
			-- Ходящие: лёгкое покачивание стоя, подскоки на ходу (не уходят под землю).
			bob = if moving then math.abs(math.sin(t * 10 + pet.Phase)) * 0.35 else math.abs(bob) * 0.4
		end
		local tilt = if pet.Flying and moving then CFrame.Angles(math.rad(-8), 0, 0) else CFrame.identity
		local pivot = CFrame.new(position + Vector3.new(0, bob, 0)) * pet.Facing * tilt
		pet.Rig:Update(pivot, t + pet.Phase)
		pet.Aura:Update(t)
	end
end

local function step(dt: number)
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local cameraPosition = camera.CFrame.Position
	local t = os.clock()
	for _, state in owners do
		stepOwner(state, cameraPosition, t, dt)
	end
end

function PetVisuals.Init()
	folder = Rig.Folder("Pets")
	-- Свои петы строятся первыми: при упоре в MaxRendered в приоритете.
	addOwner(Players.LocalPlayer)
	for _, player in Players:GetPlayers() do
		addOwner(player)
	end
	Players.PlayerAdded:Connect(addOwner)
	Players.PlayerRemoving:Connect(removeOwner)
	RunService.RenderStepped:Connect(step)
end

return PetVisuals
