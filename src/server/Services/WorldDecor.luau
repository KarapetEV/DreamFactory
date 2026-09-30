--!strict

--[[
	WorldDecor — минимальный Terrain-декор биомов (визуал MVP). Под каждой зоной спавна
	CollectionConfig — подложка из Terrain-материала биома (VisualConfig.BiomeDecor), по краям —
	холмы/скалы, внутри — плоские вкрапления акцентного материала. Генерируется сервером один раз
	при старте (Terrain реплицируется всем), детерминированно от VisualConfig.DecorSeed —
	повторяемо из репозитория, без ручной правки плейса.

	- Plan() — чистая функция (lune-тесты): список заливок. Холмы не ближе
	  SpawnClearance + радиус к точкам спавна фрагментов — не закрывают фрагменты.
	- Высота: Terrain рисует поверхность на TERRAIN_SURFACE_OFFSET studs выше верхней границы
	  заливки (замерено в Studio: заливка до 0 → поверхность на 2). Подложка заливается так,
	  чтобы видимая поверхность была на SURFACE_Y — чуть выше Baseplate (0, без z-fighting) и
	  не выше, чем позволяет сбор касанием: корень персонажа (земля + HipHeight 2 + 1) должен
	  доставать до фрагмента на y = 3 ± 1. Иначе фрагменты перестают собираться.
	- Apply() заливает Terrain и вырезает воздух над SpawnLocation'ами плейса, чтобы подложка
	  не наползала на площадку спавна.
	Геймплей не зависит: сбор/дистанции считаются от серверных позиций, не от рельефа.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local VisualConfig = require(ReplicatedStorage.shared.Config.VisualConfig)
local CollectionConfig = require(ReplicatedStorage.shared.Config.CollectionConfig)
local BiomeLocator = require(ReplicatedStorage.shared.BiomeLocator)

export type Fill = {
	Kind: "Block" | "Ball",
	Center: Vector3,
	Size: Vector3?, -- Block
	Radius: number?, -- Ball
	Material: string,
	BiomeId: string,
}

local SURFACE_Y = 0.3 -- видимая поверхность подложки; Baseplate плейса — на 0
local TERRAIN_SURFACE_OFFSET = 2 -- поверхность Terrain выше верхней границы заливки
local FILL_TOP = SURFACE_Y - TERRAIN_SURFACE_OFFSET
local GROUND_THICKNESS = 8
local FEATURE_ATTEMPTS = 12

local WorldDecor = {}

WorldDecor.SurfaceY = SURFACE_Y
WorldDecor.TerrainSurfaceOffset = TERRAIN_SURFACE_OFFSET

local function spawnPointsOf(zoneId: string): { Vector3 }
	for _, zone in CollectionConfig.Zones do
		if zone.Id == zoneId then
			return zone.SpawnPoints
		end
	end
	return {}
end

-- Горизонтальное расстояние до ближайшей точки спавна зоны.
local function nearestSpawn(points: { Vector3 }, x: number, z: number): number
	local best = math.huge
	for _, point in points do
		local dx, dz = point.X - x, point.Z - z
		best = math.min(best, math.sqrt(dx * dx + dz * dz))
	end
	return best
end

function WorldDecor.Plan(seed: number): { Fill }
	local rng = Random.new(seed)
	local fills: { Fill } = {}
	for _, area in BiomeLocator.Areas do
		local decor = VisualConfig.BiomeDecor[area.BiomeId]
		if decor then
			local minX, maxX = area.MinX - decor.Margin, area.MaxX + decor.Margin
			local minZ, maxZ = area.MinZ - decor.Margin, area.MaxZ + decor.Margin
			local width, depth = maxX - minX, maxZ - minZ
			local centerX, centerZ = (minX + maxX) / 2, (minZ + maxZ) / 2
			local points = spawnPointsOf(area.ZoneId)

			table.insert(fills, {
				Kind = "Block",
				Center = Vector3.new(centerX, FILL_TOP - GROUND_THICKNESS / 2, centerZ),
				Size = Vector3.new(width, GROUND_THICKNESS, depth),
				Material = decor.GroundMaterial,
				BiomeId = area.BiomeId,
			})

			-- Холмы/скалы — у краёв подложки (полоса Margin), не ближе SpawnClearance к фрагментам.
			for _ = 1, decor.FeatureCount do
				for _ = 1, FEATURE_ATTEMPTS do
					local radius = rng:NextNumber(decor.FeatureMinRadius, decor.FeatureMaxRadius)
					local along = rng:NextNumber(0, 1)
					local inset = rng:NextNumber(radius * 0.3, decor.Margin * 0.6)
					local side = math.floor(rng:NextNumber(0, 4))
					local x, z
					if side == 0 then
						x, z = minX + inset, minZ + along * depth
					elseif side == 1 then
						x, z = maxX - inset, minZ + along * depth
					elseif side == 2 then
						x, z = minX + along * width, minZ + inset
					else
						x, z = minX + along * width, maxZ - inset
					end
					if nearestSpawn(points, x, z) >= radius + decor.SpawnClearance then
						table.insert(fills, {
							Kind = "Ball",
							Center = Vector3.new(x, FILL_TOP - radius * 0.35, z),
							Radius = radius,
							Material = decor.FeatureMaterial,
							BiomeId = area.BiomeId,
						})
						break
					end
				end
			end

			-- Плоские вкрапления: верх шара вровень с верхом подложки — рельеф не поднимается
			-- (бугорок под фрагментом снова оторвал бы персонажа от него), меняется только материал.
			for _ = 1, decor.FeatureCount do
				local radius = rng:NextNumber(2, 3.5)
				table.insert(fills, {
					Kind = "Ball",
					Center = Vector3.new(
						rng:NextNumber(minX + radius, maxX - radius),
						FILL_TOP - radius,
						rng:NextNumber(minZ + radius, maxZ - radius)
					),
					Radius = radius,
					Material = decor.AccentMaterial,
					BiomeId = area.BiomeId,
				})
			end
		end
	end
	return fills
end

function WorldDecor.Apply(fills: { Fill })
	local terrain = Workspace.Terrain
	for _, fill in fills do
		local material = (Enum.Material :: any)[fill.Material]
		if fill.Kind == "Block" and fill.Size then
			terrain:FillBlock(CFrame.new(fill.Center), fill.Size, material)
		elseif fill.Kind == "Ball" and fill.Radius then
			terrain:FillBall(fill.Center, fill.Radius, material)
		end
	end
	-- Площадки спавна остаются чистыми.
	for _, descendant in Workspace:GetDescendants() do
		if descendant:IsA("SpawnLocation") then
			local size = descendant.Size + Vector3.new(6, 0, 6)
			terrain:FillBlock(
				CFrame.new(descendant.Position.X, FILL_TOP, descendant.Position.Z),
				Vector3.new(size.X, GROUND_THICKNESS * 2, size.Z),
				Enum.Material.Air
			)
		end
	end
end

function WorldDecor.Init()
	local ok, err = pcall(function()
		WorldDecor.Apply(WorldDecor.Plan(VisualConfig.DecorSeed))
	end)
	if not ok then
		warn(`[WorldDecor] Terrain-декор не построен: {err}`)
	end
end

return WorldDecor
