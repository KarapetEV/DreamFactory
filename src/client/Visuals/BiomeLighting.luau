--!strict

--[[
	BiomeLighting — свет и атмосфера по биому, в котором стоит персонаж (BiomeLocator: ближайшая
	зона спавна). Параметры — VisualConfig.BiomeLighting, цвет-акцент — BiomeConfig.AccentColor
	(Atmosphere.Color/Decay и тинт ColorCorrection «BiomeTint»). Смена биома — плавный Tween.
	Затемнение неба на время Хаоса (BossVisuals) — отдельный ColorCorrection поверх этого.
]]

local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local BiomeConfig = require(ReplicatedStorage.shared.Config.BiomeConfig)
local VisualConfig = require(ReplicatedStorage.shared.Config.VisualConfig)
local BiomeLocator = require(ReplicatedStorage.shared.BiomeLocator)

local CHECK_INTERVAL = 0.5

local BiomeLighting = {}

local currentBiome: string? = nil
local atmosphere: Atmosphere
local tint: ColorCorrectionEffect

local function apply(biomeId: string, instant: boolean)
	local lighting = VisualConfig.BiomeLighting[biomeId]
	local biome = BiomeConfig[biomeId]
	if not lighting or not biome then
		return
	end
	local accent = biome.AccentColor
	local info = TweenInfo.new(
		if instant then 0 else VisualConfig.BiomeLightingTweenTime,
		Enum.EasingStyle.Sine,
		Enum.EasingDirection.InOut
	)
	TweenService:Create(Lighting, info, {
		ClockTime = lighting.ClockTime,
		Brightness = lighting.Brightness,
		Ambient = lighting.Ambient,
		OutdoorAmbient = lighting.OutdoorAmbient,
	}):Play()
	TweenService:Create(atmosphere, info, {
		Color = accent,
		Decay = accent:Lerp(Color3.new(0, 0, 0), 0.5),
		Density = lighting.AtmosphereDensity,
		Haze = lighting.AtmosphereHaze,
	}):Play()
	TweenService:Create(tint, info, {
		TintColor = Color3.new(1, 1, 1):Lerp(accent, lighting.TintStrength),
		Saturation = lighting.Saturation,
	}):Play()
end

local function check()
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end
	local biomeId = BiomeLocator.BiomeAt(root.Position)
	if biomeId and biomeId ~= currentBiome then
		local first = currentBiome == nil
		currentBiome = biomeId
		apply(biomeId, first)
	end
end

function BiomeLighting.Init()
	local existing = Lighting:FindFirstChildOfClass("Atmosphere")
	if existing then
		atmosphere = existing
	else
		atmosphere = Instance.new("Atmosphere")
		atmosphere.Parent = Lighting
	end
	tint = Instance.new("ColorCorrectionEffect")
	tint.Name = "BiomeTint"
	tint.Parent = Lighting

	task.spawn(function()
		while true do
			check()
			task.wait(CHECK_INTERVAL)
		end
	end)
end

return BiomeLighting
