--!strict

-- Каркас конфига: структура + заглушечные значения. Реальный баланс считает economy-balancer.
--
-- RebirthThreshold — число rebirth (Rebirth.Count), с которого биом открыт; ClarityMultiplierBonus —
-- прибавка к ClarityMultiplier за каждый открытый биом (RebirthSystem: стартовый множитель +
-- сумма бонусов открытых биомов; CurrentBiome — открытый биом с наибольшим порогом).
-- Пороги уникальны, ровно один биом с порогом 0 — гарантированный стартовый (проверяется ниже).

local UpgradeEffects = require(script.Parent.Parent.UpgradeEffects)

export type BiomeDefinition = {
	Id: string,
	DisplayName: string,
	RebirthThreshold: number,
	ClarityMultiplierBonus: number,
	-- Арт-заглушка: цвет фрагмента снов в этом биоме (CollectionSystem красит Part при спавне).
	FragmentColor: Color3,
}

local BiomeConfig: { [string]: BiomeDefinition } = {
	DreamMeadow = {
		Id = "DreamMeadow",
		DisplayName = "Сонный луг",
		RebirthThreshold = 0,
		ClarityMultiplierBonus = 0,
		FragmentColor = Color3.fromRGB(170, 140, 255),
	},
	Nightmares = {
		Id = "Nightmares",
		DisplayName = "Кошмары",
		RebirthThreshold = 5,
		ClarityMultiplierBonus = 0.5,
		FragmentColor = Color3.fromRGB(70, 15, 90), -- тёмно-фиолетовый (GDD 5.7: гнетущая тьма)
	},
	LucidDreams = {
		Id = "LucidDreams",
		DisplayName = "Люцидные Сны",
		RebirthThreshold = 10,
		ClarityMultiplierBonus = 1,
		FragmentColor = Color3.fromRGB(150, 220, 255), -- светло-голубой (GDD 5.7: ясность, контроль)
	},
}

-- Проверки при загрузке: RebirthSystem выбирает биом по порогу — дубли порогов сделали бы
-- выбор недетерминированным, отсутствие порога 0 оставило бы игрока без биома.
local isFinite = UpgradeEffects.IsFinite

do
	local thresholds: { [number]: string } = {}
	local zeroCount = 0
	for key, biome in BiomeConfig do
		assert(biome.Id == key, `BiomeConfig: ключ {key} не совпадает с Id {biome.Id}`)
		local threshold = biome.RebirthThreshold
		assert(
			isFinite(threshold) and threshold >= 0 and threshold % 1 == 0,
			`BiomeConfig: у {key} некорректный RebirthThreshold {threshold}`
		)
		assert(
			not thresholds[threshold],
			`BiomeConfig: RebirthThreshold {threshold} у {key} совпадает с {thresholds[threshold]}`
		)
		thresholds[threshold] = key
		if threshold == 0 then
			zeroCount += 1
		end
		assert(
			isFinite(biome.ClarityMultiplierBonus) and biome.ClarityMultiplierBonus >= 0,
			`BiomeConfig: у {key} некорректный ClarityMultiplierBonus {biome.ClarityMultiplierBonus}`
		)
		local color = biome.FragmentColor
		assert(
			color ~= nil and isFinite(color.R) and isFinite(color.G) and isFinite(color.B),
			`BiomeConfig: у {key} некорректный FragmentColor`
		)
	end
	assert(zeroCount == 1, `BiomeConfig: биомов с RebirthThreshold = 0 должно быть ровно 1, а их {zeroCount}`)
end

return BiomeConfig
