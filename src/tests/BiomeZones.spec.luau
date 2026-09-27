--[[
	Тесты S15 (контент биомов 3-4, раздел 5.7 ТЗ):
	- BiomeConfig: LucidDreams добавлен, прогрессия порогов/бонусов остаётся монотонной;
	- CollectionConfig: у Nightmares и LucidDreams появились зоны спавна, привязанные к своему
	  биому; точки трёх зон не пересекаются геометрически;
	- фрагменты из новых зон проходят через уже существующий collectFragment без новой логики.

	Запуск: lune run src/tests/run (из корня репозитория).
]]

local Harness = require("./lib/Harness")

type Test = { Name: string, Run: () -> () }

local tests: { Test } = {}

local function test(name: string, run: () -> ())
	table.insert(tests, { Name = name, Run = run })
end

local fakePets = {
	GetCachedBonuses = function()
		return { ConveyorSpeedMultiplier = 1, CollectionRadiusMultiplier = 1 }
	end,
}

-- Мир с CollectionSystem: тот же каркас, что и в FragmentEmotion.spec.luau.
local function collectionSetup()
	local world = Harness.NewWorld()
	local _, dataSystem = world:NewServer()
	local profiles = {}
	local handlers = {}
	local modules: { [string]: any } = {
		["src/server/Systems/DataSystem"] = {
			GetData = function(p)
				return profiles[p]
			end,
			WaitForData = function(p)
				return profiles[p]
			end,
			BuildDefaultProfile = dataSystem.BuildDefaultProfile,
		},
		["src/server/Systems/PetSystem"] = fakePets,
		["src/shared/Remotes"] = {
			RequestCollect = {
				OnServerEvent = {
					Connect = function(_self, fn)
						handlers.RequestCollect = fn
					end,
				},
			},
		},
	}
	local collection = world:LoadModule("src/server/Systems/CollectionSystem", modules)

	local player = world:NewPlayer(1)
	local data = dataSystem.BuildDefaultProfile()
	profiles[player] = data
	world.Players = { player }

	local t = { World = world, Collection = collection, Player = player, Data = data }

	function t.Fragments()
		local list = {}
		for _, instance in world.Instances do
			if instance.ClassName == "Part" and instance:GetAttribute("FragmentId") and not instance.Destroyed then
				table.insert(list, instance)
			end
		end
		return list
	end

	-- Ставит персонажа прямо на фрагмент и шлёт RequestCollect(id); время сдвигается за кулдаун.
	function t.Collect(fragment)
		local root = {
			Position = fragment.Position,
			IsA = function(_self, name)
				return name == "BasePart"
			end,
		}
		local humanoid = { Health = 100 }
		player.Character = {
			FindFirstChildOfClass = function(_self, className)
				return if className == "Humanoid" then humanoid else nil
			end,
			FindFirstChild = function(_self, name)
				return if name == "HumanoidRootPart" then root else nil
			end,
		}
		world:Advance(10)
		handlers.RequestCollect(player, fragment:GetAttribute("FragmentId"))
	end

	return t
end

local function rawTotal(data): number
	local total = 0
	for _, value in data.Factory.RawFragments do
		total += value
	end
	return total
end

------------------------------------------------------------------------------------------
-- BiomeConfig
------------------------------------------------------------------------------------------

test("BiomeConfig: LucidDreams описан, порог и бонус монотонны относительно Nightmares", function()
	local world = Harness.NewWorld()
	local biomes = world:LoadModule("src/shared/Config/BiomeConfig")

	local lucid = assert(biomes.LucidDreams, "LucidDreams есть в конфиге")
	assert(lucid.Id == "LucidDreams")
	assert(lucid.RebirthThreshold >= 8 and lucid.RebirthThreshold <= 12, `порог {lucid.RebirthThreshold} вне диапазона GDD 8-12`)
	assert(lucid.RebirthThreshold > biomes.Nightmares.RebirthThreshold, "LucidDreams открывается позже Nightmares")
	assert(
		lucid.ClarityMultiplierBonus > biomes.Nightmares.ClarityMultiplierBonus,
		"бонус LucidDreams больше, чем у Nightmares (монотонная прогрессия)"
	)
	assert(biomes.Nightmares.ClarityMultiplierBonus > biomes.DreamMeadow.ClarityMultiplierBonus, "Nightmares больше DreamMeadow")

	assert(lucid.FragmentColor.R and lucid.FragmentColor.G and lucid.FragmentColor.B, "у LucidDreams есть цвет фрагмента")
end)

test("BiomeConfig: пороги всех биомов уникальны, ровно один с порогом 0 (load-time assert не сломан)", function()
	local world = Harness.NewWorld()
	local biomes = world:LoadModule("src/shared/Config/BiomeConfig")
	local seen: { [number]: string } = {}
	local zeroCount = 0
	local count = 0
	for key, biome in biomes do
		count += 1
		assert(not seen[biome.RebirthThreshold], `дубль порога {biome.RebirthThreshold}: {key} и {seen[biome.RebirthThreshold]}`)
		seen[biome.RebirthThreshold] = key
		if biome.RebirthThreshold == 0 then
			zeroCount += 1
		end
	end
	assert(count == 3, `ожидались 3 биома (DreamMeadow, Nightmares, LucidDreams), получено {count}`)
	assert(zeroCount == 1, "ровно один биом с порогом 0")
end)

------------------------------------------------------------------------------------------
-- CollectionConfig: зоны Nightmares и LucidDreams
------------------------------------------------------------------------------------------

test("CollectionConfig: у Nightmares и LucidDreams есть зоны, привязанные к своему BiomeId", function()
	local world = Harness.NewWorld()
	local config = world:LoadModule("src/shared/Config/CollectionConfig")
	local biomes = world:LoadModule("src/shared/Config/BiomeConfig")

	local byBiome: { [string]: { any } } = {}
	for _, zone in config.Zones do
		assert(biomes[zone.BiomeId], `зона {zone.Id}: биом {zone.BiomeId} не найден в BiomeConfig`)
		byBiome[zone.BiomeId] = byBiome[zone.BiomeId] or {}
		table.insert(byBiome[zone.BiomeId], zone)
		assert(#zone.SpawnPoints > 0, `у зоны {zone.Id} есть точки спавна`)
		assert(zone.MaxFragments > 0, `у зоны {zone.Id} MaxFragments > 0`)
	end

	assert(byBiome.DreamMeadow and #byBiome.DreamMeadow >= 1, "у DreamMeadow есть зона")
	assert(byBiome.Nightmares and #byBiome.Nightmares >= 1, "у Nightmares теперь есть зона")
	assert(byBiome.LucidDreams and #byBiome.LucidDreams >= 1, "у LucidDreams есть зона")
end)

test("CollectionConfig: точки спавна трёх зон не пересекаются геометрически", function()
	local world = Harness.NewWorld()
	local config = world:LoadModule("src/shared/Config/CollectionConfig")

	-- Ни одна пара зон не делит общую точку спавна.
	local allPoints: { [string]: string } = {}
	for _, zone in config.Zones do
		for _, point in zone.SpawnPoints do
			local key = `{point.X},{point.Y},{point.Z}`
			assert(not allPoints[key], `точка {key} есть и в {allPoints[key]}, и в {zone.Id}`)
			allPoints[key] = zone.Id
		end
	end

	-- Диапазоны Z по зонам не пересекаются (зоны разнесены по оси Z, как DreamMeadow).
	local ranges: { [string]: { Min: number, Max: number } } = {}
	for _, zone in config.Zones do
		local minZ, maxZ = math.huge, -math.huge
		for _, point in zone.SpawnPoints do
			minZ = math.min(minZ, point.Z)
			maxZ = math.max(maxZ, point.Z)
		end
		ranges[zone.Id] = { Min = minZ, Max = maxZ }
	end
	local zoneIds = {}
	for id in ranges do
		table.insert(zoneIds, id)
	end
	for i = 1, #zoneIds do
		for j = i + 1, #zoneIds do
			local a, b = ranges[zoneIds[i]], ranges[zoneIds[j]]
			local overlaps = a.Min <= b.Max and b.Min <= a.Max
			assert(not overlaps, `зоны {zoneIds[i]} и {zoneIds[j]} пересекаются по Z`)
		end
	end
end)

------------------------------------------------------------------------------------------
-- Сбор фрагментов из новых зон
------------------------------------------------------------------------------------------

test("Сбор: фрагменты из зон Nightmares и LucidDreams собираются тем же collectFragment", function()
	local t = collectionSetup()
	t.Collection.Init()

	local byRange = { Nightmares = {}, LucidDreams = {} }
	for _, fragment in t.Fragments() do
		local z = fragment.Position.Z
		if z >= 100 and z < 200 then
			table.insert(byRange.Nightmares, fragment)
		elseif z >= 200 then
			table.insert(byRange.LucidDreams, fragment)
		end
	end
	assert(#byRange.Nightmares > 0, "заспавнился хотя бы один фрагмент в Nightmares")
	assert(#byRange.LucidDreams > 0, "заспавнился хотя бы один фрагмент в LucidDreams")

	local before = rawTotal(t.Data)
	t.Collect(byRange.Nightmares[1])
	assert(rawTotal(t.Data) == before + 1, "фрагмент Nightmares засчитан")
	assert(byRange.Nightmares[1].Destroyed)

	before = rawTotal(t.Data)
	t.Collect(byRange.LucidDreams[1])
	assert(rawTotal(t.Data) == before + 1, "фрагмент LucidDreams засчитан")
	assert(byRange.LucidDreams[1].Destroyed)
end)

test("Спавн: цвет фрагмента берётся из BiomeConfig[zone.BiomeId].FragmentColor", function()
	local t = collectionSetup()
	local biomes = t.World:LoadModule("src/shared/Config/BiomeConfig")
	t.Collection.Init()

	local seenColors = { DreamMeadow = false, Nightmares = false, LucidDreams = false }
	for _, fragment in t.Fragments() do
		local z = fragment.Position.Z
		local biomeId = if z < 100 then "DreamMeadow" elseif z < 200 then "Nightmares" else "LucidDreams"
		local expected = biomes[biomeId].FragmentColor
		assert(
			fragment.Color.R == expected.R and fragment.Color.G == expected.G and fragment.Color.B == expected.B,
			`{biomeId}: цвет фрагмента не совпадает с FragmentColor`
		)
		seenColors[biomeId] = true
	end
	assert(seenColors.DreamMeadow and seenColors.Nightmares and seenColors.LucidDreams, "проверены фрагменты всех трёх биомов")
end)

return tests
