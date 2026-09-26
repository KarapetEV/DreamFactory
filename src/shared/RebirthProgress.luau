--!strict

--[[
	RebirthProgress — множитель ясности и биом по числу rebirth (раздел 5.4 ТЗ).
	Чистая функция только от BiomeConfig и StartingProfileConfig, без обращений к Instance и
	к серверным системам: её требуют и RebirthSystem (запись при rebirth), и DataSystem
	(пересчёт при загрузке профиля) — общий модуль исключает круговой require между ними.
]]

local BiomeConfig = require(script.Parent.Config.BiomeConfig)
local StartingProfileConfig = require(script.Parent.Config.StartingProfileConfig)

export type RebirthProgress = {
	ClarityMultiplier: number,
	CurrentBiome: string,
}

local RebirthProgress = {}

-- ClarityMultiplier = стартовый + Σ ClarityMultiplierBonus биомов с RebirthThreshold ≤ count
-- (с нуля, не накопление); CurrentBiome — открытый биом с наибольшим порогом.
function RebirthProgress.Compute(rebirthCount: number): RebirthProgress
	local multiplier = StartingProfileConfig.ClarityMultiplier
	local biomeId = StartingProfileConfig.StartingBiomeId
	local bestThreshold = -1
	for id, biome in BiomeConfig do
		if biome.RebirthThreshold <= rebirthCount then
			multiplier += biome.ClarityMultiplierBonus
			if biome.RebirthThreshold > bestThreshold then
				bestThreshold = biome.RebirthThreshold
				biomeId = id
			end
		end
	end
	return {
		ClarityMultiplier = multiplier,
		CurrentBiome = biomeId,
	}
end

return RebirthProgress
