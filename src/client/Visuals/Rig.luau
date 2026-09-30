--!strict

--[[
	Rig — сборка модели из VisualModels.ModelSpec и её процедурное движение (без Animation
	Editor): каждый кадр владелец вызывает Update(pivot, t, scale) — детали двигаются одним
	BulkMoveTo. Всё локально (клиентские инстансы, не реплицируются), детали анкерные и без
	коллизий/запросов/теней — визуал не влияет на физику и серверные проверки.

	- Swing/Spin из спецификации считаются от t (секунды); Static-детали стоят на staticPivot
	  (по умолчанию — тот же pivot).
	- Anchor — невидимая деталь по габаритам модели (в центре габарита): на неё вешаются свет и
	  эмиттеры ауры, Shape = Box эмиттера берёт её размер.
	- scale — равномерный масштаб всей модели (пульс босса, появление пета). Размеры деталей
	  пересчитываются только при изменении scale.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VisualModels = require(ReplicatedStorage.shared.Config.VisualModels)

type ModelSpec = VisualModels.ModelSpec
type PartSpec = VisualModels.PartSpec

type RigPart = {
	Instance: BasePart,
	Spec: PartSpec,
	Offset: Vector3,
	Rotation: CFrame,
	Base: CFrame,
	SwingPivot: Vector3?,
	SwingAxis: Vector3?,
	BaseColor: Color3,
	BaseTransparency: number,
}

export type Rig = {
	Model: Model,
	Anchor: BasePart,
	Update: (self: Rig, pivot: CFrame, t: number, scale: number?, staticPivot: CFrame?) -> (),
	FindTagged: (self: Rig, tag: string) -> { BasePart },
	SetFlash: (self: Rig, color: Color3, alpha: number) -> (),
	SetFade: (self: Rig, alpha: number) -> (),
	Destroy: (self: Rig) -> (),
}

local AXES: { [string]: Vector3 } = {
	X = Vector3.xAxis,
	Y = Vector3.yAxis,
	Z = Vector3.zAxis,
}

local Rig = {}
Rig.__index = Rig

local function createPart(spec: PartSpec): BasePart
	local part: BasePart
	if spec.Shape == "Wedge" then
		part = Instance.new("WedgePart")
	elseif spec.Shape == "CornerWedge" then
		part = Instance.new("CornerWedgePart")
	else
		local basic = Instance.new("Part")
		if spec.Shape == "Ball" then
			basic.Shape = Enum.PartType.Ball
		elseif spec.Shape == "Cylinder" then
			basic.Shape = Enum.PartType.Cylinder
		elseif spec.Shape == "Ellipsoid" then
			local mesh = Instance.new("SpecialMesh")
			mesh.MeshType = Enum.MeshType.Sphere
			mesh.Parent = basic
		end
		part = basic
	end
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Massless = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Material = (Enum.Material :: any)[spec.Material or "SmoothPlastic"]
	part.Transparency = spec.Transparency or 0
	part.Size = spec.Size
	return part
end

-- colors — цвета динамических ролей (Emotion, Biome, ...); остальные — из Palette спецификации.
function Rig.new(spec: ModelSpec, colors: { [string]: Color3 }?, parent: Instance?, name: string?): Rig
	local model = Instance.new("Model")
	model.Name = name or "Rig"

	local bounds = VisualModels.ComputeBounds(spec)
	local anchor = Instance.new("Part")
	anchor.Name = "Anchor"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false
	anchor.Transparency = 1
	anchor.Size = bounds.Max - bounds.Min
	anchor.Parent = model

	local parts: { RigPart } = {}
	for _, partSpec in spec.Parts do
		local instance = createPart(partSpec)
		local color = (colors and colors[partSpec.Color]) or spec.Palette[partSpec.Color] or Color3.new(1, 0, 1)
		instance.Color = color
		if partSpec.Tag then
			instance.Name = partSpec.Tag
		end
		instance.Parent = model

		local r = partSpec.Rotation or Vector3.zero
		local rotation = CFrame.fromEulerAnglesXYZ(math.rad(r.X), math.rad(r.Y), math.rad(r.Z))
		local swing = partSpec.Swing
		table.insert(parts, {
			Instance = instance,
			Spec = partSpec,
			Offset = partSpec.Offset,
			Rotation = rotation,
			Base = CFrame.new(partSpec.Offset) * rotation,
			SwingPivot = if swing then swing.Pivot else nil,
			SwingAxis = if swing then AXES[swing.Axis] else nil,
			BaseColor = color,
			BaseTransparency = instance.Transparency,
		})
	end

	local self = setmetatable({
		Model = model,
		Anchor = anchor,
		_parts = parts,
		_anchorOffset = (bounds.Max + bounds.Min) / 2,
		_anchorSize = anchor.Size,
		_scale = 1,
		_instances = {} :: { BasePart },
		_cframes = {} :: { CFrame },
	}, Rig)

	for index, rigPart in parts do
		self._instances[index] = rigPart.Instance
	end
	table.insert(self._instances, anchor)

	model.Parent = parent or Workspace
	return (self :: any) :: Rig
end

function Rig.Update(self: any, pivot: CFrame, t: number, scale: number?, staticPivot: CFrame?)
	local s = scale or 1
	if s ~= self._scale then
		self._scale = s
		for _, rigPart in self._parts :: { RigPart } do
			rigPart.Instance.Size = rigPart.Spec.Size * s
		end
		self.Anchor.Size = self._anchorSize * s
	end

	local cframes = self._cframes
	local still = staticPivot or pivot
	for index, rigPart in self._parts :: { RigPart } do
		local spec = rigPart.Spec
		local localCFrame = rigPart.Base
		if spec.Spin then
			localCFrame = CFrame.new(rigPart.Offset) * CFrame.Angles(0, t * spec.Spin, 0) * rigPart.Rotation
		end
		local swing = spec.Swing
		if swing and rigPart.SwingPivot and rigPart.SwingAxis then
			local angle = math.rad(swing.Degrees) * math.sin(t * swing.Speed + (swing.Phase or 0))
			local p = rigPart.SwingPivot
			localCFrame = CFrame.new(p) * CFrame.fromAxisAngle(rigPart.SwingAxis, angle) * CFrame.new(-p) * localCFrame
		end
		if s ~= 1 then
			localCFrame = CFrame.new(localCFrame.Position * s) * localCFrame.Rotation
		end
		cframes[index] = (if spec.Static then still else pivot) * localCFrame
	end
	cframes[#self._parts + 1] = pivot * CFrame.new(self._anchorOffset * s)
	Workspace:BulkMoveTo(self._instances, cframes, Enum.BulkMoveMode.FireCFrameChanged)
end

-- Детали с Tag из спецификации (трещины кокона, окно фабрики, ядро босса).
function Rig.FindTagged(self: any, tag: string): { BasePart }
	local result = {}
	for _, rigPart in self._parts :: { RigPart } do
		if rigPart.Spec.Tag == tag then
			table.insert(result, rigPart.Instance)
		end
	end
	return result
end

-- Подсветка всей модели цветом color: alpha = 0 — исходные цвета, 1 — целиком color.
function Rig.SetFlash(self: any, color: Color3, alpha: number)
	for _, rigPart in self._parts :: { RigPart } do
		rigPart.Instance.Color = rigPart.BaseColor:Lerp(color, alpha)
	end
end

-- Растворение: alpha = 0 — исходная прозрачность, 1 — невидимо. Скрытые по умолчанию детали
-- (трещины) не проявляются.
function Rig.SetFade(self: any, alpha: number)
	for _, rigPart in self._parts :: { RigPart } do
		local base = rigPart.BaseTransparency
		if base < 1 then
			rigPart.Instance.Transparency = base + (1 - base) * alpha
		end
	end
end

function Rig.Destroy(self: any)
	self.Model:Destroy()
end

-- Папка клиентского визуала Workspace.ClientVisuals.<name> (создаётся по требованию).
function Rig.Folder(name: string): Folder
	local root = Workspace:FindFirstChild("ClientVisuals")
	if not root then
		root = Instance.new("Folder")
		root.Name = "ClientVisuals"
		root.Parent = Workspace
	end
	local folder = root:FindFirstChild(name)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = name
		folder.Parent = root
	end
	return folder :: Folder
end

return Rig
