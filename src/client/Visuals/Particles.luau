--!strict

--[[
	Particles — сборка ParticleEmitter'ов со стандартной текстурой Roblox и общий пул разовых
	вспышек (Burst) под бюджетом EffectBudget (VisualConfig.Effects): при плотном сборе
	лишние вспышки отбрасываются, а не копятся. Вспышки дальше BurstVisibleDistance от камеры
	не играют вовсе.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VisualConfig = require(ReplicatedStorage.shared.Config.VisualConfig)
local EffectBudget = require(script.Parent.EffectBudget)

export type EmitterOptions = {
	Color: Color3 | ColorSequence,
	Size: number | NumberSequence,
	Transparency: NumberSequence?,
	Lifetime: NumberRange,
	Rate: number,
	Speed: NumberRange,
	SpreadAngle: Vector2?,
	LightEmission: number?,
	Shape: Enum.ParticleEmitterShape?,
	ShapeStyle: Enum.ParticleEmitterShapeStyle?,
	ShapeInOut: Enum.ParticleEmitterShapeInOut?,
	Acceleration: Vector3?,
	Drag: number?,
	RotSpeed: NumberRange?,
	LockedToPart: boolean?,
	ZOffset: number?,
}

local Particles = {}

local DEFAULT_TRANSPARENCY = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0.2),
	NumberSequenceKeypoint.new(0.7, 0.4),
	NumberSequenceKeypoint.new(1, 1),
})

function Particles.Emitter(parent: Instance, options: EmitterOptions): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = if typeof(options.Color) == "Color3"
		then ColorSequence.new(options.Color :: Color3)
		else options.Color :: ColorSequence
	emitter.Size = if type(options.Size) == "number"
		then NumberSequence.new({
			NumberSequenceKeypoint.new(0, options.Size :: number),
			NumberSequenceKeypoint.new(1, 0),
		})
		else options.Size :: NumberSequence
	emitter.Transparency = options.Transparency or DEFAULT_TRANSPARENCY
	emitter.Lifetime = options.Lifetime
	emitter.Rate = options.Rate
	emitter.Speed = options.Speed
	emitter.SpreadAngle = options.SpreadAngle or Vector2.new(180, 180)
	emitter.LightEmission = options.LightEmission or 1
	emitter.Shape = options.Shape or Enum.ParticleEmitterShape.Box
	emitter.ShapeStyle = options.ShapeStyle or Enum.ParticleEmitterShapeStyle.Volume
	emitter.ShapeInOut = options.ShapeInOut or Enum.ParticleEmitterShapeInOut.Outward
	emitter.Acceleration = options.Acceleration or Vector3.zero
	emitter.Drag = options.Drag or 0
	emitter.RotSpeed = options.RotSpeed or NumberRange.new(-90, 90)
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.LockedToPart = options.LockedToPart or false
	emitter.ZOffset = options.ZOffset or 0
	emitter.Parent = parent
	return emitter
end

-- Пул вспышек: по эмиттеру на слот бюджета, на Attachment в Terrain.
local budget = EffectBudget.new(
	VisualConfig.Effects.MaxConcurrentBursts,
	VisualConfig.Effects.MaxBurstsPerSecond,
	VisualConfig.Effects.BurstLifetime
)
local pool: { { Attachment: Attachment, Emitter: ParticleEmitter } } = {}

local function getSlot(index: number)
	local slot = pool[index]
	if slot then
		return slot
	end
	local attachment = Instance.new("Attachment")
	attachment.Name = "VisualBurst"
	attachment.Parent = Workspace.Terrain
	local emitter = Particles.Emitter(attachment, {
		Color = Color3.new(1, 1, 1),
		Size = 0.5,
		Lifetime = NumberRange.new(0.4, 0.9),
		Rate = 0,
		Speed = NumberRange.new(6, 12),
		Drag = 4,
		Acceleration = Vector3.new(0, 4, 0),
	})
	slot = { Attachment = attachment, Emitter = emitter }
	pool[index] = slot
	return slot
end

local function visibleFrom(position: Vector3): boolean
	local camera = Workspace.CurrentCamera
	return camera == nil
		or (camera.CFrame.Position - position).Magnitude <= VisualConfig.Effects.BurstVisibleDistance
end

-- Разовая вспышка count частиц цвета color в точке position (под общим бюджетом).
-- Возвращает false, если вспышка отброшена бюджетом или дальностью.
function Particles.Burst(position: Vector3, color: Color3, count: number, size: number?): boolean
	if not visibleFrom(position) then
		return false
	end
	local index = budget:TryAcquire(os.clock())
	if not index then
		return false
	end
	local slot = getSlot(index)
	slot.Attachment.WorldPosition = position
	slot.Emitter.Color = ColorSequence.new(color)
	local s = size or 0.5
	slot.Emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, s), NumberSequenceKeypoint.new(1, 0) })
	slot.Emitter:Emit(count)
	return true
end

return Particles
