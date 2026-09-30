--!strict

--[[
	FragmentVisuals — вид фрагментов снов. Сервер создаёт в Workspace.DreamFragments Part-хитбокс
	(шар цвета эмоции — запасной визуал) с атрибутами Attributes.FragmentEmotion/FragmentBiome.
	Клиент прячет шар локально и строит на его месте огранённый кристалл
	(VisualModels.FragmentCrystal): цвет, свет и частицы — по эмоции (основной сигнал), кольцо
	под кристаллом — цвет-акцент биома (вторичный). Покачивание и вращение — процедурные.

	- Дальше VisualConfig.Fragment.LodDistance от камеры кристалл не двигается и не пылит.
	- Исчезновение фрагмента (сбор кем угодно) — вспышка частиц через общий бюджет Particles.Burst:
	  при плотном сборе лишние вспышки отбрасываются.
	- Касание/сбор не трогаем: хитбокс — серверный Part, CollectionController работает с ним.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Attributes = require(ReplicatedStorage.shared.Attributes)
local BiomeConfig = require(ReplicatedStorage.shared.Config.BiomeConfig)
local VisualConfig = require(ReplicatedStorage.shared.Config.VisualConfig)
local VisualModels = require(ReplicatedStorage.shared.Config.VisualModels)
local Rig = require(script.Parent.Rig)
local Particles = require(script.Parent.Particles)

local FOLDER_NAME = "DreamFragments"
local NEUTRAL_ACCENT = Color3.fromRGB(200, 200, 220)

type Entry = {
	Rig: Rig.Rig,
	Base: CFrame,
	Phase: number,
	Color: Color3,
	Emitter: ParticleEmitter,
	Near: boolean,
}

local FragmentVisuals = {}

local entries: { [BasePart]: Entry } = {}
local folder: Folder

local function track(instance: Instance)
	if not instance:IsA("BasePart") or entries[instance] then
		return
	end
	local emotion = instance:GetAttribute(Attributes.FragmentEmotion)
	local color = if type(emotion) == "string" then (VisualConfig.EmotionColors :: any)[emotion] else nil
	if not color then
		return -- без эмоции остаётся серверный шар
	end
	local biome = BiomeConfig[instance:GetAttribute(Attributes.FragmentBiome) :: any]
	local accent = if biome then biome.AccentColor else NEUTRAL_ACCENT

	instance.Transparency = 1 -- локально: серверный шар заменён кристаллом
	local rig = Rig.new(VisualModels.FragmentCrystal, { Emotion = color, Biome = accent }, folder, instance.Name)
	for _, ring in rig:FindTagged("BiomeRing") do
		ring.Transparency = VisualConfig.Fragment.BiomeRingTransparency
	end

	local light = Instance.new("PointLight")
	light.Color = color
	light.Brightness = 1.2
	light.Range = 9
	light.Shadows = false
	light.Parent = rig.Anchor

	local emitter = Particles.Emitter(rig.Anchor, {
		Color = color,
		Size = 0.22,
		Lifetime = NumberRange.new(0.8, 1.4),
		Rate = VisualConfig.Fragment.IdleParticleRate,
		Speed = NumberRange.new(0.3, 0.8),
		Acceleration = Vector3.new(0, 1.5, 0),
		ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface,
	})

	local base = CFrame.new(instance.Position)
	local entry: Entry = {
		Rig = rig,
		Base = base,
		Phase = (instance:GetAttribute("FragmentId") :: number? or 0) * 1.7,
		Color = color,
		Emitter = emitter,
		Near = true,
	}
	entries[instance] = entry
	rig:Update(base, 0, 1, base)
end

local function untrack(instance: Instance)
	local entry = entries[instance :: BasePart]
	if not entry then
		return
	end
	entries[instance :: BasePart] = nil
	Particles.Burst(entry.Base.Position, entry.Color, VisualConfig.Fragment.CollectBurstCount)
	entry.Rig:Destroy()
end

local function step()
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local cameraPosition = camera.CFrame.Position
	local t = os.clock()
	local cfg = VisualConfig.Fragment
	for _, entry in entries do
		local near = (entry.Base.Position - cameraPosition).Magnitude <= cfg.LodDistance
		if near ~= entry.Near then
			entry.Near = near
			entry.Emitter.Enabled = near
		end
		if near then
			local phase = entry.Phase
			local pivot = entry.Base
				* CFrame.new(0, math.sin(t * cfg.BobSpeed + phase) * cfg.BobAmplitude, 0)
				* CFrame.Angles(0, t * cfg.SpinSpeed + phase, 0)
			entry.Rig:Update(pivot, t, 1, entry.Base)
		end
	end
end

function FragmentVisuals.Init()
	folder = Rig.Folder("Fragments")
	local source = Workspace:WaitForChild(FOLDER_NAME)
	for _, child in source:GetChildren() do
		track(child)
	end
	source.ChildAdded:Connect(track)
	source.ChildRemoved:Connect(untrack)
	RunService.RenderStepped:Connect(step)
end

return FragmentVisuals
