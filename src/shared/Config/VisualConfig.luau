--!strict

--[[
	Визуал MVP перед плейтестом: цвета, тиры аур, параметры процедурного движения, лимиты
	эффектов, свет и Terrain-декор биомов. Только отображение — ни одна серверная проверка
	эти числа не читает. Формы моделей — отдельно, в VisualModels.

	Значения Enum (материалы, Terrain-материалы) хранятся строками: конфиг грузится и в
	lune-тестах, где Enum нет; клиент/сервер переводит их через Enum.Material[имя]. Имена
	проверяются по белым спискам ниже при загрузке.

	- EmotionColors — ОСНОВНОЙ визуальный сигнал фрагмента (цвет кристалла и частиц) и эмоции
	  пета. Цвет биома (BiomeConfig.AccentColor) — вторичный акцент окружения: кольцо под
	  фрагментом, Atmosphere/тинт освещения биома.
	- RarityAura — один базовый меш на вид, редкость = слой эффектов поверх модели:
	  Common без ауры → Rare свечение → Epic частицы по контуру → Legendary полная аура →
	  Secret всё это плюс маркер над головой. Флаги монотонны по шкале редкостей.
	- Effects — общий бюджет разовых вспышек частиц (сбор фрагментов и т.п.): не больше
	  MaxConcurrentBursts одновременно и MaxBurstsPerSecond в секунду, лишние отбрасываются.
]]

local Types = require(script.Parent.Parent.Types)
local UpgradeEffects = require(script.Parent.Parent.UpgradeEffects)
local PetSpeciesConfig = require(script.Parent.PetSpeciesConfig)
local BiomeConfig = require(script.Parent.BiomeConfig)

type EmotionType = Types.EmotionType

export type AuraTier = {
	Tier: number, -- 0 — без ауры; строго растёт по PetSpeciesConfig.Rarities
	Color: Color3,
	Glow: boolean, -- PointLight вокруг модели
	ContourParticles: boolean, -- частицы с поверхности габаритов модели
	FullAura: boolean, -- объёмная аура-облако частиц
	SecretMarker: boolean, -- вращающийся маркер над головой (сверх Legendary)
	LightBrightness: number,
	ParticleRate: number, -- частиц в секунду у контура/ауры (0 — нет)
}

export type BiomeLighting = {
	ClockTime: number,
	Brightness: number,
	Ambient: Color3,
	OutdoorAmbient: Color3,
	AtmosphereDensity: number, -- 0..1
	AtmosphereHaze: number, -- 0..10
	TintStrength: number, -- 0..1: доля AccentColor биома в ColorCorrection.TintColor
	Saturation: number, -- -1..1
}

export type BiomeDecor = {
	GroundMaterial: string, -- Terrain-материал подложки зоны
	FeatureMaterial: string, -- холмы/скалы по краям зоны
	AccentMaterial: string, -- мелкие вкрапления (кристаллы, лава, цветы)
	FeatureCount: number,
	FeatureMinRadius: number,
	FeatureMaxRadius: number,
	Margin: number, -- на сколько studs подложка шире габарита точек спавна зоны
	SpawnClearance: number, -- минимум studs от точки спавна фрагмента до края декора
}

export type VisualDefinition = {
	MaterialNames: { string },
	TerrainMaterialNames: { string },

	EmotionColors: { [EmotionType]: Color3 },
	RarityAura: { [string]: AuraTier },

	Effects: {
		MaxConcurrentBursts: number,
		MaxBurstsPerSecond: number,
		BurstLifetime: number, -- секунд, сколько вспышка держит слот бюджета
		BurstVisibleDistance: number, -- дальше от камеры вспышку не показываем вовсе
	},

	Fragment: {
		BobAmplitude: number,
		BobSpeed: number, -- рад/с
		SpinSpeed: number, -- рад/с
		IdleParticleRate: number,
		CollectBurstCount: number,
		LodDistance: number, -- дальше от камеры: частицы выключены, движение не обновляется
		BiomeRingTransparency: number,
		-- Магнитный сбор (Attributes.FragmentCollectMode = "Magnet"): кристалл летит к собравшему.
		MagnetFlyDuration: number, -- сек полёта
		MagnetFlyArc: number, -- studs: высота дуги в середине полёта
		MagnetEndScale: number, -- масштаб кристалла у персонажа (0..1]
		MagnetArriveBurstCount: number, -- частиц вспышки у персонажа
		MagnetMaxFlights: number, -- одновременных полётов; сверх — обычная вспышка на месте
	},

	Pets: {
		FollowBack: number, -- studs за спиной владельца
		SideSpacing: number, -- studs между соседними петами
		Responsiveness: number, -- скорость догоняния (1/с): больше — меньше лаг
		IdleBobAmplitude: number,
		IdleBobSpeed: number,
		RenderDistance: number, -- петов дальше от камеры не показываем
		MaxRendered: number, -- потолок моделей петов на клиенте
		MutationSparkleRate: number,
	},

	Cocoon: {
		ShakeDuration: number,
		GlowDuration: number,
		BurstCount: number,
		RevealDuration: number,
		DistanceInFront: number,
		ShellColor: Color3,
		CrackColor: Color3,
	},

	Boss: {
		BobAmplitude: number,
		BobSpeed: number,
		SwayDegrees: number,
		HitFlashColor: Color3,
		HitFlashTime: number,
		HitPulseScale: number, -- ≥ 1, масштаб на пике пульса
		DeathParticleCount: number,
		DeathDuration: number,
		SpawnRiseDuration: number,
		EndedWaitTimeout: number, -- сколько ждать снимок завершения после исчезновения Part
		TelegraphColor: Color3,
		TelegraphRadius: number,
		SkyDarkenBrightness: number, -- ≤ 0, ColorCorrection.Brightness на время Хаоса
		SkyDarkenSaturation: number,
		SkyTint: Color3,
	},

	Factory: {
		Origin: Vector3, -- центр основания (клиентская модель у точки спавна)
		YawDegrees: number,
		BeltLength: number,
		SlatCount: number,
		BeltSpeed: number, -- studs/с, пока в буфере есть сырые фрагменты
		MaxRidingFragments: number,
		FlashParticleCount: number,
		FlashColor: Color3,
	},

	BiomeLighting: { [string]: BiomeLighting },
	BiomeLightingTweenTime: number,
	BiomeDecor: { [string]: BiomeDecor },
	DecorSeed: number,

	PlayerEffects: {
		ShieldColor: Color3,
		ShieldDiameter: number,
		ShieldBlinkBefore: number, -- секунд до конца щита, когда аура начинает мигать
		RaidVignetteColor: Color3,
		RaidVignetteDuration: number,
		RebirthFlashColor: Color3,
		RebirthFlashDuration: number,
		RebirthParticleCount: number,
		RebirthRingDiameter: number,
	},
}

local VisualConfig: VisualDefinition = {
	MaterialNames = { "SmoothPlastic", "Plastic", "Neon", "Glass", "ForceField", "Fabric", "Metal", "Foil", "Ice", "Slate" },
	TerrainMaterialNames = {
		"Grass",
		"LeafyGrass",
		"Ground",
		"Mud",
		"Rock",
		"Slate",
		"Basalt",
		"CrackedLava",
		"Glacier",
		"Ice",
		"Salt",
		"Snow",
		"Limestone",
	},

	EmotionColors = {
		Joyful = Color3.fromRGB(255, 200, 60), -- тёплый жёлтый
		Nostalgic = Color3.fromRGB(125, 185, 255), -- мягкий голубой
		Fearful = Color3.fromRGB(165, 40, 255), -- резкий фиолетовый
	},

	RarityAura = {
		Common = {
			Tier = 0,
			Color = Color3.fromRGB(220, 220, 230),
			Glow = false,
			ContourParticles = false,
			FullAura = false,
			SecretMarker = false,
			LightBrightness = 0,
			ParticleRate = 0,
		},
		Rare = {
			Tier = 1,
			Color = Color3.fromRGB(80, 170, 255),
			Glow = true,
			ContourParticles = false,
			FullAura = false,
			SecretMarker = false,
			LightBrightness = 1.5,
			ParticleRate = 0,
		},
		Epic = {
			Tier = 2,
			Color = Color3.fromRGB(185, 85, 255),
			Glow = true,
			ContourParticles = true,
			FullAura = false,
			SecretMarker = false,
			LightBrightness = 2,
			ParticleRate = 6,
		},
		Legendary = {
			Tier = 3,
			Color = Color3.fromRGB(255, 185, 50),
			Glow = true,
			ContourParticles = true,
			FullAura = true,
			SecretMarker = false,
			LightBrightness = 3,
			ParticleRate = 12,
		},
		Secret = {
			Tier = 4,
			Color = Color3.fromRGB(255, 70, 190),
			Glow = true,
			ContourParticles = true,
			FullAura = true,
			SecretMarker = true,
			LightBrightness = 3.5,
			ParticleRate = 16,
		},
	},

	Effects = {
		MaxConcurrentBursts = 6,
		MaxBurstsPerSecond = 8,
		BurstLifetime = 1.2,
		BurstVisibleDistance = 90,
	},

	Fragment = {
		BobAmplitude = 0.35,
		BobSpeed = 1.8,
		SpinSpeed = 0.9,
		IdleParticleRate = 3,
		CollectBurstCount = 14,
		LodDistance = 140,
		BiomeRingTransparency = 0.55,
		MagnetFlyDuration = 0.35,
		MagnetFlyArc = 2,
		MagnetEndScale = 0.3,
		MagnetArriveBurstCount = 6,
		MagnetMaxFlights = 16,
	},

	Pets = {
		FollowBack = 5,
		SideSpacing = 3.2,
		Responsiveness = 5,
		IdleBobAmplitude = 0.25,
		IdleBobSpeed = 2.4,
		RenderDistance = 160,
		MaxRendered = 48,
		MutationSparkleRate = 4,
	},

	Cocoon = {
		ShakeDuration = 1.2,
		GlowDuration = 1,
		BurstCount = 60,
		RevealDuration = 2,
		DistanceInFront = 7,
		ShellColor = Color3.fromRGB(240, 228, 255),
		CrackColor = Color3.fromRGB(255, 250, 220),
	},

	Boss = {
		BobAmplitude = 1.2,
		BobSpeed = 0.8,
		SwayDegrees = 6,
		HitFlashColor = Color3.fromRGB(255, 235, 245),
		HitFlashTime = 0.12,
		HitPulseScale = 1.06,
		DeathParticleCount = 150,
		DeathDuration = 1.6,
		SpawnRiseDuration = 1.2,
		EndedWaitTimeout = 1.5,
		TelegraphColor = Color3.fromRGB(150, 20, 110),
		TelegraphRadius = 14,
		SkyDarkenBrightness = -0.18,
		SkyDarkenSaturation = -0.35,
		SkyTint = Color3.fromRGB(215, 185, 235),
	},

	Factory = {
		Origin = Vector3.new(-55, 0, 0),
		YawDegrees = 90,
		BeltLength = 24,
		SlatCount = 12,
		BeltSpeed = 3,
		MaxRidingFragments = 6,
		FlashParticleCount = 24,
		FlashColor = Color3.fromRGB(255, 225, 140),
	},

	BiomeLighting = {
		DreamMeadow = {
			ClockTime = 14.5,
			Brightness = 2.2,
			Ambient = Color3.fromRGB(95, 85, 120),
			OutdoorAmbient = Color3.fromRGB(150, 140, 175),
			AtmosphereDensity = 0.3,
			AtmosphereHaze = 1.2,
			TintStrength = 0.12,
			Saturation = 0.1,
		},
		Nightmares = {
			ClockTime = 21.5,
			Brightness = 1,
			Ambient = Color3.fromRGB(45, 20, 60),
			OutdoorAmbient = Color3.fromRGB(70, 35, 90),
			AtmosphereDensity = 0.5,
			AtmosphereHaze = 2.5,
			TintStrength = 0.3,
			Saturation = -0.2,
		},
		LucidDreams = {
			ClockTime = 17.2,
			Brightness = 2.6,
			Ambient = Color3.fromRGB(110, 135, 160),
			OutdoorAmbient = Color3.fromRGB(165, 200, 225),
			AtmosphereDensity = 0.25,
			AtmosphereHaze = 0.6,
			TintStrength = 0.15,
			Saturation = 0.2,
		},
	},
	BiomeLightingTweenTime = 2,

	BiomeDecor = {
		DreamMeadow = {
			-- Grass рисует высокие травинки (Terrain Decoration) — на подложке они прятали бы
			-- фрагменты, поэтому трава только на холмах по краям.
			GroundMaterial = "LeafyGrass",
			FeatureMaterial = "Grass",
			AccentMaterial = "Rock",
			FeatureCount = 7,
			FeatureMinRadius = 4,
			FeatureMaxRadius = 8,
			Margin = 18,
			SpawnClearance = 4,
		},
		Nightmares = {
			GroundMaterial = "Basalt",
			FeatureMaterial = "Slate",
			AccentMaterial = "CrackedLava",
			FeatureCount = 8,
			FeatureMinRadius = 3,
			FeatureMaxRadius = 7,
			Margin = 18,
			SpawnClearance = 4,
		},
		LucidDreams = {
			GroundMaterial = "Glacier",
			FeatureMaterial = "Ice",
			AccentMaterial = "Salt",
			FeatureCount = 7,
			FeatureMinRadius = 3,
			FeatureMaxRadius = 7,
			Margin = 18,
			SpawnClearance = 4,
		},
	},
	DecorSeed = 20260930,

	PlayerEffects = {
		ShieldColor = Color3.fromRGB(120, 220, 255),
		ShieldDiameter = 8,
		ShieldBlinkBefore = 10,
		RaidVignetteColor = Color3.fromRGB(220, 30, 60),
		RaidVignetteDuration = 2.5,
		RebirthFlashColor = Color3.fromRGB(255, 245, 215),
		RebirthFlashDuration = 1.2,
		RebirthParticleCount = 80,
		RebirthRingDiameter = 30,
	},
}

-- Проверки при загрузке: конфиг визуала без цвета эмоции/тира редкости/света биома уронил бы
-- клиентский рендер посреди плейтеста — пусть лучше падает старт.
do
	local c = VisualConfig
	local isFinite = UpgradeEffects.IsFinite

	local function positive(name: string, value: number)
		assert(isFinite(value) and value > 0, `VisualConfig: {name} должен быть > 0, получено {value}`)
	end
	local function nonNegative(name: string, value: number)
		assert(isFinite(value) and value >= 0, `VisualConfig: {name} должен быть ≥ 0, получено {value}`)
	end
	local function inRange(name: string, value: number, lo: number, hi: number)
		assert(isFinite(value) and value >= lo and value <= hi, `VisualConfig: {name} вне [{lo}, {hi}]: {value}`)
	end
	local function isColor(name: string, color: Color3)
		assert(
			color ~= nil and isFinite(color.R) and isFinite(color.G) and isFinite(color.B),
			`VisualConfig: {name} — некорректный цвет`
		)
	end
	local function knownName(list: { string }, listName: string, name: string, value: string)
		assert(table.find(list, value) ~= nil, `VisualConfig: {name} = {value} нет в {listName}`)
	end

	-- Цвета эмоций: ровно EmotionTypes, попарно различимы (это основной сигнал фрагмента).
	local emotions = PetSpeciesConfig.EmotionTypes
	for key in c.EmotionColors do
		assert(table.find(emotions, key :: any) ~= nil, `VisualConfig: EmotionColors.{key} — нет такой эмоции`)
	end
	for i, a in emotions do
		local colorA = c.EmotionColors[a]
		isColor(`EmotionColors.{a}`, colorA)
		for j = i + 1, #emotions do
			local colorB = c.EmotionColors[emotions[j]]
			local distance = math.abs(colorA.R - colorB.R) + math.abs(colorA.G - colorB.G) + math.abs(colorA.B - colorB.B)
			assert(distance > 0.3, `VisualConfig: цвета эмоций {a} и {emotions[j]} слишком похожи`)
		end
	end

	-- Тиры ауры: ровно Rarities, Tier строго растёт, флаги и интенсивность не убывают.
	local rarities = PetSpeciesConfig.Rarities
	for key in c.RarityAura do
		assert(table.find(rarities, key) ~= nil, `VisualConfig: RarityAura.{key} — нет такой редкости`)
	end
	local previous: AuraTier? = nil
	for _, rarity in rarities do
		local tier = c.RarityAura[rarity]
		assert(tier ~= nil, `VisualConfig: нет RarityAura.{rarity}`)
		isColor(`RarityAura.{rarity}.Color`, tier.Color)
		nonNegative(`RarityAura.{rarity}.LightBrightness`, tier.LightBrightness)
		nonNegative(`RarityAura.{rarity}.ParticleRate`, tier.ParticleRate)
		assert(tier.Glow == (tier.LightBrightness > 0), `VisualConfig: RarityAura.{rarity} — Glow без яркости или наоборот`)
		assert(
			(tier.ContourParticles or tier.FullAura) == (tier.ParticleRate > 0),
			`VisualConfig: RarityAura.{rarity} — частицы без ParticleRate или наоборот`
		)
		if previous then
			assert(tier.Tier > previous.Tier, `VisualConfig: RarityAura.{rarity}.Tier не больше младшей редкости`)
			for _, flag in { "Glow", "ContourParticles", "FullAura", "SecretMarker" } do
				assert(
					not (previous :: any)[flag] or (tier :: any)[flag],
					`VisualConfig: RarityAura.{rarity}.{flag} выключен, хотя у младшей редкости включён`
				)
			end
			assert(tier.LightBrightness >= previous.LightBrightness, `VisualConfig: RarityAura.{rarity} светит слабее младшей`)
			assert(tier.ParticleRate >= previous.ParticleRate, `VisualConfig: RarityAura.{rarity} частиц меньше младшей`)
		else
			assert(tier.Tier == 0, "VisualConfig: младшая редкость должна иметь Tier = 0")
		end
		previous = tier
	end
	local first = c.RarityAura[rarities[1]]
	assert(
		not (first.Glow or first.ContourParticles or first.FullAura or first.SecretMarker),
		`VisualConfig: у младшей редкости {rarities[1]} не должно быть ауры`
	)
	local last = c.RarityAura[rarities[#rarities]]
	assert(last.SecretMarker, `VisualConfig: у старшей редкости {rarities[#rarities]} должен быть маркер`)
	assert(
		not c.RarityAura[rarities[#rarities - 1]].SecretMarker,
		"VisualConfig: SecretMarker — только сверх предпоследней редкости"
	)

	positive("Effects.MaxConcurrentBursts", c.Effects.MaxConcurrentBursts)
	assert(c.Effects.MaxConcurrentBursts % 1 == 0, "VisualConfig: Effects.MaxConcurrentBursts — целое")
	positive("Effects.MaxBurstsPerSecond", c.Effects.MaxBurstsPerSecond)
	positive("Effects.BurstLifetime", c.Effects.BurstLifetime)
	positive("Effects.BurstVisibleDistance", c.Effects.BurstVisibleDistance)

	nonNegative("Fragment.BobAmplitude", c.Fragment.BobAmplitude)
	nonNegative("Fragment.BobSpeed", c.Fragment.BobSpeed)
	nonNegative("Fragment.SpinSpeed", c.Fragment.SpinSpeed)
	nonNegative("Fragment.IdleParticleRate", c.Fragment.IdleParticleRate)
	positive("Fragment.CollectBurstCount", c.Fragment.CollectBurstCount)
	positive("Fragment.LodDistance", c.Fragment.LodDistance)
	inRange("Fragment.BiomeRingTransparency", c.Fragment.BiomeRingTransparency, 0, 1)
	positive("Fragment.MagnetFlyDuration", c.Fragment.MagnetFlyDuration)
	nonNegative("Fragment.MagnetFlyArc", c.Fragment.MagnetFlyArc)
	inRange("Fragment.MagnetEndScale", c.Fragment.MagnetEndScale, 0.05, 1)
	positive("Fragment.MagnetArriveBurstCount", c.Fragment.MagnetArriveBurstCount)
	positive("Fragment.MagnetMaxFlights", c.Fragment.MagnetMaxFlights)

	positive("Pets.FollowBack", c.Pets.FollowBack)
	positive("Pets.SideSpacing", c.Pets.SideSpacing)
	positive("Pets.Responsiveness", c.Pets.Responsiveness)
	nonNegative("Pets.IdleBobAmplitude", c.Pets.IdleBobAmplitude)
	nonNegative("Pets.IdleBobSpeed", c.Pets.IdleBobSpeed)
	positive("Pets.RenderDistance", c.Pets.RenderDistance)
	positive("Pets.MaxRendered", c.Pets.MaxRendered)
	nonNegative("Pets.MutationSparkleRate", c.Pets.MutationSparkleRate)

	positive("Cocoon.ShakeDuration", c.Cocoon.ShakeDuration)
	positive("Cocoon.GlowDuration", c.Cocoon.GlowDuration)
	positive("Cocoon.BurstCount", c.Cocoon.BurstCount)
	positive("Cocoon.RevealDuration", c.Cocoon.RevealDuration)
	positive("Cocoon.DistanceInFront", c.Cocoon.DistanceInFront)
	isColor("Cocoon.ShellColor", c.Cocoon.ShellColor)
	isColor("Cocoon.CrackColor", c.Cocoon.CrackColor)

	nonNegative("Boss.BobAmplitude", c.Boss.BobAmplitude)
	nonNegative("Boss.BobSpeed", c.Boss.BobSpeed)
	nonNegative("Boss.SwayDegrees", c.Boss.SwayDegrees)
	isColor("Boss.HitFlashColor", c.Boss.HitFlashColor)
	positive("Boss.HitFlashTime", c.Boss.HitFlashTime)
	inRange("Boss.HitPulseScale", c.Boss.HitPulseScale, 1, 1.5)
	positive("Boss.DeathParticleCount", c.Boss.DeathParticleCount)
	positive("Boss.DeathDuration", c.Boss.DeathDuration)
	positive("Boss.SpawnRiseDuration", c.Boss.SpawnRiseDuration)
	positive("Boss.EndedWaitTimeout", c.Boss.EndedWaitTimeout)
	isColor("Boss.TelegraphColor", c.Boss.TelegraphColor)
	positive("Boss.TelegraphRadius", c.Boss.TelegraphRadius)
	inRange("Boss.SkyDarkenBrightness", c.Boss.SkyDarkenBrightness, -1, 0)
	inRange("Boss.SkyDarkenSaturation", c.Boss.SkyDarkenSaturation, -1, 0)
	isColor("Boss.SkyTint", c.Boss.SkyTint)

	local origin = c.Factory.Origin
	assert(
		origin ~= nil and isFinite(origin.X) and isFinite(origin.Y) and isFinite(origin.Z),
		"VisualConfig: Factory.Origin некорректен"
	)
	assert(isFinite(c.Factory.YawDegrees), "VisualConfig: Factory.YawDegrees некорректен")
	positive("Factory.BeltLength", c.Factory.BeltLength)
	positive("Factory.SlatCount", c.Factory.SlatCount)
	positive("Factory.BeltSpeed", c.Factory.BeltSpeed)
	nonNegative("Factory.MaxRidingFragments", c.Factory.MaxRidingFragments)
	positive("Factory.FlashParticleCount", c.Factory.FlashParticleCount)
	isColor("Factory.FlashColor", c.Factory.FlashColor)

	-- Свет и декор: ровно биомы BiomeConfig.
	for key in c.BiomeLighting do
		assert(BiomeConfig[key] ~= nil, `VisualConfig: BiomeLighting.{key} — нет такого биома`)
	end
	for key in c.BiomeDecor do
		assert(BiomeConfig[key] ~= nil, `VisualConfig: BiomeDecor.{key} — нет такого биома`)
	end
	for biomeId in BiomeConfig do
		local lighting = c.BiomeLighting[biomeId]
		assert(lighting ~= nil, `VisualConfig: нет BiomeLighting.{biomeId}`)
		inRange(`BiomeLighting.{biomeId}.ClockTime`, lighting.ClockTime, 0, 24)
		nonNegative(`BiomeLighting.{biomeId}.Brightness`, lighting.Brightness)
		isColor(`BiomeLighting.{biomeId}.Ambient`, lighting.Ambient)
		isColor(`BiomeLighting.{biomeId}.OutdoorAmbient`, lighting.OutdoorAmbient)
		inRange(`BiomeLighting.{biomeId}.AtmosphereDensity`, lighting.AtmosphereDensity, 0, 1)
		inRange(`BiomeLighting.{biomeId}.AtmosphereHaze`, lighting.AtmosphereHaze, 0, 10)
		inRange(`BiomeLighting.{biomeId}.TintStrength`, lighting.TintStrength, 0, 1)
		inRange(`BiomeLighting.{biomeId}.Saturation`, lighting.Saturation, -1, 1)

		local decor = c.BiomeDecor[biomeId]
		assert(decor ~= nil, `VisualConfig: нет BiomeDecor.{biomeId}`)
		local terrain = c.TerrainMaterialNames
		knownName(terrain, "TerrainMaterialNames", `BiomeDecor.{biomeId}.GroundMaterial`, decor.GroundMaterial)
		knownName(terrain, "TerrainMaterialNames", `BiomeDecor.{biomeId}.FeatureMaterial`, decor.FeatureMaterial)
		knownName(terrain, "TerrainMaterialNames", `BiomeDecor.{biomeId}.AccentMaterial`, decor.AccentMaterial)
		nonNegative(`BiomeDecor.{biomeId}.FeatureCount`, decor.FeatureCount)
		positive(`BiomeDecor.{biomeId}.FeatureMinRadius`, decor.FeatureMinRadius)
		assert(
			isFinite(decor.FeatureMaxRadius) and decor.FeatureMaxRadius >= decor.FeatureMinRadius,
			`VisualConfig: BiomeDecor.{biomeId}.FeatureMaxRadius меньше FeatureMinRadius`
		)
		positive(`BiomeDecor.{biomeId}.Margin`, decor.Margin)
		nonNegative(`BiomeDecor.{biomeId}.SpawnClearance`, decor.SpawnClearance)
	end
	positive("BiomeLightingTweenTime", c.BiomeLightingTweenTime)
	assert(isFinite(c.DecorSeed) and c.DecorSeed % 1 == 0, "VisualConfig: DecorSeed — целое")

	local p = c.PlayerEffects
	isColor("PlayerEffects.ShieldColor", p.ShieldColor)
	positive("PlayerEffects.ShieldDiameter", p.ShieldDiameter)
	nonNegative("PlayerEffects.ShieldBlinkBefore", p.ShieldBlinkBefore)
	isColor("PlayerEffects.RaidVignetteColor", p.RaidVignetteColor)
	positive("PlayerEffects.RaidVignetteDuration", p.RaidVignetteDuration)
	isColor("PlayerEffects.RebirthFlashColor", p.RebirthFlashColor)
	positive("PlayerEffects.RebirthFlashDuration", p.RebirthFlashDuration)
	positive("PlayerEffects.RebirthParticleCount", p.RebirthParticleCount)
	positive("PlayerEffects.RebirthRingDiameter", p.RebirthRingDiameter)
end

return VisualConfig
