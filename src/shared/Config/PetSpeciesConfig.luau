--!strict

--[[
	Виды петов и их бонусы (раздел 5.3 ТЗ, GDD: эмоциональный окрас петов). Не секрет —
	клиент может брать отсюда тексты бонусов. Шансы выпадения видов — отдельно, server-only
	(src/server/Config/PetRarityConfig.luau); там же при загрузке проверяется, что каждый
	вид из таблицы шансов описан здесь и имеет бонус для своей редкости.

	Эмоции:
	  Joyful    — ускоряет конвейер (FactorySystem: задержка цикла делится на множитель);
	  Nostalgic — увеличивает радиус сбора (CollectionSystem: радиус умножается на множитель);
	  Fearful   — бонус к PvP-обороне ценой личного Хаоса. Эффекта пока нет: подключат
	              ChaosBossSystem (S13) и PvPRaidSystem (S17).

	BonusPerRarity — доля прибавки к множителю своей эмоции: 0.1 = +10%. Бонусы надетых петов
	одной эмоции складываются: множитель = 1 + Σ бонусов, затем зажимается в [1, MaxMultiplier].
	Мутация увеличивает бонус своего пета на MutationBonusFraction (0.1 = бонус × 1.1).

	Каркас: заглушечные значения. Реальный баланс считает economy-balancer.
]]

local UpgradeEffects = require(script.Parent.Parent.UpgradeEffects)

export type EmotionType = "Joyful" | "Nostalgic" | "Fearful"

export type SpeciesDefinition = {
	Id: string,
	DisplayName: string,
	EmotionType: EmotionType,
	-- Ключи — все редкости из Rarities.
	BonusPerRarity: { [string]: number },
}

export type PetSpeciesDefinition = {
	EmotionTypes: { EmotionType },
	-- Шкала редкостей от младшей к старшей; бонус вида по ней строго возрастает.
	Rarities: { string },
	MutationBonusFraction: number,
	-- Потолок каждого агрегированного множителя (защита от раздутого стака бонусов).
	MaxMultiplier: number,
	Species: { [string]: SpeciesDefinition },
}

local STANDARD_SCALE = {
	Common = 0.05,
	Rare = 0.1,
	Epic = 0.2,
	Legendary = 0.35,
	Secret = 0.6,
}

local PetSpeciesConfig: PetSpeciesDefinition = {
	EmotionTypes = { "Joyful", "Nostalgic", "Fearful" },
	Rarities = { "Common", "Rare", "Epic", "Legendary", "Secret" },
	MutationBonusFraction = 0.1,
	MaxMultiplier = 3,
	Species = {
		DozySheep = {
			Id = "DozySheep",
			DisplayName = "Дремлющая овечка",
			EmotionType = "Joyful",
			BonusPerRarity = table.clone(STANDARD_SCALE),
		},
		PillowMoth = {
			Id = "PillowMoth",
			DisplayName = "Подушечная моль",
			EmotionType = "Nostalgic",
			BonusPerRarity = table.clone(STANDARD_SCALE),
		},
		StarJelly = {
			Id = "StarJelly",
			DisplayName = "Звёздная медуза",
			EmotionType = "Joyful",
			BonusPerRarity = table.clone(STANDARD_SCALE),
		},
		CloudFox = {
			Id = "CloudFox",
			DisplayName = "Облачный лис",
			EmotionType = "Fearful",
			BonusPerRarity = table.clone(STANDARD_SCALE),
		},
		DreamWhale = {
			Id = "DreamWhale",
			DisplayName = "Кит сновидений",
			EmotionType = "Nostalgic",
			BonusPerRarity = table.clone(STANDARD_SCALE),
		},
		MoonOwl = {
			Id = "MoonOwl",
			DisplayName = "Лунная сова",
			EmotionType = "Joyful",
			BonusPerRarity = table.clone(STANDARD_SCALE),
		},
	},
}

-- Проверки при загрузке: битый конфиг бонусов должен ронять старт, а не тихо давать
-- NaN-множитель конвейеру или радиусу.
local isFinite = UpgradeEffects.IsFinite

do
	local seen: { [string]: true } = {}
	for _, emotion in PetSpeciesConfig.EmotionTypes do
		assert(not seen[emotion], `PetSpeciesConfig: эмоция {emotion} повторяется`)
		seen[emotion] = true
	end
	for _, required in { "Joyful", "Nostalgic", "Fearful" } do
		assert(seen[required], `PetSpeciesConfig: нет эмоции {required}`)
	end
end

do
	local seen: { [string]: true } = {}
	for _, rarity in PetSpeciesConfig.Rarities do
		assert(type(rarity) == "string" and rarity ~= "", "PetSpeciesConfig: пустая редкость")
		assert(not seen[rarity], `PetSpeciesConfig: редкость {rarity} повторяется`)
		seen[rarity] = true
	end
end

assert(
	isFinite(PetSpeciesConfig.MutationBonusFraction) and PetSpeciesConfig.MutationBonusFraction > 0,
	"PetSpeciesConfig: некорректный MutationBonusFraction"
)
assert(
	isFinite(PetSpeciesConfig.MaxMultiplier) and PetSpeciesConfig.MaxMultiplier > 1,
	"PetSpeciesConfig: некорректный MaxMultiplier"
)

for key, species in PetSpeciesConfig.Species do
	assert(species.Id == key, `PetSpeciesConfig: ключ {key} не совпадает с Id {species.Id}`)
	assert(
		table.find(PetSpeciesConfig.EmotionTypes, species.EmotionType) ~= nil,
		`PetSpeciesConfig: у {key} неизвестная эмоция {species.EmotionType}`
	)

	local count = 0
	for _ in species.BonusPerRarity do
		count += 1
	end
	assert(
		count == #PetSpeciesConfig.Rarities,
		`PetSpeciesConfig: у {key} бонусы заданы не ровно для редкостей из Rarities`
	)

	local previous = 0
	for _, rarity in PetSpeciesConfig.Rarities do
		local bonus = species.BonusPerRarity[rarity]
		assert(isFinite(bonus) and bonus > 0, `PetSpeciesConfig: у {key}/{rarity} некорректный бонус {bonus}`)
		assert(bonus > previous, `PetSpeciesConfig: у {key} бонус {rarity} не больше младшей редкости`)
		previous = bonus
	end
end

return PetSpeciesConfig
