--!strict

--[[
	FactoryVisuals — конвейер «Фабрики снов» у точки спавна (VisualConfig.Factory.Origin).
	Модель локальная: каждый клиент видит на этом месте свою фабрику (отдельных участков у
	игроков пока нет).

	- Тело — VisualModels.Factory; лента — планки, циклически сдвигаемые вдоль ленты, пока в
	  буфере есть сырые фрагменты (снимок сервера RawFragments > 0); на ленте едут кристаллики
	  (не больше MaxRidingFragments) в цветах эмоций реального содержимого буфера
	  (RawFragmentsByEmotion, распределение мест — BeltLoad).
	- Вспышка переработки: FactorySystem.OnEssenceProduced — серверный сигнал, отдельного
	  ремоута нет, поэтому клиент узнаёт о переработке по снимку экономики (HUD.SnapshotChanged):
	  сырые фрагменты уменьшились, а Essence выросла (и это не ответ на Rebirth) — значит,
	  конвейер отработал цикл. Тогда — частицы у выхода и вспышка окна машины.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Types = require(ReplicatedStorage.shared.Types)
local VisualConfig = require(ReplicatedStorage.shared.Config.VisualConfig)
local VisualModels = require(ReplicatedStorage.shared.Config.VisualModels)
local Rig = require(script.Parent.Rig)
local Particles = require(script.Parent.Particles)
local BeltLoad = require(script.Parent.BeltLoad)

export type SnapshotSource = {
	GetSnapshot: () -> Types.EconomySnapshot?,
	SnapshotChanged: any,
}

local BELT_TOP_Y = 2.68 -- верх ленты в координатах модели
local SLAT_SIZE = Vector3.new(0.8, 0.15, 3)
local RIDER_SIZE = Vector3.new(0.6, 0.6, 0.6)

local FactoryVisuals = {}

local origin: CFrame
local slats: { BasePart } = {}
local riders: { BasePart } = {}
local windows: { BasePart } = {}
local output: BasePart?
local outputEmitter: ParticleEmitter?
local beltOffset = 0
local running = false
local ridersVisible = 0
local lastSnapshot: Types.EconomySnapshot? = nil

local function decorPart(size: Vector3, color: Color3, material: Enum.Material, parent: Instance): Part
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Size = size
	part.Color = color
	part.Material = material
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

local function flash()
	local cfg = VisualConfig.Factory
	if outputEmitter then
		outputEmitter:Emit(cfg.FlashParticleCount)
	end
	for _, window in windows do
		window.Color = Color3.new(1, 1, 1)
		TweenService:Create(window, TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Color = cfg.FlashColor,
		}):Play()
	end
	if output then
		output.Size = Vector3.new(2.4, 2.4, 2.4)
		TweenService:Create(output, TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Size = Vector3.new(1.6, 1.6, 1.6),
		}):Play()
	end
end

local function onSnapshot(snapshot: Types.EconomySnapshot)
	local previous = lastSnapshot
	lastSnapshot = snapshot
	local raw = if type(snapshot.RawFragments) == "number" then snapshot.RawFragments else 0
	running = raw > 0
	local load = BeltLoad.Allocate(snapshot.RawFragmentsByEmotion, #riders)
	ridersVisible = #load
	for index, emotion in load do
		riders[index].Color = (VisualConfig.EmotionColors :: any)[emotion]
	end
	if
		previous
		and snapshot.RebirthAck == nil
		and raw < previous.RawFragments
		and snapshot.Essence > previous.Essence
	then
		flash()
	end
end

local function step(dt: number)
	local cfg = VisualConfig.Factory
	local length = cfg.BeltLength
	if running then
		beltOffset = (beltOffset + cfg.BeltSpeed * dt) % length
	end
	local spacing = length / #slats
	local cframes: { CFrame } = {}
	local parts: { BasePart } = {}
	for index, slat in slats do
		local x = ((index - 1) * spacing + beltOffset) % length - length / 2
		table.insert(parts, slat)
		table.insert(cframes, origin * CFrame.new(x, BELT_TOP_Y, 0))
	end
	local t = os.clock()
	local riderSpacing = length / math.max(#riders, 1)
	for index, rider in riders do
		local visible = index <= ridersVisible
		rider.Transparency = if visible then 0.1 else 1
		if visible then
			local x = ((index - 1) * riderSpacing + beltOffset) % length - length / 2
			table.insert(parts, rider)
			table.insert(
				cframes,
				origin * CFrame.new(x, BELT_TOP_Y + 0.45, 0) * CFrame.Angles(math.rad(45), t + index, math.rad(35))
			)
		end
	end
	Workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
end

function FactoryVisuals.Init(source: SnapshotSource)
	local cfg = VisualConfig.Factory
	local folder = Rig.Folder("Factory")
	origin = CFrame.new(cfg.Origin) * CFrame.Angles(0, math.rad(cfg.YawDegrees), 0)

	local body = Rig.new(VisualModels.Factory, nil, folder, "FactoryBody")
	body:Update(origin, 0)
	windows = body:FindTagged("Window")
	output = body:FindTagged("Output")[1]
	if output then
		local light = Instance.new("PointLight")
		light.Color = cfg.FlashColor
		light.Brightness = 2
		light.Range = 10
		light.Parent = output
		outputEmitter = Particles.Emitter(output, {
			Color = ColorSequence.new(cfg.FlashColor, Color3.new(1, 1, 1)),
			Size = 0.45,
			Lifetime = NumberRange.new(0.5, 1),
			Rate = 0,
			Speed = NumberRange.new(4, 9),
			Acceleration = Vector3.new(0, 6, 0),
			Drag = 2,
		})
	end

	for _ = 1, cfg.SlatCount do
		table.insert(slats, decorPart(SLAT_SIZE, Color3.fromRGB(60, 55, 80), Enum.Material.SmoothPlastic, folder))
	end
	-- Цвет каждого кристаллика выставляет onSnapshot по содержимому буфера.
	for _ = 1, cfg.MaxRidingFragments do
		local rider = decorPart(RIDER_SIZE, Color3.new(1, 1, 1), Enum.Material.Neon, folder)
		rider.Transparency = 1
		table.insert(riders, rider)
	end

	local current = source.GetSnapshot()
	if current then
		onSnapshot(current)
	end
	source.SnapshotChanged:Connect(onSnapshot)
	RunService.RenderStepped:Connect(step)
end

return FactoryVisuals
