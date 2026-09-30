--!strict

--[[
	CocoonEffect — раскрытие кокона после подтверждённого сервером HatchCocoon
	(PetInventoryUI.Hatched). Общая модель кокона (VisualModels.Cocoon), три стадии без
	baked-анимации — только CFrame/Tween-подобная интерполяция и ParticleEmitter:
	  1) тряска нарастающей силы;
	  2) трещины проступают, свечение цвета редкости усиливается;
	  3) раскрытие — вспышка частиц, кокон исчезает, на его месте появляется модель пета
	     с аурой редкости, крутится на витрине и растворяется.
	Эффект локальный (видит только вылупивший). Новое вылупление прерывает текущее.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

local Types = require(ReplicatedStorage.shared.Types)
local VisualConfig = require(ReplicatedStorage.shared.Config.VisualConfig)
local VisualModels = require(ReplicatedStorage.shared.Config.VisualModels)
local Rig = require(script.Parent.Rig)
local Particles = require(script.Parent.Particles)
local PetVisuals = require(script.Parent.PetVisuals)

local COCOON_HOVER = 1.8 -- центр кокона над землёй
local POP_TIME = 0.35
local FADE_TIME = 0.3

local CocoonEffect = {}

local token = 0
local folder: Folder

local function easeOutBack(x: number): number
	local c1, c3 = 1.70158, 2.70158
	return 1 + c3 * (x - 1) ^ 3 + c1 * (x - 1) ^ 2
end

-- Ждёт следующего кадра; false — эффект прерван новым вылуплением.
local function frame(myToken: number): boolean
	RunService.RenderStepped:Wait()
	return token == myToken
end

local function burst(position: Vector3, color: Color3, count: number)
	local attachment = Instance.new("Attachment")
	attachment.WorldPosition = position
	attachment.Parent = Workspace.Terrain
	local emitter = Particles.Emitter(attachment, {
		Color = ColorSequence.new(color, Color3.new(1, 1, 1)),
		Size = 0.7,
		Lifetime = NumberRange.new(0.6, 1.2),
		Rate = 0,
		Speed = NumberRange.new(8, 18),
		Drag = 3,
		Acceleration = Vector3.new(0, 3, 0),
	})
	emitter:Emit(count)
	Debris:AddItem(attachment, 2)
end

local function play(pet: Types.PetRecord, myToken: number)
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not root then
		return
	end
	local cfg = VisualConfig.Cocoon
	local tier = VisualConfig.RarityAura[pet.Rarity] or VisualConfig.RarityAura.Common
	local groundY = root.Position.Y - (if humanoid then humanoid.HipHeight else 2) - root.Size.Y / 2
	local ahead = (root.CFrame * CFrame.new(0, 0, -cfg.DistanceInFront)).Position
	local center = Vector3.new(ahead.X, groundY + COCOON_HOVER, ahead.Z)
	local facing = Vector3.new(root.Position.X, center.Y, root.Position.Z)
	local base = CFrame.lookAt(center, facing)

	local cocoon = Rig.new(VisualModels.Cocoon, nil, folder, "Cocoon")
	local light = Instance.new("PointLight")
	light.Color = tier.Color
	light.Brightness = 0
	light.Range = 12
	light.Parent = cocoon.Anchor
	local cracks = cocoon:FindTagged("Crack")
	local random = Random.new()

	local function shaken(intensity: number): CFrame
		return base
			* CFrame.new(random:NextNumber(-1, 1) * 0.25 * intensity, 0, random:NextNumber(-1, 1) * 0.25 * intensity)
			* CFrame.Angles(0, 0, math.rad(random:NextNumber(-1, 1) * 12 * intensity))
	end

	-- 1) Тряска.
	local start = os.clock()
	while os.clock() - start < cfg.ShakeDuration do
		local k = (os.clock() - start) / cfg.ShakeDuration
		cocoon:Update(shaken(k * k), os.clock())
		if not frame(myToken) then
			cocoon:Destroy()
			return
		end
	end

	-- 2) Трещины и свечение.
	start = os.clock()
	while os.clock() - start < cfg.GlowDuration do
		local k = (os.clock() - start) / cfg.GlowDuration
		for index, crack in cracks do
			-- Трещины проступают по очереди.
			local crackK = math.clamp(k * #cracks - (index - 1), 0, 1)
			crack.Transparency = 1 - crackK
		end
		light.Brightness = 6 * k
		cocoon:SetFlash(tier.Color, 0.5 * k)
		cocoon:Update(shaken(1 + k), os.clock())
		if not frame(myToken) then
			cocoon:Destroy()
			return
		end
	end

	-- 3) Раскрытие.
	burst(center, tier.Color, cfg.BurstCount)
	cocoon:Destroy()

	local rig, aura = PetVisuals.BuildPet(pet.SpeciesId, pet.Rarity, type(pet.Mutation) == "string", folder)
	if not rig or not aura then
		return
	end
	local spec = VisualModels.Pets[pet.SpeciesId]
	local petCenter = Vector3.new(center.X, groundY + math.max(spec.Hover, 1.5), center.Z)
	start = os.clock()
	local total = POP_TIME + cfg.RevealDuration + FADE_TIME
	while os.clock() - start < total do
		local elapsed = os.clock() - start
		local scale = 1
		if elapsed < POP_TIME then
			scale = 0.2 + 0.8 * easeOutBack(elapsed / POP_TIME)
		elseif elapsed > POP_TIME + cfg.RevealDuration then
			local k = (elapsed - POP_TIME - cfg.RevealDuration) / FADE_TIME
			scale = 1 - 0.6 * k
			rig:SetFade(k)
		end
		local pivot = CFrame.lookAt(petCenter, Vector3.new(root.Position.X, petCenter.Y, root.Position.Z))
			* CFrame.Angles(0, math.sin(elapsed * 2) * 0.6, 0)
			* CFrame.new(0, math.sin(elapsed * 3) * 0.2, 0)
		rig:Update(pivot, os.clock(), math.max(scale, 0.05))
		aura:Update(os.clock())
		if not frame(myToken) then
			break
		end
	end
	rig:Destroy()
end

function CocoonEffect.Play(pet: Types.PetRecord)
	token += 1
	local myToken = token
	task.spawn(play, pet, myToken)
end

-- hatchedSource — PetInventoryUI (сигнал Hatched с PetRecord из снимка сервера).
function CocoonEffect.Init(hatchedSource: { Hatched: any })
	folder = Rig.Folder("Cocoon")
	hatchedSource.Hatched:Connect(CocoonEffect.Play)
end

return CocoonEffect
