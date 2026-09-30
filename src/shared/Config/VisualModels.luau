--!strict

--[[
	Геометрия моделей MVP-визуала: каждая модель — список Part'ов (Block/Ball/Cylinder/Wedge/
	CornerWedge/Ellipsoid) относительно центра модели. Собирает клиент (Visuals/Rig); сервер
	эту геометрию не использует — хитбоксы (фрагмент, босс) остаются серверными Part.
	Кубический/геометрический силуэт — осознанно: цель MVP — узнаваемость и разный силуэт.

	Соглашения:
	- Offset — центр детали от центра модели (studs); «вперёд» модели — −Z (как LookVector).
	- Rotation — градусы, CFrame.fromEulerAnglesXYZ (сначала Z, затем Y, затем X).
	- Ellipsoid — Block с SpecialMesh Sphere (растягивается по Size); Ball — равные стороны;
	  Cylinder — ось по X, Size.Y == Size.Z.
	- Color — имя роли: цвет из Palette модели или из DynamicRoles (подставляется в рантайме:
	  Emotion — VisualConfig.EmotionColors, Biome — BiomeConfig.AccentColor).
	- Swing — процедурное покачивание детали: поворот вокруг оси Axis модели, проходящей через
	  точку Pivot (координаты модели), на Degrees·sin(t·Speed + Phase). Детали одной
	  конечности имеют одинаковый Swing и двигаются как одно целое.
	- Spin — вращение детали вокруг вертикали через её центр (рад/с).
	- Static — деталь не участвует в покачивании/вращении всей модели (кольцо под фрагментом).
	- Tag — метка для кода эффектов (трещины кокона, окно фабрики, ядро босса).

	Проверки при загрузке: размеры/смещения конечны, формы/материалы/роли известны, у каждого
	вида пета из PetSpeciesConfig есть модель, модель босса помещается в ChaosBossConfig.BossSize.
]]

local UpgradeEffects = require(script.Parent.Parent.UpgradeEffects)
local PetSpeciesConfig = require(script.Parent.PetSpeciesConfig)
local ChaosBossConfig = require(script.Parent.ChaosBossConfig)
local VisualConfig = require(script.Parent.VisualConfig)

export type SwingSpec = {
	Axis: "X" | "Y" | "Z",
	Degrees: number,
	Speed: number, -- рад/с
	Phase: number?,
	Pivot: Vector3,
}

export type PartSpec = {
	Shape: string,
	Size: Vector3,
	Offset: Vector3,
	Rotation: Vector3?,
	Color: string,
	Material: string?, -- по умолчанию SmoothPlastic
	Transparency: number?,
	Swing: SwingSpec?,
	Spin: number?,
	Static: boolean?,
	Tag: string?,
}

export type ModelSpec = {
	Parts: { PartSpec },
	Palette: { [string]: Color3 },
	DynamicRoles: { string }?,
}

export type PetModelSpec = ModelSpec & {
	-- Высота центра модели над землёй: у ходящих — до низа лап, у летающих — с запасом.
	Hover: number,
}

export type Bounds = { Min: Vector3, Max: Vector3 }

local SHAPES = { "Block", "Ball", "Cylinder", "Wedge", "CornerWedge", "Ellipsoid" }

local function v(x: number, y: number, z: number): Vector3
	return Vector3.new(x, y, z)
end

-- Деталь с обязательными полями + необязательные из extra.
local function part(shape: string, size: Vector3, offset: Vector3, color: string, extra: { [string]: any }?): PartSpec
	local spec: { [string]: any } = { Shape = shape, Size = size, Offset = offset, Color = color }
	if extra then
		for key, value in extra do
			spec[key] = value
		end
	end
	return spec :: any
end

-- Пара симметричных деталей (зеркало по X): side = +1 правая, −1 левая. build(side) → PartSpec.
local function mirrored(parts: { PartSpec }, build: (side: number) -> PartSpec)
	table.insert(parts, build(1))
	table.insert(parts, build(-1))
end

------------------------------------------------------------------------------------------
-- Петы
------------------------------------------------------------------------------------------

local function dozySheep(): PetModelSpec
	local parts: { PartSpec } = {
		part("Ellipsoid", v(2.4, 1.8, 2.8), v(0, 0, 0), "Primary", { Material = "Fabric" }),
		part("Ball", v(1.3, 1.3, 1.3), v(0, 0.75, 0.5), "Primary", { Material = "Fabric" }),
		part("Ball", v(1.1, 1.1, 1.1), v(0.75, 0.55, -0.35), "Primary", { Material = "Fabric" }),
		part("Ball", v(1.1, 1.1, 1.1), v(-0.75, 0.55, -0.35), "Primary", { Material = "Fabric" }),
		part("Ball", v(1, 1, 1), v(0, 0.3, 1.2), "Primary", { Material = "Fabric" }),
		part("Block", v(1, 1, 1), v(0, 0.3, -1.55), "Secondary"),
		-- Ночной колпак: клин на макушке.
		part("Wedge", v(0.7, 0.8, 0.9), v(0, 1.2, -1.45), "Accent", { Rotation = v(0, 180, 0) }),
	}
	mirrored(parts, function(side)
		-- Ушки лениво покачиваются.
		return part("Ellipsoid", v(0.7, 0.22, 0.4), v(0.65 * side, 0.45, -1.45), "Secondary", {
			Rotation = v(0, 0, -20 * side),
			Swing = { Axis = "Z", Degrees = 12 * side, Speed = 2.5, Pivot = v(0.4 * side, 0.45, -1.45) },
		})
	end)
	mirrored(parts, function(side)
		-- Сонные закрытые глаза — светящиеся полоски.
		return part("Block", v(0.3, 0.07, 0.05), v(0.22 * side, 0.4, -2.07), "Eye", { Material = "Neon" })
	end)
	for _, z in { -0.75, 0.75 } do
		mirrored(parts, function(side)
			return part("Block", v(0.35, 0.55, 0.35), v(0.6 * side, -0.95, z), "Secondary")
		end)
	end
	return {
		Parts = parts,
		Palette = {
			Primary = Color3.fromRGB(250, 246, 235),
			Secondary = Color3.fromRGB(80, 70, 95),
			Accent = Color3.fromRGB(130, 150, 255),
			Eye = Color3.fromRGB(255, 240, 190),
		},
		Hover = 1.25,
	}
end

local function pillowMoth(): PetModelSpec
	local parts: { PartSpec } = {
		part("Ellipsoid", v(0.9, 0.9, 1.9), v(0, 0, 0), "Primary", { Material = "Fabric" }),
		part("Ball", v(0.95, 0.95, 0.95), v(0, 0.1, -1), "Primary", { Material = "Fabric" }),
	}
	mirrored(parts, function(side)
		return part("Block", v(1.9, 0.1, 1.4), v(1.3 * side, 0.25, -0.2), "Secondary", {
			Rotation = v(0, 0, 12 * side),
			Transparency = 0.1,
			Swing = { Axis = "Z", Degrees = 35 * side, Speed = 11, Pivot = v(0.35 * side, 0.2, -0.2) },
		})
	end)
	mirrored(parts, function(side)
		return part("Block", v(1.3, 0.1, 1), v(1 * side, 0.05, 0.75), "Accent", {
			Swing = { Axis = "Z", Degrees = 25 * side, Speed = 11, Phase = 0.4, Pivot = v(0.35 * side, 0.05, 0.75) },
		})
	end)
	mirrored(parts, function(side)
		return part("Block", v(0.08, 0.9, 0.08), v(0.25 * side, 0.8, -1.25), "Accent", {
			Rotation = v(-25, 0, -20 * side),
		})
	end)
	mirrored(parts, function(side)
		return part("Ball", v(0.32, 0.32, 0.32), v(0.28 * side, 0.25, -1.38), "Eye")
	end)
	return {
		Parts = parts,
		Palette = {
			Primary = Color3.fromRGB(232, 222, 255),
			Secondary = Color3.fromRGB(175, 205, 255),
			Accent = Color3.fromRGB(140, 170, 240),
			Eye = Color3.fromRGB(55, 45, 85),
		},
		Hover = 3.2,
	}
end

local function starJelly(): PetModelSpec
	local parts: { PartSpec } = {
		part("Ellipsoid", v(2.1, 1.5, 2.1), v(0, 0.4, 0), "Primary", { Material = "Glass", Transparency = 0.3 }),
		part("Ball", v(0.9, 0.9, 0.9), v(0, 0.35, 0), "Accent", { Material = "Neon" }),
		part("Cylinder", v(0.2, 2.2, 2.2), v(0, -0.3, 0), "Secondary", { Rotation = v(0, 0, 90), Transparency = 0.2 }),
		-- Восьмилучевая звезда на макушке — два повёрнутых квадрата, медленно вращается.
		part("Block", v(0.9, 0.9, 0.18), v(0, 1.45, 0), "Accent", { Material = "Neon", Spin = 1.2 }),
		part("Block", v(0.9, 0.9, 0.18), v(0, 1.45, 0), "Accent", { Material = "Neon", Rotation = v(0, 0, 45), Spin = 1.2 }),
	}
	for index = 0, 4 do
		local angle = index * math.pi * 2 / 5
		local x, z = 0.65 * math.cos(angle), 0.65 * math.sin(angle)
		table.insert(
			parts,
			part("Block", v(0.16, 1.7, 0.16), v(x, -1.2, z), "Secondary", {
				Swing = { Axis = "X", Degrees = 15, Speed = 3, Phase = index * 1.2, Pivot = v(x, -0.35, z) },
			})
		)
	end
	mirrored(parts, function(side)
		return part("Ball", v(0.25, 0.25, 0.25), v(0.3 * side, 0.35, -0.98), "Eye")
	end)
	return {
		Parts = parts,
		Palette = {
			Primary = Color3.fromRGB(255, 185, 140),
			Secondary = Color3.fromRGB(255, 150, 175),
			Accent = Color3.fromRGB(255, 235, 130),
			Eye = Color3.fromRGB(60, 35, 60),
		},
		Hover = 3.5,
	}
end

local function cloudFox(): PetModelSpec
	local tailSwing: SwingSpec = { Axis = "Y", Degrees = 22, Speed = 5, Pivot = v(0, 0.3, 1) }
	local parts: { PartSpec } = {
		part("Ellipsoid", v(1.3, 1.2, 2.3), v(0, 0, 0), "Primary"),
		part("Ball", v(1, 1, 1), v(0, 0.2, -0.9), "Primary"),
		part("Block", v(1.1, 1, 1), v(0, 0.6, -1.35), "Primary"),
		part("Wedge", v(0.6, 0.45, 0.6), v(0, 0.35, -2.1), "Primary"),
		part("Ball", v(0.2, 0.2, 0.2), v(0, 0.5, -2.42), "Nose"),
		-- Большой облачный хвост — главный элемент силуэта.
		part("Ellipsoid", v(0.95, 0.95, 2), v(0, 0.55, 1.7), "Secondary", { Rotation = v(-35, 0, 0), Swing = tailSwing }),
		part("Ball", v(0.75, 0.75, 0.75), v(0, 1.15, 2.45), "Accent", { Swing = tailSwing }),
	}
	mirrored(parts, function(side)
		return part("Wedge", v(0.3, 0.7, 0.5), v(0.35 * side, 1.45, -1.3), "Primary")
	end)
	mirrored(parts, function(side)
		-- Резкие светящиеся фиолетовые глаза (Fearful).
		return part("Block", v(0.28, 0.14, 0.05), v(0.26 * side, 0.72, -1.87), "Eye", { Material = "Neon" })
	end)
	for _, z in { -0.7, 0.7 } do
		mirrored(parts, function(side)
			return part("Block", v(0.3, 0.6, 0.3), v(0.4 * side, -0.75, z), "Primary")
		end)
	end
	return {
		Parts = parts,
		Palette = {
			Primary = Color3.fromRGB(240, 238, 252),
			Secondary = Color3.fromRGB(170, 130, 240),
			Accent = Color3.fromRGB(255, 255, 255),
			Eye = Color3.fromRGB(190, 90, 255),
			Nose = Color3.fromRGB(60, 50, 80),
		},
		Hover = 1.05,
	}
end

local function dreamWhale(): PetModelSpec
	local tailSwing: SwingSpec = { Axis = "X", Degrees = 15, Speed = 2.5, Pivot = v(0, 0.1, 1.6) }
	local parts: { PartSpec } = {
		part("Ellipsoid", v(2, 1.8, 3.8), v(0, 0, 0), "Primary"),
		part("Ellipsoid", v(1.6, 1, 3.2), v(0, -0.45, -0.15), "Secondary"),
		part("Ellipsoid", v(0.9, 0.8, 1.4), v(0, 0.2, 2.2), "Primary", { Swing = tailSwing }),
		part("Block", v(2, 0.15, 0.8), v(0, 0.3, 2.9), "Accent", { Swing = tailSwing }),
		part("Ball", v(0.25, 0.25, 0.25), v(0, 0.95, -0.6), "Star", { Material = "Neon" }),
		part("Ball", v(0.25, 0.25, 0.25), v(0.3, 0.9, 0.3), "Star", { Material = "Neon" }),
		part("Ball", v(0.25, 0.25, 0.25), v(-0.25, 0.85, 1), "Star", { Material = "Neon" }),
	}
	mirrored(parts, function(side)
		return part("Block", v(1, 0.12, 0.55), v(1.15 * side, -0.35, -0.4), "Accent", {
			Rotation = v(0, 0, -25 * side),
			Swing = { Axis = "Z", Degrees = 15 * side, Speed = 2.5, Pivot = v(0.8 * side, -0.3, -0.4) },
		})
	end)
	mirrored(parts, function(side)
		return part("Ball", v(0.3, 0.3, 0.3), v(0.88 * side, 0.15, -1.15), "Eye", { Material = "Neon" })
	end)
	return {
		Parts = parts,
		Palette = {
			Primary = Color3.fromRGB(80, 110, 205),
			Secondary = Color3.fromRGB(200, 215, 255),
			Accent = Color3.fromRGB(150, 180, 255),
			Eye = Color3.fromRGB(240, 250, 255),
			Star = Color3.fromRGB(255, 240, 160),
		},
		Hover = 3.8,
	}
end

local function moonOwl(): PetModelSpec
	local parts: { PartSpec } = {
		part("Ellipsoid", v(1.6, 2.1, 1.5), v(0, 0, 0), "Primary"),
		part("Cylinder", v(0.12, 1.35, 1.35), v(0, 0.35, -0.66), "Secondary", { Rotation = v(0, 90, 0) }),
		part("Wedge", v(0.22, 0.28, 0.25), v(0, 0.12, -0.82), "Beak"),
		-- Лунный диск над головой.
		part("Cylinder", v(0.12, 0.7, 0.7), v(0, 1.45, 0.1), "Moon", { Material = "Neon", Rotation = v(0, 90, 0), Spin = 1 }),
	}
	mirrored(parts, function(side)
		return part("Ball", v(0.48, 0.48, 0.48), v(0.3 * side, 0.45, -0.74), "Eye", { Material = "Neon" })
	end)
	mirrored(parts, function(side)
		return part("Ball", v(0.2, 0.2, 0.2), v(0.3 * side, 0.45, -0.97), "Pupil")
	end)
	mirrored(parts, function(side)
		return part("Wedge", v(0.25, 0.55, 0.35), v(0.5 * side, 1.2, -0.1), "Primary", { Rotation = v(0, 0, -15 * side) })
	end)
	mirrored(parts, function(side)
		return part("Ellipsoid", v(0.3, 1.5, 1.1), v(0.92 * side, -0.05, 0.1), "Wing", {
			Swing = { Axis = "Z", Degrees = 30 * side, Speed = 7, Pivot = v(0.8 * side, 0.5, 0.1) },
		})
	end)
	mirrored(parts, function(side)
		return part("Block", v(0.3, 0.15, 0.35), v(0.3 * side, -1.1, -0.2), "Beak")
	end)
	return {
		Parts = parts,
		Palette = {
			Primary = Color3.fromRGB(105, 90, 160),
			Secondary = Color3.fromRGB(225, 215, 245),
			Wing = Color3.fromRGB(80, 65, 130),
			Eye = Color3.fromRGB(255, 215, 80),
			Pupil = Color3.fromRGB(30, 20, 40),
			Beak = Color3.fromRGB(240, 170, 70),
			Moon = Color3.fromRGB(255, 245, 190),
		},
		Hover = 3,
	}
end

------------------------------------------------------------------------------------------
-- Кокон, фрагмент, босс, фабрика
------------------------------------------------------------------------------------------

local function cocoon(): ModelSpec
	local parts: { PartSpec } = {
		part("Ellipsoid", v(2.2, 3, 2.2), v(0, 0, 0), "Shell", { Material = "Fabric" }),
		part("Ellipsoid", v(2.35, 0.35, 2.35), v(0, 0.7, 0), "Band", { Rotation = v(0, 0, 8), Material = "Fabric" }),
		part("Ellipsoid", v(2.35, 0.35, 2.35), v(0, -0.6, 0), "Band", { Rotation = v(0, 0, -6), Material = "Fabric" }),
		part("Ball", v(0.6, 0.6, 0.6), v(0, 1.45, 0), "Band"),
		part("Block", v(0.25, 0.6, 0.25), v(0, -1.7, 0), "Band"),
	}
	-- Трещины: невидимы до второй стадии эффекта (CocoonEffect).
	local cracks = {
		{ v(0.45, 0.2, -1.08), v(0, 0, 25) },
		{ v(-0.35, -0.3, -1.08), v(0, 0, -30) },
		{ v(0.9, -0.1, -0.7), v(0, -45, 15) },
		{ v(-0.95, 0.4, -0.55), v(0, 45, -20) },
		{ v(0.1, 0.8, -0.95), v(0, 0, 70) },
	}
	for _, crack in cracks do
		table.insert(
			parts,
			part("Block", v(0.08, 1.1, 0.06), crack[1], "Crack", {
				Rotation = crack[2],
				Material = "Neon",
				Transparency = 1,
				Tag = "Crack",
			})
		)
	end
	return {
		Parts = parts,
		Palette = {
			Shell = VisualConfig.Cocoon.ShellColor,
			Band = Color3.fromRGB(205, 185, 240),
			Crack = VisualConfig.Cocoon.CrackColor,
		},
	}
end

-- Огранённый кристалл: куб на вершине + призма-ось + два осколка, светящееся ядро внутри.
-- Цвет — эмоция фрагмента; кольцо под ним — цвет биома (вторичный акцент, Static).
local function fragmentCrystal(): ModelSpec
	return {
		Parts = {
			part("Ball", v(0.7, 0.7, 0.7), v(0, 0, 0), "Emotion", { Material = "Neon" }),
			part("Block", v(1.1, 1.1, 1.1), v(0, 0, 0), "Emotion", {
				Rotation = v(45, 35.26, 0),
				Material = "Glass",
				Transparency = 0.3,
			}),
			part("Block", v(0.5, 2.3, 0.5), v(0, 0, 0), "Emotion", {
				Rotation = v(0, 45, 0),
				Material = "Glass",
				Transparency = 0.15,
			}),
			part("Block", v(0.35, 0.9, 0.35), v(0.55, -0.5, 0.2), "Emotion", {
				Rotation = v(0, 30, -30),
				Material = "Glass",
				Transparency = 0.2,
			}),
			part("Block", v(0.3, 0.75, 0.3), v(-0.5, -0.55, -0.25), "Emotion", {
				Rotation = v(20, -20, 25),
				Material = "Glass",
				Transparency = 0.2,
			}),
			part("Cylinder", v(0.12, 2.8, 2.8), v(0, -1.35, 0), "Biome", {
				Rotation = v(0, 0, 90),
				Material = "Neon",
				Static = true,
				Tag = "BiomeRing",
			}),
		},
		Palette = {},
		DynamicRoles = { "Emotion", "Biome" },
	}
end

local function chaosBoss(): ModelSpec
	local armSwing = function(side: number): SwingSpec
		return { Axis = "X", Degrees = 10, Speed = 1.2, Phase = if side > 0 then 0 else math.pi, Pivot = v(4 * side, 2, -0.6) }
	end
	local parts: { PartSpec } = {
		-- Нижний «дымный» шлейф вместо ног: босс парит.
		part("Ellipsoid", v(7, 5, 7), v(0, -5, 0), "Secondary", { Transparency = 0.25 }),
		part("Ellipsoid", v(8, 8.5, 7), v(0, 0, 0), "Primary"),
		part("Cylinder", v(0.4, 3.2, 3.2), v(0, 0.8, -3.3), "Secondary", { Rotation = v(0, 90, 0) }),
		part("Ball", v(2.2, 2.2, 2.2), v(0, 0.8, -3.45), "Core", { Material = "Neon", Tag = "Core" }),
		part("Block", v(5, 4.2, 4.5), v(0, 5.4, -0.4), "Primary"),
		part("Block", v(2.8, 0.5, 0.3), v(0, 4.2, -2.7), "Eye", { Material = "Neon" }),
		part("Wedge", v(0.8, 2.2, 1.6), v(0, 3.2, 3.4), "Horn", { Rotation = v(-30, 0, 0) }),
	}
	mirrored(parts, function(side)
		return part("Ball", v(1, 1, 1), v(1.2 * side, 5.8, -2.7), "Eye", { Material = "Neon" })
	end)
	mirrored(parts, function(side)
		return part("Wedge", v(1.6, 0.6, 0.5), v(1.2 * side, 6.6, -2.6), "Primary", { Rotation = v(0, 0, 12 * side) })
	end)
	mirrored(parts, function(side)
		return part("Wedge", v(0.9, 2.4, 1.4), v(1.9 * side, 6.6, 0), "Horn", { Rotation = v(0, 0, -20 * side) })
	end)
	mirrored(parts, function(side)
		return part("CornerWedge", v(1.6, 2.4, 1.6), v(3 * side, 4.2, 0.6), "Horn")
	end)
	mirrored(parts, function(side)
		return part("Ellipsoid", v(2.2, 6, 2.2), v(4.2 * side, -0.8, -0.6), "Primary", {
			Rotation = v(0, 0, 12 * side),
			Swing = armSwing(side),
		})
	end)
	for _, claw in { { 4.3, -1.2 }, { 4.9, -0.4 } } do
		mirrored(parts, function(side)
			return part("Wedge", v(0.5, 1.4, 0.8), v(claw[1] * side, -4.5, claw[2]), "Horn", {
				Rotation = v(0, 180, 0),
				Swing = armSwing(side),
			})
		end)
	end
	return {
		Parts = parts,
		Palette = {
			Primary = Color3.fromRGB(35, 10, 50),
			Secondary = Color3.fromRGB(70, 20, 95),
			Horn = Color3.fromRGB(20, 5, 25),
			Eye = Color3.fromRGB(255, 40, 90),
			Core = Color3.fromRGB(255, 50, 120),
		},
	}
end

-- Статичное тело конвейера (лента вдоль X модели, вход −X, выход +X). Движущиеся планки
-- ленты и едущие фрагменты FactoryVisuals создаёт сам по VisualConfig.Factory.
local function factory(): ModelSpec
	local parts: { PartSpec } = {
		part("Block", v(30, 1, 10), v(0, 0.5, 0), "Base", { Material = "Slate" }),
		part("Block", v(24, 0.6, 3.2), v(0, 2.3, 0), "BeltBed"),
		part("Block", v(3.6, 2.6, 3.6), v(-13, 4, 0), "Hopper", { Material = "Glass", Transparency = 0.3 }),
		part("Block", v(4, 0.3, 4), v(-13, 5.4, 0), "Rail", { Material = "Metal" }),
		part("Block", v(5, 6, 6), v(12.5, 4, 0), "Machine"),
		part("Block", v(0.2, 2, 3.4), v(9.95, 4.5, 0), "Glow", { Material = "Neon", Tag = "Window" }),
		part("Cylinder", v(3, 1.4, 1.4), v(13.2, 8.5, 1.2), "Rail", { Rotation = v(0, 0, 90), Material = "Metal" }),
		part("Ball", v(1.2, 1.2, 1.2), v(13.2, 10.1, 1.2), "Glow", { Material = "Neon", Tag = "Window" }),
		part("Ball", v(1.6, 1.6, 1.6), v(12.5, 4, -3.3), "Glow", { Material = "Neon", Tag = "Output" }),
	}
	for _, x in { -10, -3, 4 } do
		table.insert(parts, part("Block", v(0.8, 1, 2.6), v(x, 1.5, 0), "Rail", { Material = "Metal" }))
	end
	mirrored(parts, function(side)
		return part("Block", v(24, 0.5, 0.25), v(0, 2.85, 1.75 * side), "Rail", { Material = "Metal" })
	end)
	return {
		Parts = parts,
		Palette = {
			Base = Color3.fromRGB(70, 65, 95),
			BeltBed = Color3.fromRGB(35, 32, 45),
			Hopper = Color3.fromRGB(150, 140, 200),
			Rail = Color3.fromRGB(120, 110, 160),
			Machine = Color3.fromRGB(95, 75, 150),
			Glow = VisualConfig.Factory.FlashColor,
		},
	}
end

------------------------------------------------------------------------------------------
-- Габариты (чистая функция: тесты и проверки при загрузке)
------------------------------------------------------------------------------------------

-- Поворот точки как CFrame.fromEulerAnglesXYZ(rx, ry, rz): R = Rx·Ry·Rz (градусы).
local function rotate(x: number, y: number, z: number, rotation: Vector3?): (number, number, number)
	if not rotation then
		return x, y, z
	end
	local rx, ry, rz = math.rad(rotation.X), math.rad(rotation.Y), math.rad(rotation.Z)
	-- Rz
	local cz, sz = math.cos(rz), math.sin(rz)
	x, y = x * cz - y * sz, x * sz + y * cz
	-- Ry
	local cy, sy = math.cos(ry), math.sin(ry)
	x, z = x * cy + z * sy, -x * sy + z * cy
	-- Rx
	local cx, sx = math.cos(rx), math.sin(rx)
	y, z = y * cx - z * sx, y * sx + z * cx
	return x, y, z
end

-- Осевой габарит модели в позе покоя (без Swing/Spin). Эллипсоиды считаются коробкой —
-- оценка сверху.
local function computeBounds(spec: ModelSpec): Bounds
	local minX, minY, minZ = math.huge, math.huge, math.huge
	local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
	for _, p in spec.Parts do
		local hx, hy, hz = p.Size.X / 2, p.Size.Y / 2, p.Size.Z / 2
		for _, sx in { -1, 1 } do
			for _, sy in { -1, 1 } do
				for _, sz in { -1, 1 } do
					local x, y, z = rotate(hx * sx, hy * sy, hz * sz, p.Rotation)
					x += p.Offset.X
					y += p.Offset.Y
					z += p.Offset.Z
					minX, minY, minZ = math.min(minX, x), math.min(minY, y), math.min(minZ, z)
					maxX, maxY, maxZ = math.max(maxX, x), math.max(maxY, y), math.max(maxZ, z)
				end
			end
		end
	end
	return { Min = Vector3.new(minX, minY, minZ), Max = Vector3.new(maxX, maxY, maxZ) }
end

------------------------------------------------------------------------------------------

local VisualModels = {
	Pets = {
		DozySheep = dozySheep(),
		PillowMoth = pillowMoth(),
		StarJelly = starJelly(),
		CloudFox = cloudFox(),
		DreamWhale = dreamWhale(),
		MoonOwl = moonOwl(),
	} :: { [string]: PetModelSpec },
	Cocoon = cocoon(),
	FragmentCrystal = fragmentCrystal(),
	ChaosBoss = chaosBoss(),
	Factory = factory(),
	Shapes = SHAPES,
	ComputeBounds = computeBounds,
}

-- Проверки при загрузке.
do
	local isFinite = UpgradeEffects.IsFinite

	local function finiteVector(value: Vector3?): boolean
		return value ~= nil and isFinite(value.X) and isFinite(value.Y) and isFinite(value.Z)
	end

	local function checkModel(name: string, spec: ModelSpec)
		assert(#spec.Parts > 0, `VisualModels: у {name} нет деталей`)
		for index, p in spec.Parts do
			local where = `VisualModels: {name}[{index}]`
			assert(table.find(SHAPES, p.Shape) ~= nil, `{where} — неизвестная форма {p.Shape}`)
			assert(
				finiteVector(p.Size) and p.Size.X > 0 and p.Size.Y > 0 and p.Size.Z > 0,
				`{where} — некорректный Size`
			)
			assert(finiteVector(p.Offset), `{where} — некорректный Offset`)
			assert(p.Rotation == nil or finiteVector(p.Rotation), `{where} — некорректный Rotation`)
			if p.Shape == "Ball" then
				assert(p.Size.X == p.Size.Y and p.Size.Y == p.Size.Z, `{where} — у Ball стороны должны быть равны`)
			elseif p.Shape == "Cylinder" then
				assert(p.Size.Y == p.Size.Z, `{where} — у Cylinder Size.Y должен равняться Size.Z`)
			end
			local material = p.Material or "SmoothPlastic"
			assert(table.find(VisualConfig.MaterialNames, material) ~= nil, `{where} — неизвестный материал {material}`)
			assert(
				p.Transparency == nil or (isFinite(p.Transparency) and p.Transparency >= 0 and p.Transparency <= 1),
				`{where} — Transparency вне [0, 1]`
			)
			local dynamic = spec.DynamicRoles and table.find(spec.DynamicRoles, p.Color) ~= nil
			assert(spec.Palette[p.Color] ~= nil or dynamic, `{where} — роль цвета {p.Color} нет в Palette/DynamicRoles`)
			if p.Swing then
				local swing = p.Swing
				assert(swing.Axis == "X" or swing.Axis == "Y" or swing.Axis == "Z", `{where} — Swing.Axis`)
				assert(isFinite(swing.Degrees) and math.abs(swing.Degrees) <= 90, `{where} — Swing.Degrees`)
				assert(isFinite(swing.Speed) and swing.Speed >= 0, `{where} — Swing.Speed`)
				assert(swing.Phase == nil or isFinite(swing.Phase), `{where} — Swing.Phase`)
				assert(finiteVector(swing.Pivot), `{where} — Swing.Pivot`)
			end
			assert(p.Spin == nil or isFinite(p.Spin), `{where} — Spin`)
		end
		for role, color in spec.Palette do
			assert(isFinite(color.R) and isFinite(color.G) and isFinite(color.B), `VisualModels: {name}.Palette.{role}`)
		end
	end

	-- Каждый вид пета — ровно одна модель, силуэт в разумных габаритах.
	for speciesId in VisualModels.Pets do
		assert(PetSpeciesConfig.Species[speciesId] ~= nil, `VisualModels: модель пета {speciesId} — нет такого вида`)
	end
	for speciesId in PetSpeciesConfig.Species do
		local spec = VisualModels.Pets[speciesId]
		assert(spec ~= nil, `VisualModels: нет модели для вида {speciesId}`)
		checkModel(`Pets.{speciesId}`, spec)
		assert(isFinite(spec.Hover) and spec.Hover >= 0, `VisualModels: Pets.{speciesId}.Hover`)
		local bounds = computeBounds(spec)
		local size = bounds.Max - bounds.Min
		local largest = math.max(size.X, size.Y, size.Z)
		assert(largest >= 1.5 and largest <= 6, `VisualModels: Pets.{speciesId} — габарит {largest} вне [1.5, 6]`)
		assert(-bounds.Min.Y <= spec.Hover + 0.05, `VisualModels: Pets.{speciesId} — модель ниже земли при Hover`)
	end

	checkModel("Cocoon", VisualModels.Cocoon)
	checkModel("FragmentCrystal", VisualModels.FragmentCrystal)
	checkModel("ChaosBoss", VisualModels.ChaosBoss)
	checkModel("Factory", VisualModels.Factory)

	-- Босс вписан в BossSize (хитбокс сервера) и заполняет его, а не болтается внутри.
	local limit = ChaosBossConfig.BossSize
	local bossBounds = computeBounds(VisualModels.ChaosBoss)
	local tolerance = 0.01
	assert(
		bossBounds.Min.X >= -limit.X / 2 - tolerance
			and bossBounds.Max.X <= limit.X / 2 + tolerance
			and bossBounds.Min.Y >= -limit.Y / 2 - tolerance
			and bossBounds.Max.Y <= limit.Y / 2 + tolerance
			and bossBounds.Min.Z >= -limit.Z / 2 - tolerance
			and bossBounds.Max.Z <= limit.Z / 2 + tolerance,
		"VisualModels: модель босса выходит за ChaosBossConfig.BossSize"
	)
	local bossSize = bossBounds.Max - bossBounds.Min
	assert(bossSize.Y >= 0.9 * limit.Y, "VisualModels: модель босса ниже 90% BossSize.Y")
	assert(bossSize.X >= 0.8 * limit.X, "VisualModels: модель босса уже 80% BossSize.X")
end

return VisualModels
