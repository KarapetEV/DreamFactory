--[[
	Тесты данных визуала MVP (VisualConfig, VisualModels, EquippedPetsCodec). Сам визуал
	(партиклы, CFrame-движение) lune не проверяет — это смотрится в Studio. Здесь:
	- цвет по EmotionType есть у каждой эмоции и различим; тиры ауры монотонны по редкости,
	  у Secret — маркер сверх Legendary;
	- у каждого вида пета своя модель и свой силуэт; модель босса вписана в BossSize;
	- свет/декор есть у каждого биома BiomeConfig;
	- битые конфиги падают при загрузке (load-time assert, как во всём проекте);
	- кодек атрибута надетых петов: порядок, лимит слотов, мусор не роняет разбор.

	Запуск: lune run src/tests/run (из корня репозитория).
]]

local Harness = require("./lib/Harness")

type Test = { Name: string, Run: () -> () }

local tests: { Test } = {}

local function test(name: string, run: () -> ())
	table.insert(tests, { Name = name, Run = run })
end

local VISUAL_CONFIG = "src/shared/Config/VisualConfig"
local VISUAL_MODELS = "src/shared/Config/VisualModels"
local CODEC = "src/shared/EquippedPetsCodec"

local function load(path: string): any
	return Harness.NewWorld():LoadModule(path)
end

-- Загрузка модуля path с патчем исходника patchPath должна упасть с ожидаемой ошибкой.
local function loadFails(patchPath: string, patch: (string) -> string, expected: string, path: string?)
	local world = Harness.NewWorld()
	world.SourcePatches[patchPath] = function(source: string): string
		local patched = patch(source)
		assert(patched ~= source, "патч не применился — тест устарел")
		return patched
	end
	local ok, err = pcall(world.LoadModule, world, path or patchPath)
	assert(not ok, `битый конфиг загрузился (ожидалось: {expected})`)
	assert(string.find(tostring(err), expected, 1, true), `другая ошибка: {err}`)
end

local function replaceOnce(source: string, from: string, to: string): string
	local start, finish = string.find(source, from, 1, true)
	if not start then
		return source
	end
	return string.sub(source, 1, start - 1) .. to .. string.sub(source, finish + 1)
end

------------------------------------------------------------------------------------------
-- VisualConfig
------------------------------------------------------------------------------------------

test("VisualConfig: цвет у каждой эмоции, эмоции различимы", function()
	local config = load(VISUAL_CONFIG)
	local species = load("src/shared/Config/PetSpeciesConfig")
	for _, emotion in species.EmotionTypes do
		local color = config.EmotionColors[emotion]
		assert(color and color.R and color.G and color.B, `нет цвета эмоции {emotion}`)
	end
	-- Эмоции из ТЗ: Joyful — тёплый жёлтый (R, G > B), Nostalgic — голубой (B доминирует),
	-- Fearful — фиолетовый (R и B > G).
	local joyful, nostalgic, fearful = config.EmotionColors.Joyful, config.EmotionColors.Nostalgic, config.EmotionColors.Fearful
	assert(joyful.R > joyful.B and joyful.G > joyful.B, "Joyful — тёплый жёлтый")
	assert(nostalgic.B > nostalgic.R and nostalgic.B >= nostalgic.G, "Nostalgic — голубой")
	assert(fearful.B > fearful.G and fearful.R > fearful.G, "Fearful — фиолетовый")
end)

test("VisualConfig: аура монотонна по редкости — Common без ауры, Secret с маркером сверх Legendary", function()
	local config = load(VISUAL_CONFIG)
	local species = load("src/shared/Config/PetSpeciesConfig")
	local order = species.Rarities
	local common, secret = config.RarityAura[order[1]], config.RarityAura[order[#order]]
	assert(not (common.Glow or common.ContourParticles or common.FullAura or common.SecretMarker), "Common без ауры")
	assert(config.RarityAura.Rare.Glow and not config.RarityAura.Rare.ContourParticles, "Rare — лёгкое свечение")
	assert(config.RarityAura.Epic.ContourParticles and not config.RarityAura.Epic.FullAura, "Epic — частицы по контуру")
	assert(config.RarityAura.Legendary.FullAura and not config.RarityAura.Legendary.SecretMarker, "Legendary — полная аура")
	assert(secret.FullAura and secret.SecretMarker, "Secret — полная аура + маркер")
	for i = 2, #order do
		assert(config.RarityAura[order[i]].Tier > config.RarityAura[order[i - 1]].Tier, `Tier растёт на {order[i]}`)
	end
end)

test("VisualConfig: свет и Terrain-декор у каждого биома BiomeConfig", function()
	local config = load(VISUAL_CONFIG)
	local biomes = load("src/shared/Config/BiomeConfig")
	for biomeId, biome in biomes do
		assert(config.BiomeLighting[biomeId], `нет света {biomeId}`)
		assert(config.BiomeDecor[biomeId], `нет декора {biomeId}`)
		assert(biome.AccentColor and biome.AccentColor.R, `нет AccentColor у {biomeId}`)
	end
	-- Кошмары темнее луга (GDD 5.7: гнетущая тьма).
	assert(config.BiomeLighting.Nightmares.Brightness < config.BiomeLighting.DreamMeadow.Brightness)
end)

test("VisualConfig: битые данные роняют загрузку", function()
	loadFails(VISUAL_CONFIG, function(source)
		return replaceOnce(source, "Fearful = Color3.fromRGB(165, 40, 255)", "Fearful = Color3.fromRGB(255, 200, 61)")
	end, "слишком похожи")
	loadFails(VISUAL_CONFIG, function(source)
		-- Legendary без полной ауры, хотя у Secret она есть — монотонность нарушена наоборот:
		-- у Epic частицы есть, у Legendary выключаем контур.
		local legendary = string.find(source, "Legendary = {", 1, true)
		assert(legendary)
		local head, tail = string.sub(source, 1, legendary), string.sub(source, legendary + 1)
		return head .. replaceOnce(tail, "ContourParticles = true", "ContourParticles = false")
	end, "Legendary.ContourParticles выключен")
	loadFails(VISUAL_CONFIG, function(source)
		return replaceOnce(source, "GroundMaterial = \"Basalt\"", "GroundMaterial = \"Lava\"")
	end, "нет в TerrainMaterialNames")
	loadFails(VISUAL_CONFIG, function(source)
		return replaceOnce(source, "HitPulseScale = 1.06", "HitPulseScale = 0.5")
	end, "Boss.HitPulseScale")
	loadFails(VISUAL_CONFIG, function(source)
		return replaceOnce(source, "MaxConcurrentBursts = 6", "MaxConcurrentBursts = 0")
	end, "Effects.MaxConcurrentBursts")
end)

------------------------------------------------------------------------------------------
-- VisualModels
------------------------------------------------------------------------------------------

test("VisualModels: у каждого вида пета своя модель и свой силуэт", function()
	local models = load(VISUAL_MODELS)
	local species = load("src/shared/Config/PetSpeciesConfig")
	local signatures: { [string]: string } = {}
	for speciesId in species.Species do
		local spec = models.Pets[speciesId]
		assert(spec and #spec.Parts > 0, `нет модели {speciesId}`)
		local bounds = models.ComputeBounds(spec)
		local size = bounds.Max - bounds.Min
		-- Силуэт: габарит (с точностью 0.1) + число деталей. Совпадение двух видов — подозрение
		-- на копипасту модели.
		local signature = string.format("%.1f/%.1f/%.1f/%d", size.X, size.Y, size.Z, #spec.Parts)
		for otherId, other in signatures do
			assert(other ~= signature, `силуэты {speciesId} и {otherId} совпадают`)
		end
		signatures[speciesId] = signature
	end
end)

test("VisualModels: модель босса вписана в ChaosBossConfig.BossSize и заполняет его", function()
	local models = load(VISUAL_MODELS)
	local boss = load("src/shared/Config/ChaosBossConfig")
	local bounds = models.ComputeBounds(models.ChaosBoss)
	local size = bounds.Max - bounds.Min
	assert(size.X <= boss.BossSize.X + 0.01 and size.Y <= boss.BossSize.Y + 0.01 and size.Z <= boss.BossSize.Z + 0.01)
	assert(size.Y >= boss.BossSize.Y * 0.9, `высота {size.Y} заметно меньше BossSize.Y`)
end)

test("VisualModels: кристалл фрагмента окрашен по эмоции, кольцо — по биому", function()
	local models = load(VISUAL_MODELS)
	local emotionParts, biomeParts = 0, 0
	for _, p in models.FragmentCrystal.Parts do
		if p.Color == "Emotion" then
			emotionParts += 1
		elseif p.Color == "Biome" then
			biomeParts += 1
			assert(p.Static, "кольцо биома не качается вместе с кристаллом")
		end
	end
	assert(emotionParts >= 3, "эмоция — основной сигнал: большинство деталей")
	assert(biomeParts == 1, "цвет биома — одна вторичная деталь")
end)

test("VisualModels: ComputeBounds учитывает поворот детали", function()
	local models = load(VISUAL_MODELS)
	local function vec(x: number, y: number, z: number)
		return { X = x, Y = y, Z = z }
	end
	local spec = {
		Parts = {
			{ Shape = "Block", Size = vec(4, 2, 2), Offset = vec(0, 0, 0), Rotation = vec(0, 0, 90) },
		},
	}
	local bounds = models.ComputeBounds(spec)
	-- Блок 4×2 повёрнут на 90° вокруг Z: по X — 2, по Y — 4.
	assert(math.abs(bounds.Max.X - 1) < 1e-6 and math.abs(bounds.Max.Y - 2) < 1e-6, `габарит {bounds.Max.X}, {bounds.Max.Y}`)
end)

test("VisualModels: битая геометрия роняет загрузку", function()
	loadFails(VISUAL_MODELS, function(source)
		return replaceOnce(source, "part(\"Block\", v(5, 4.2, 4.5), v(0, 5.4, -0.4)", "part(\"Block\", v(5, 4.2, 4.5), v(0, 7.4, -0.4)")
	end, "выходит за ChaosBossConfig.BossSize")
	loadFails(VISUAL_MODELS, function(source)
		return replaceOnce(source, "\t\tMoonOwl = moonOwl(),\n", "")
	end, "нет модели для вида MoonOwl")
	loadFails(VISUAL_MODELS, function(source)
		return replaceOnce(source, "\"Nose\")", "\"Snout\")")
	end, "роль цвета Snout")
	loadFails(VISUAL_MODELS, function(source)
		return replaceOnce(source, "part(\"Ball\", v(1, 1, 1), v(0, 0.3, 1.2)", "part(\"Ball\", v(1, 2, 1), v(0, 0.3, 1.2)")
	end, "у Ball стороны должны быть равны")
end)

------------------------------------------------------------------------------------------
-- EquippedPetsCodec
------------------------------------------------------------------------------------------

local function pet(speciesId: string, rarity: string, equipped: boolean, mutation: string?)
	return { Id = speciesId .. rarity, SpeciesId = speciesId, Rarity = rarity, Equipped = equipped, Level = 1, Mutation = mutation }
end

test("EquippedPetsCodec: только надетые, в порядке инвентаря, не больше слотов", function()
	local codec = load(CODEC)
	local pets = {
		pet("DozySheep", "Common", false),
		pet("CloudFox", "Legendary", true, "Shiny"),
		pet("MoonOwl", "Secret", true),
		pet("StarJelly", "Rare", true),
	}
	assert(codec.Encode(pets, 2) == "CloudFox:Legendary:1;MoonOwl:Secret:0", codec.Encode(pets, 2))
	local decoded = codec.Decode(codec.Encode(pets, 3))
	assert(#decoded == 3)
	assert(decoded[1].SpeciesId == "CloudFox" and decoded[1].Rarity == "Legendary" and decoded[1].Mutated)
	assert(decoded[3].SpeciesId == "StarJelly" and not decoded[3].Mutated)
end)

test("EquippedPetsCodec: неизвестные виды/редкости и мусор пропускаются", function()
	local codec = load(CODEC)
	assert(codec.Encode({ pet("Dragon", "Common", true), pet("MoonOwl", "Mythic", true) }, 6) == "")
	assert(codec.Encode("garbage" :: any, 3) == "")
	assert(#codec.Decode(nil) == 0)
	assert(#codec.Decode(42) == 0)
	local decoded = codec.Decode("Dragon:Common:0;MoonOwl:Rare:1;;bad;MoonOwl:Rare:7;DozySheep:Epic:0")
	assert(#decoded == 2 and decoded[1].SpeciesId == "MoonOwl" and decoded[2].SpeciesId == "DozySheep")
	-- Подделанная длинная строка: разбор ограничен MaxDecoded.
	local long = string.rep("DozySheep:Common:0;", 100)
	assert(#codec.Decode(long) == codec.MaxDecoded)
end)

------------------------------------------------------------------------------------------
-- EffectBudget (лимит одновременных вспышек частиц)
------------------------------------------------------------------------------------------

local EFFECT_BUDGET = "src/client/Visuals/EffectBudget"

test("EffectBudget: не больше maxConcurrent одновременно, слот освобождается через lifetime", function()
	local budget = load(EFFECT_BUDGET).new(3, 100, 1)
	local slots = {}
	for i = 1, 3 do
		slots[i] = budget:TryAcquire(0.01 * i)
		assert(slots[i], `вспышка {i} разрешена`)
	end
	assert(slots[1] ~= slots[2] and slots[2] ~= slots[3], "разные слоты")
	assert(budget:TryAcquire(0.05) == nil, "четвёртая одновременная — отброшена")
	assert(budget:ActiveCount(0.05) == 3)
	assert(budget:TryAcquire(1.02) ~= nil, "после lifetime слот свободен")
end)

test("EffectBudget: не больше maxPerSecond запусков за скользящую секунду", function()
	local budget = load(EFFECT_BUDGET).new(10, 4, 0.05)
	local granted = 0
	for i = 0, 19 do
		if budget:TryAcquire(i * 0.05) then -- 20 запросов за секунду, слоты освобождаются быстро
			granted += 1
		end
	end
	assert(granted == 4, `за секунду разрешено {granted}`)
	assert(budget:TryAcquire(1.01) ~= nil, "в следующей секунде — снова можно")
end)

test("VisualConfig.Effects: бюджет вспышек сборки ограничен (плотный сбор не сажает FPS)", function()
	local config = load(VISUAL_CONFIG)
	local budget = load(EFFECT_BUDGET).new(
		config.Effects.MaxConcurrentBursts,
		config.Effects.MaxBurstsPerSecond,
		config.Effects.BurstLifetime
	)
	-- Авто-сборщик + ручной сбор: 100 фрагментов за 2 секунды.
	local granted = 0
	for i = 0, 99 do
		if budget:TryAcquire(i * 0.02) then
			granted += 1
		end
	end
	assert(granted <= config.Effects.MaxBurstsPerSecond * 2, `разрешено {granted}`)
	assert(budget:ActiveCount(1.99) <= config.Effects.MaxConcurrentBursts)
end)

------------------------------------------------------------------------------------------
-- BiomeLocator и Terrain-декор
------------------------------------------------------------------------------------------

test("BiomeLocator: точки спавна каждой зоны относятся к биому своей зоны", function()
	local world = Harness.NewWorld()
	local locator = world:LoadModule("src/shared/BiomeLocator")
	local collection = world:LoadModule("src/shared/Config/CollectionConfig")
	for _, zone in collection.Zones do
		for _, point in zone.SpawnPoints do
			assert(locator.BiomeAt(point) == zone.BiomeId, `{zone.Id}: точка отнесена к {locator.BiomeAt(point)}`)
		end
	end
end)

test("WorldDecor.Plan: подложка у каждой зоны, холмы не закрывают точки спавна фрагментов", function()
	local world = Harness.NewWorld()
	local decor = world:LoadModule("src/server/Services/WorldDecor")
	local config = world:LoadModule(VISUAL_CONFIG)
	local collection = world:LoadModule("src/shared/Config/CollectionConfig")
	local fills = decor.Plan(config.DecorSeed)

	local grounds: { [string]: number } = {}
	for _, fill in fills do
		assert(table.find(config.TerrainMaterialNames, fill.Material), `материал {fill.Material}`)
		local biomeDecor = config.BiomeDecor[fill.BiomeId]
		if fill.Kind == "Block" then
			assert(fill.Material == biomeDecor.GroundMaterial)
			grounds[fill.BiomeId] = (grounds[fill.BiomeId] or 0) + 1
		elseif fill.Material == biomeDecor.FeatureMaterial then
			for _, zone in collection.Zones do
				for _, point in zone.SpawnPoints do
					local dx, dz = point.X - fill.Center.X, point.Z - fill.Center.Z
					local distance = math.sqrt(dx * dx + dz * dz)
					assert(
						distance >= fill.Radius + biomeDecor.SpawnClearance - 1e-6,
						`холм {fill.BiomeId} в {distance} studs от точки спавна {zone.Id}`
					)
				end
			end
		end
	end
	for _, zone in collection.Zones do
		assert((grounds[zone.BiomeId] or 0) >= 1, `нет подложки у {zone.BiomeId}`)
	end
end)

test("WorldDecor.Plan: рельеф под точкой спавна не отрывает персонажа от фрагмента (сбор касанием)", function()
	-- Регрессия плейтеста: подложка поднимала землю до y≈3, фрагмент (центр y=3, радиус 1)
	-- уходил в грунт, а корень персонажа (земля + HipHeight 2 + 1, полувысота 1) до него не
	-- доставал — Touched не срабатывал. Требуем перекрытие корня и фрагмента ≥ 1 stud:
	-- видимая поверхность ≤ точка спавна − 2.
	local world = Harness.NewWorld()
	local decor = world:LoadModule("src/server/Services/WorldDecor")
	local config = world:LoadModule(VISUAL_CONFIG)
	local collection = world:LoadModule("src/shared/Config/CollectionConfig")
	local fills = decor.Plan(config.DecorSeed)
	assert(decor.SurfaceY > 0, "поверхность выше Baseplate — без z-fighting")

	for _, zone in collection.Zones do
		for _, point in zone.SpawnPoints do
			local top = -math.huge -- верх заливок над этой точкой по горизонтали
			for _, fill in fills do
				if fill.Kind == "Block" then
					local half = fill.Size
					if
						math.abs(point.X - fill.Center.X) <= half.X / 2
						and math.abs(point.Z - fill.Center.Z) <= half.Z / 2
					then
						top = math.max(top, fill.Center.Y + half.Y / 2)
					end
				else
					local dx, dz = point.X - fill.Center.X, point.Z - fill.Center.Z
					local d2 = dx * dx + dz * dz
					if d2 < fill.Radius * fill.Radius then
						top = math.max(top, fill.Center.Y + math.sqrt(fill.Radius * fill.Radius - d2))
					end
				end
			end
			local surface = top + decor.TerrainSurfaceOffset
			assert(surface <= point.Y - 2 + 1e-6, `{zone.Id}: поверхность {surface} под точкой {point.X},{point.Z}`)
		end
	end
end)

------------------------------------------------------------------------------------------
-- Лента фабрики: цвета по реальному содержимому буфера
------------------------------------------------------------------------------------------

local BELT_LOAD = "src/client/Visuals/BeltLoad"

local function tally(list)
	local result = { Joyful = 0, Nostalgic = 0, Fearful = 0 }
	for _, emotion in list do
		result[emotion] += 1
	end
	return result
end

test("BeltLoad: буфер влезает — на ленте ровно его содержимое, в порядке переработки", function()
	local belt = load(BELT_LOAD)
	local list = belt.Allocate({ Joyful = 0, Nostalgic = 2, Fearful = 1 }, 6)
	assert(#list == 3 and list[1] == "Nostalgic" and list[2] == "Nostalgic" and list[3] == "Fearful", table.concat(list, ","))
	assert(#belt.Allocate({ Joyful = 0, Nostalgic = 0, Fearful = 0 }, 6) == 0, "пустой буфер — пустая лента")
end)

test("BeltLoad: буфер больше ленты — пропорционально, каждая эмоция из буфера видна", function()
	local belt = load(BELT_LOAD)
	local counts = tally(belt.Allocate({ Joyful = 60, Nostalgic = 30, Fearful = 10 }, 6))
	assert(counts.Joyful + counts.Nostalgic + counts.Fearful == 6)
	assert(counts.Joyful == 3 and counts.Nostalgic == 2 and counts.Fearful == 1, `{counts.Joyful}/{counts.Nostalgic}/{counts.Fearful}`)

	counts = tally(belt.Allocate({ Joyful = 98, Nostalgic = 0, Fearful = 1 }, 6))
	assert(counts.Fearful == 1 and counts.Joyful == 5 and counts.Nostalgic == 0, "редкая эмоция не пропадает с ленты")
end)

test("BeltLoad: мусор вместо разбивки (старый/битый снимок) — пустая лента, без ошибки", function()
	local belt = load(BELT_LOAD)
	assert(#belt.Allocate(nil, 6) == 0)
	assert(#belt.Allocate({ Joyful = 0 / 0, Nostalgic = -3, Fearful = math.huge }, 6) == 0)
	assert(#belt.Allocate({ Joyful = 5 }, 0) == 0)
end)

return tests
