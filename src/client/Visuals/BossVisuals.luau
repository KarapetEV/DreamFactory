--!strict

--[[
	BossVisuals — Хаос-босс. Сервер держит анкерный Part-хитбокс размера
	ChaosBossConfig.BossSize (дистанция удара считается до него); клиент прячет его локально
	и рисует на его месте модель VisualModels.ChaosBoss (вписана в BossSize).

	- Телеграф: снимок Хаоса с Incoming (порог достигнут, босс появится через
	  ChaosBossConfig.SpawnTelegraphDuration) — в BossPosition растёт тёмный разлом с
	  поднимающимися частицами и красным светом; небо темнеет (ColorCorrection) на время
	  телеграфа и боя.
	- Появление: подъём из-под земли с масштабом; Idle — парение/покачивание через CFrame,
	  Swing рук — из спецификации.
	- Попадание: серверный ChaosBossSystem.OnBossHit клиенту не транслируется; тот же удар
	  уменьшает атрибут Health хитбокса — по нему вспышка цвета и масштаб-пульс.
	- Конец: хитбокс исчезает; если снимок завершения (Ended) — Victory, модель распадается на
	  частицы и разлетается, иначе (Timeout) медленно уходит под землю.
]]

local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local Types = require(ReplicatedStorage.shared.Types)
local ChaosBossConfig = require(ReplicatedStorage.shared.Config.ChaosBossConfig)
local VisualConfig = require(ReplicatedStorage.shared.Config.VisualConfig)
local VisualModels = require(ReplicatedStorage.shared.Config.VisualModels)
local Rig = require(script.Parent.Rig)
local Particles = require(script.Parent.Particles)

export type ChaosSource = {
	GetChaosSnapshot: () -> Types.ChaosSnapshot?,
	ChaosChanged: any,
}

local BOSS_NAME = "ChaosBoss"
local RISE_DEPTH = 10
local SKY_TWEEN = TweenInfo.new(1.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)

local BossVisuals = {}

local folder: Folder
local sky: ColorCorrectionEffect
local skyDark = false

local rig: Rig.Rig? = nil
local bossPart: BasePart? = nil
local bossLight: PointLight? = nil
local attachedAt = 0
local spawnedAt = 0
local hitAt = -math.huge
local lastHealth = 0

local lastEnded: Types.ChaosEventResult? = nil
local lastEndedAt = -math.huge

local telegraph: { Disc: BasePart, StartedAt: number }? = nil

local function bossBase(): CFrame
	local position = if bossPart then bossPart.Position else ChaosBossConfig.BossPosition
	-- Модель смотрит на +Z — в сторону точки спавна игроков.
	return CFrame.lookAt(position, position + Vector3.zAxis)
end

local function groundBelowBoss(): Vector3
	local p = ChaosBossConfig.BossPosition
	return Vector3.new(p.X, p.Y - ChaosBossConfig.BossSize.Y / 2, p.Z)
end

------------------------------------------------------------------------------------------
-- Небо и телеграф
------------------------------------------------------------------------------------------

local function setSkyDark(dark: boolean)
	if dark == skyDark then
		return
	end
	skyDark = dark
	local cfg = VisualConfig.Boss
	TweenService:Create(sky, SKY_TWEEN, {
		Brightness = if dark then cfg.SkyDarkenBrightness else 0,
		Saturation = if dark then cfg.SkyDarkenSaturation else 0,
		TintColor = if dark then cfg.SkyTint else Color3.new(1, 1, 1),
	}):Play()
end

local function startTelegraph()
	if telegraph then
		return
	end
	local cfg = VisualConfig.Boss
	local disc = Instance.new("Part")
	disc.Name = "ChaosTelegraph"
	disc.Shape = Enum.PartType.Cylinder
	disc.Anchored = true
	disc.CanCollide = false
	disc.CanQuery = false
	disc.CanTouch = false
	disc.CastShadow = false
	disc.Material = Enum.Material.Neon
	disc.Color = cfg.TelegraphColor
	disc.Transparency = 0.25
	disc.Size = Vector3.new(0.2, 1, 1)
	disc.CFrame = CFrame.new(groundBelowBoss() + Vector3.new(0, 0.15, 0)) * CFrame.Angles(0, 0, math.rad(90))
	disc.Parent = folder

	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 40, 80)
	light.Brightness = 4
	light.Range = cfg.TelegraphRadius * 2
	light.Parent = disc

	Particles.Emitter(disc, {
		Color = ColorSequence.new(cfg.TelegraphColor, Color3.fromRGB(10, 0, 15)),
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.6),
			NumberSequenceKeypoint.new(0.5, 1.6),
			NumberSequenceKeypoint.new(1, 0),
		}),
		Lifetime = NumberRange.new(1.2, 2.2),
		Rate = 45,
		Speed = NumberRange.new(0, 0), -- направление задаёт Acceleration: вверх, как дым из разлома
		Shape = Enum.ParticleEmitterShape.Cylinder,
		Acceleration = Vector3.new(0, 9, 0),
		LightEmission = 0.4,
		RotSpeed = NumberRange.new(-180, 180),
	})
	telegraph = { Disc = disc, StartedAt = os.clock() }
end

local function stopTelegraph()
	local current = telegraph
	if not current then
		return
	end
	telegraph = nil
	local emitter = current.Disc:FindFirstChildOfClass("ParticleEmitter")
	if emitter then
		emitter.Enabled = false
	end
	TweenService:Create(current.Disc, TweenInfo.new(1), { Transparency = 1 }):Play()
	Debris:AddItem(current.Disc, 2.5)
end

------------------------------------------------------------------------------------------
-- Модель босса
------------------------------------------------------------------------------------------

local function burstAt(position: Vector3, colors: ColorSequence, count: number, speed: NumberRange)
	local attachment = Instance.new("Attachment")
	attachment.WorldPosition = position
	attachment.Parent = Workspace.Terrain
	local emitter = Particles.Emitter(attachment, {
		Color = colors,
		Size = 1.2,
		Lifetime = NumberRange.new(0.8, 1.8),
		Rate = 0,
		Speed = speed,
		Drag = 1.5,
		Acceleration = Vector3.new(0, 2, 0),
		Shape = Enum.ParticleEmitterShape.Sphere,
	})
	emitter:Emit(count)
	Debris:AddItem(attachment, 3)
end

-- Распад (Victory) или уход под землю (Timeout) уже отвязанной модели.
local function playDeath(dead: Rig.Rig, victory: boolean)
	local cfg = VisualConfig.Boss
	local parts: { BasePart } = {}
	local starts: { CFrame } = {}
	local velocities: { Vector3 } = {}
	local center = dead.Anchor.Position
	local random = Random.new()
	for _, descendant in dead.Model:GetDescendants() do
		if descendant:IsA("BasePart") and descendant ~= dead.Anchor then
			table.insert(parts, descendant)
			table.insert(starts, descendant.CFrame)
			local away = descendant.Position - center
			local direction = if away.Magnitude > 0.1 then away.Unit else Vector3.yAxis
			table.insert(velocities, direction * random:NextNumber(8, 18) + Vector3.new(0, random:NextNumber(4, 10), 0))
		end
	end
	if victory then
		burstAt(
			center,
			ColorSequence.new(Color3.fromRGB(255, 60, 130), Color3.fromRGB(40, 10, 60)),
			cfg.DeathParticleCount,
			NumberRange.new(10, 26)
		)
	end

	local start = os.clock()
	local connection: RBXScriptConnection
	connection = RunService.RenderStepped:Connect(function()
		local elapsed = os.clock() - start
		local k = math.clamp(elapsed / cfg.DeathDuration, 0, 1)
		local cframes: { CFrame } = {}
		for index, part in parts do
			if victory then
				local spin = CFrame.Angles(elapsed * 3 + index, elapsed * 2, 0)
				cframes[index] = CFrame.new(starts[index].Position + velocities[index] * elapsed) * starts[index].Rotation * spin
			else
				cframes[index] = starts[index] - Vector3.new(0, RISE_DEPTH * k * k, 0)
			end
			part.Transparency = math.max(part.Transparency, k)
		end
		Workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
		if k >= 1 then
			connection:Disconnect()
			dead:Destroy()
		end
	end)
end

local function detach()
	local dead = rig
	if not dead then
		return
	end
	rig = nil
	bossPart = nil
	bossLight = nil
	local myAttachedAt = attachedAt
	task.spawn(function()
		-- Снимок завершения может прийти чуть позже исчезновения хитбокса.
		local deadline = os.clock() + VisualConfig.Boss.EndedWaitTimeout
		while os.clock() < deadline and lastEndedAt < myAttachedAt do
			task.wait()
		end
		local ended = lastEnded
		local victory = lastEndedAt >= myAttachedAt and ended ~= nil and ended.Outcome == "Victory"
		playDeath(dead, victory)
	end)
end

local function attach(part: BasePart)
	if rig then
		detach()
	end
	stopTelegraph()
	bossPart = part
	part.Transparency = 1 -- локально: серверный хитбокс заменён моделью
	rig = Rig.new(VisualModels.ChaosBoss, nil, folder, "ChaosBossModel")
	attachedAt = os.clock()
	spawnedAt = attachedAt
	hitAt = -math.huge
	lastHealth = tonumber(part:GetAttribute("Health")) or 0

	local current = rig :: Rig.Rig
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 50, 120)
	light.Range = 30
	light.Brightness = 3
	light.Parent = current.Anchor
	bossLight = light
	Particles.Emitter(current.Anchor, {
		Color = ColorSequence.new(Color3.fromRGB(70, 20, 95), Color3.fromRGB(10, 0, 15)),
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.5), NumberSequenceKeypoint.new(1, 0) }),
		Lifetime = NumberRange.new(1, 2),
		Rate = 20,
		Speed = NumberRange.new(0.5, 2),
		ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface,
		Acceleration = Vector3.new(0, 3, 0),
		LightEmission = 0.2,
	})
	burstAt(groundBelowBoss(), ColorSequence.new(VisualConfig.Boss.TelegraphColor), 60, NumberRange.new(10, 20))

	part:GetAttributeChangedSignal("Health"):Connect(function()
		local health = tonumber(part:GetAttribute("Health")) or 0
		if health < lastHealth then
			hitAt = os.clock()
		end
		lastHealth = health
	end)
	part.AncestryChanged:Connect(function()
		if part.Parent == nil and bossPart == part then
			detach()
		end
	end)
end

local function step()
	local t = os.clock()
	local cfg = VisualConfig.Boss

	if telegraph then
		local k = math.clamp((t - telegraph.StartedAt) / ChaosBossConfig.SpawnTelegraphDuration, 0, 1)
		local diameter = 1 + (cfg.TelegraphRadius * 2 - 1) * (1 - (1 - k) ^ 2)
		telegraph.Disc.Size = Vector3.new(0.2, diameter, diameter)
		telegraph.Disc.CFrame = CFrame.new(telegraph.Disc.Position) * CFrame.Angles(0, t * 0.8, math.rad(90))
	end

	local current = rig
	if not current then
		return
	end
	local rise = math.clamp((t - spawnedAt) / cfg.SpawnRiseDuration, 0, 1)
	local eased = 1 - (1 - rise) ^ 3
	local hit = (t - hitAt) / cfg.HitFlashTime
	local pulse = if hit >= 0 and hit < 2 then math.sin(math.pi * hit / 2) else 0
	local scale = (0.6 + 0.4 * eased) * (1 + (cfg.HitPulseScale - 1) * pulse)
	current:SetFlash(cfg.HitFlashColor, if hit >= 0 and hit < 1 then 1 - hit else 0)

	local bob = math.sin(t * cfg.BobSpeed) * cfg.BobAmplitude
	local sway = math.rad(cfg.SwayDegrees) * math.sin(t * cfg.BobSpeed * 0.5)
	local pivot = bossBase() * CFrame.new(0, bob - RISE_DEPTH * (1 - eased), 0) * CFrame.Angles(0, sway, 0)
	current:Update(pivot, t, scale)
	if bossLight then
		bossLight.Brightness = 3 + math.sin(t * 3) + pulse * 4
	end
end

local function onChaos(snapshot: Types.ChaosSnapshot)
	if snapshot.Incoming == true then
		startTelegraph()
	elseif not snapshot.Active then
		stopTelegraph()
	end
	setSkyDark(snapshot.Incoming == true or snapshot.Active)
	if snapshot.Ended then
		lastEnded = snapshot.Ended
		lastEndedAt = os.clock()
	end
end

function BossVisuals.Init(source: ChaosSource)
	folder = Rig.Folder("Boss")
	sky = Instance.new("ColorCorrectionEffect")
	sky.Name = "ChaosSky"
	sky.Parent = Lighting

	local current = source.GetChaosSnapshot()
	if current then
		onChaos(current)
	end
	source.ChaosChanged:Connect(onChaos)

	local existing = Workspace:FindFirstChild(BOSS_NAME)
	if existing and existing:IsA("BasePart") then
		attach(existing)
	end
	Workspace.ChildAdded:Connect(function(child)
		if child.Name == BOSS_NAME and child:IsA("BasePart") then
			attach(child)
		end
	end)
	RunService.RenderStepped:Connect(step)
end

return BossVisuals
