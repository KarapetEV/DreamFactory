--!strict

--[[
	PlayerEffects — PvP- и Rebirth-эффекты без новых ремоут, по уже приходящим данным:
	- аура щита: пузырь ForceField вокруг каждого игрока, у кого атрибут
	  Attributes.ShieldExpiresAt (os.time() конца щита, пишет PvPRaidSystem) ещё в будущем
	  по серверному времени (Workspace:GetServerTimeNow); за ShieldBlinkBefore до конца мигает;
	- виньетка рейда: атрибут Attributes.RaidedCount своего игрока вырос — красная пульсирующая
	  рамка экрана и надпись;
	- перерождение: снимок экономики с RebirthAck = true — вспышка экрана, кольцо и частицы
	  вокруг своего персонажа в цвете-акценте нового биома.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local Types = require(ReplicatedStorage.shared.Types)
local Loc = require(ReplicatedStorage.shared.Loc)
local Attributes = require(ReplicatedStorage.shared.Attributes)
local BiomeConfig = require(ReplicatedStorage.shared.Config.BiomeConfig)
local VisualConfig = require(ReplicatedStorage.shared.Config.VisualConfig)
local Rig = require(script.Parent.Rig)
local Particles = require(script.Parent.Particles)

export type SnapshotSource = {
	SnapshotChanged: any,
}

local TEXT = {
	Raided = Loc.Get("PlayerEffects.Raided"),
}

local VIGNETTE_THICKNESS = 0.18 -- доля экрана на каждую сторону

local PlayerEffects = {}

local folder: Folder
local shields: { [Player]: Part } = {}
local vignette: CanvasGroup
local raidLabel: TextLabel
local flashFrame: Frame
local lastRaidedCount = 0

------------------------------------------------------------------------------------------
-- Аура щита
------------------------------------------------------------------------------------------

local function getShield(player: Player): Part
	local bubble = shields[player]
	if bubble then
		return bubble
	end
	local cfg = VisualConfig.PlayerEffects
	bubble = Instance.new("Part")
	bubble.Name = `Shield_{player.UserId}`
	bubble.Shape = Enum.PartType.Ball
	bubble.Size = Vector3.one * cfg.ShieldDiameter
	bubble.Material = Enum.Material.ForceField
	bubble.Color = cfg.ShieldColor
	bubble.Anchored = true
	bubble.CanCollide = false
	bubble.CanQuery = false
	bubble.CanTouch = false
	bubble.CastShadow = false
	shields[player] = bubble
	return bubble
end

local function stepShields()
	local now = Workspace:GetServerTimeNow()
	local t = os.clock()
	local blinkBefore = VisualConfig.PlayerEffects.ShieldBlinkBefore
	for _, player in Players:GetPlayers() do
		local expiresAt = player:GetAttribute(Attributes.ShieldExpiresAt)
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		local left = if type(expiresAt) == "number" then expiresAt - now else 0
		if left > 0 and root then
			local bubble = getShield(player)
			bubble.Parent = folder
			bubble.CFrame = CFrame.new(root.Position)
			local blinking = left < blinkBefore and math.sin(t * 12) > 0
			bubble.Transparency = if blinking then 0.85 else 0.35
		elseif shields[player] then
			shields[player].Parent = nil
		end
	end
end

------------------------------------------------------------------------------------------
-- Виньетка рейда
------------------------------------------------------------------------------------------

local function edge(parent: Instance, size: UDim2, position: UDim2, rotation: number)
	local frame = Instance.new("Frame")
	frame.BorderSizePixel = 0
	frame.BackgroundColor3 = VisualConfig.PlayerEffects.RaidVignetteColor
	frame.Size = size
	frame.Position = position
	frame.Parent = parent
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = rotation
	gradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	gradient.Parent = frame
end

local function buildGui(): ScreenGui
	local gui = Instance.new("ScreenGui")
	gui.Name = "PlayerEffects"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 5

	vignette = Instance.new("CanvasGroup")
	vignette.Size = UDim2.fromScale(1, 1)
	vignette.BackgroundTransparency = 1
	vignette.GroupTransparency = 1
	vignette.Visible = false
	vignette.Parent = gui
	local k = VIGNETTE_THICKNESS
	edge(vignette, UDim2.fromScale(1, k), UDim2.fromScale(0, 0), 90) -- верх: плотно сверху
	edge(vignette, UDim2.fromScale(1, k), UDim2.fromScale(0, 1 - k), -90)
	edge(vignette, UDim2.fromScale(k, 1), UDim2.fromScale(0, 0), 0)
	edge(vignette, UDim2.fromScale(k, 1), UDim2.fromScale(1 - k, 0), 180)

	raidLabel = Instance.new("TextLabel")
	raidLabel.Size = UDim2.fromScale(0.6, 0.08)
	raidLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	raidLabel.Position = UDim2.fromScale(0.5, 0.22)
	raidLabel.BackgroundTransparency = 1
	raidLabel.TextColor3 = Color3.new(1, 1, 1)
	raidLabel.TextStrokeColor3 = VisualConfig.PlayerEffects.RaidVignetteColor
	raidLabel.TextStrokeTransparency = 0
	raidLabel.TextScaled = true
	raidLabel.Font = Enum.Font.GothamBlack
	raidLabel.Text = TEXT.Raided
	raidLabel.Parent = vignette

	flashFrame = Instance.new("Frame")
	flashFrame.Size = UDim2.fromScale(1, 1)
	flashFrame.BorderSizePixel = 0
	flashFrame.BackgroundColor3 = VisualConfig.PlayerEffects.RebirthFlashColor
	flashFrame.BackgroundTransparency = 1
	flashFrame.Parent = gui
	return gui
end

local vignetteToken = 0

local function playRaidVignette()
	vignetteToken += 1
	local token = vignetteToken
	local duration = VisualConfig.PlayerEffects.RaidVignetteDuration
	vignette.Visible = true
	task.spawn(function()
		local start = os.clock()
		while os.clock() - start < duration and vignetteToken == token do
			local k = (os.clock() - start) / duration
			-- Два удара «пульса», затем затухание.
			local pulse = math.abs(math.sin(k * math.pi * 3))
			vignette.GroupTransparency = 1 - pulse * (1 - k * 0.6)
			RunService.RenderStepped:Wait()
		end
		if vignetteToken == token then
			vignette.GroupTransparency = 1
			vignette.Visible = false
		end
	end)
end

local function onRaidedCountChanged()
	local count = tonumber(Players.LocalPlayer:GetAttribute(Attributes.RaidedCount)) or 0
	if count > lastRaidedCount then
		playRaidVignette()
	end
	lastRaidedCount = count
end

------------------------------------------------------------------------------------------
-- Перерождение
------------------------------------------------------------------------------------------

local function playRebirth(snapshot: Types.EconomySnapshot)
	local cfg = VisualConfig.PlayerEffects
	local biome = BiomeConfig[snapshot.CurrentBiome]
	local accent = if biome then biome.AccentColor else cfg.RebirthFlashColor

	flashFrame.BackgroundTransparency = 0.15
	TweenService:Create(flashFrame, TweenInfo.new(cfg.RebirthFlashDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		BackgroundTransparency = 1,
	}):Play()

	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not root then
		return
	end
	local groundY = root.Position.Y - (if humanoid then humanoid.HipHeight else 2) - root.Size.Y / 2

	local ring = Instance.new("Part")
	ring.Shape = Enum.PartType.Cylinder
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.CastShadow = false
	ring.Material = Enum.Material.Neon
	ring.Color = accent
	ring.Transparency = 0.2
	ring.Size = Vector3.new(0.3, 2, 2)
	ring.CFrame = CFrame.new(root.Position.X, groundY + 0.2, root.Position.Z) * CFrame.Angles(0, 0, math.rad(90))
	ring.Parent = folder
	TweenService:Create(ring, TweenInfo.new(1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.3, cfg.RebirthRingDiameter, cfg.RebirthRingDiameter),
		Transparency = 1,
	}):Play()
	Debris:AddItem(ring, 1.2)

	local attachment = Instance.new("Attachment")
	attachment.WorldPosition = root.Position
	attachment.Parent = Workspace.Terrain
	local emitter = Particles.Emitter(attachment, {
		Color = ColorSequence.new(accent, cfg.RebirthFlashColor),
		Size = 0.8,
		Lifetime = NumberRange.new(1, 1.8),
		Rate = 0,
		Speed = NumberRange.new(6, 16),
		Drag = 2,
		Acceleration = Vector3.new(0, 8, 0),
	})
	emitter:Emit(cfg.RebirthParticleCount)
	Debris:AddItem(attachment, 3)
end

------------------------------------------------------------------------------------------

function PlayerEffects.Init(source: SnapshotSource)
	folder = Rig.Folder("PlayerEffects")
	buildGui().Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	lastRaidedCount = tonumber(Players.LocalPlayer:GetAttribute(Attributes.RaidedCount)) or 0
	Players.LocalPlayer:GetAttributeChangedSignal(Attributes.RaidedCount):Connect(onRaidedCountChanged)

	source.SnapshotChanged:Connect(function(snapshot: Types.EconomySnapshot)
		if snapshot.RebirthAck == true then
			playRebirth(snapshot)
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		local bubble = shields[player]
		shields[player] = nil
		if bubble then
			bubble:Destroy()
		end
	end)
	RunService.RenderStepped:Connect(stepShields)
end

return PlayerEffects
