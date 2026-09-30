--!strict

--[[
	В каком биоме точка мира — только для визуала (свет/атмосфера у клиента, Terrain-декор у
	сервера). Биом — у ближайшей по горизонтали зоны спавна CollectionConfig (центр зоны —
	среднее её точек спавна). На сбор и прогресс не влияет: доступ к биомам решает сервер по
	Rebirth.Count.
]]

local CollectionConfig = require(script.Parent.Config.CollectionConfig)

export type ZoneArea = {
	ZoneId: string,
	BiomeId: string,
	CenterX: number,
	CenterZ: number,
	-- Габарит точек спавна по горизонтали (без отступа).
	MinX: number,
	MaxX: number,
	MinZ: number,
	MaxZ: number,
}

local BiomeLocator = {}

local areas: { ZoneArea } = {}
for _, zone in CollectionConfig.Zones do
	local sumX, sumZ = 0, 0
	local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
	for _, point in zone.SpawnPoints do
		sumX += point.X
		sumZ += point.Z
		minX, maxX = math.min(minX, point.X), math.max(maxX, point.X)
		minZ, maxZ = math.min(minZ, point.Z), math.max(maxZ, point.Z)
	end
	local count = #zone.SpawnPoints
	table.insert(areas, {
		ZoneId = zone.Id,
		BiomeId = zone.BiomeId,
		CenterX = sumX / count,
		CenterZ = sumZ / count,
		MinX = minX,
		MaxX = maxX,
		MinZ = minZ,
		MaxZ = maxZ,
	})
end

BiomeLocator.Areas = areas

-- Биом ближайшей зоны (по горизонтали). Зон нет — nil.
function BiomeLocator.BiomeAt(position: Vector3): string?
	local best: ZoneArea? = nil
	local bestDistance = math.huge
	for _, area in areas do
		local dx, dz = position.X - area.CenterX, position.Z - area.CenterZ
		local distance = dx * dx + dz * dz
		if distance < bestDistance then
			best = area
			bestDistance = distance
		end
	end
	return if best then best.BiomeId else nil
end

return BiomeLocator
