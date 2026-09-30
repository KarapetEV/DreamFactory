--!strict

--[[
	Aura — слой редкости поверх базовой модели пета (один меш на вид): по
	VisualConfig.RarityAura[rarity] вешает на Anchor рига свет (Glow), частицы с поверхности
	габарита (ContourParticles), объёмное облако (FullAura) и у Secret — вращающийся
	радужный маркер-звезду над головой. Мутация — отдельные белые искры.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VisualConfig = require(ReplicatedStorage.shared.Config.VisualConfig)
local Particles = require(script.Parent.Particles)
local Rig = require(script.Parent.Rig)

export type Aura = {
	-- Вызывать каждый кадр после rig:Update (маркер следует за моделью).
	Update: (self: Aura, t: number) -> (),
}

local MARKER_GAP = 1.2 -- studs над верхом габарита
local MARKER_SIZE = 0.9

local Aura = {}
Aura.__index = Aura

local function markerPart(parent: Instance, rotation: number): Part
	local part = Instance.new("Part")
	part.Name = "SecretMarker"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Size = Vector3.new(MARKER_SIZE, MARKER_SIZE, 0.15)
	part:SetAttribute("Rotation", rotation)
	part.Parent = parent
	return part
end

function Aura.Apply(rig: Rig.Rig, rarity: string, mutated: boolean): Aura
	local tier = VisualConfig.RarityAura[rarity] or VisualConfig.RarityAura.Common
	local anchor = rig.Anchor
	local extent = math.max(anchor.Size.X, anchor.Size.Y, anchor.Size.Z)

	if tier.Glow then
		local light = Instance.new("PointLight")
		light.Color = tier.Color
		light.Brightness = tier.LightBrightness
		light.Range = extent * 2 + 4
		light.Shadows = false
		light.Parent = anchor
	end
	if tier.ContourParticles then
		Particles.Emitter(anchor, {
			Color = tier.Color,
			Size = 0.25,
			Lifetime = NumberRange.new(0.6, 1),
			Rate = tier.ParticleRate,
			Speed = NumberRange.new(0.2, 0.6),
			Shape = Enum.ParticleEmitterShape.Box,
			ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface,
			Acceleration = Vector3.new(0, 1, 0),
		})
	end
	if tier.FullAura then
		Particles.Emitter(anchor, {
			Color = ColorSequence.new(tier.Color, Color3.new(1, 1, 1)),
			Size = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.2),
				NumberSequenceKeypoint.new(0.4, extent * 0.35),
				NumberSequenceKeypoint.new(1, 0),
			}),
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(0.3, 0.75),
				NumberSequenceKeypoint.new(1, 1),
			}),
			Lifetime = NumberRange.new(1, 1.6),
			Rate = tier.ParticleRate * 0.6,
			Speed = NumberRange.new(0.3, 0.8),
			Shape = Enum.ParticleEmitterShape.Sphere,
			Acceleration = Vector3.new(0, 1.5, 0),
			ZOffset = -1,
		})
	end
	if mutated then
		Particles.Emitter(anchor, {
			Color = Color3.new(1, 1, 1),
			Size = 0.18,
			Lifetime = NumberRange.new(0.3, 0.6),
			Rate = VisualConfig.Pets.MutationSparkleRate,
			Speed = NumberRange.new(0, 0.2),
			ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface,
		})
	end

	local markers: { Part } = {}
	if tier.SecretMarker then
		table.insert(markers, markerPart(rig.Model, 0))
		table.insert(markers, markerPart(rig.Model, 45))
		local light = Instance.new("PointLight")
		light.Brightness = 2
		light.Range = 6
		light.Parent = markers[1]
	end

	return (setmetatable({ _rig = rig, _markers = markers }, Aura) :: any) :: Aura
end

function Aura.Update(self: any, t: number)
	local markers: { Part } = self._markers
	if #markers == 0 then
		return
	end
	local anchor: BasePart = self._rig.Anchor
	local top = anchor.CFrame * CFrame.new(0, anchor.Size.Y / 2 + MARKER_GAP + math.sin(t * 2) * 0.15, 0)
	local color = Color3.fromHSV((t * 0.25) % 1, 0.7, 1)
	for _, marker in markers do
		marker.CFrame = CFrame.new(top.Position)
			* CFrame.Angles(0, t * 2, 0)
			* CFrame.Angles(0, 0, math.rad(marker:GetAttribute("Rotation") :: number))
		marker.Color = color
	end
	local light = markers[1]:FindFirstChildOfClass("PointLight")
	if light then
		light.Color = color
	end
end

return Aura
