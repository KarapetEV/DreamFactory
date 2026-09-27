--!strict

--[[
	Эмоциональный тип фрагментов снов (GDD раздел 3, ТЗ 5.2/5.5). Enum эмоций — общий с видами
	петов (PetSpeciesConfig.EmotionTypes).

	- SpawnWeights: тип фрагмента при спавне выбирает сервер (CollectionSystem) по этим весам —
	  относительным, нормировать не нужно. Клиент тип не присылает и не выбирает.
	- EssenceModifiers: множитель выхода Essence конвейера (FactorySystem) для фрагмента этого
	  типа — поверх EssencePerFragment × ClarityMultiplier.

	Каркас: заглушечные значения (равные трети; Joyful ×1.1, Nostalgic ×1.0, Fearful ×0.9).
	Реальный баланс считает economy-balancer.
]]

local Types = require(script.Parent.Parent.Types)
local UpgradeEffects = require(script.Parent.Parent.UpgradeEffects)
local PetSpeciesConfig = require(script.Parent.PetSpeciesConfig)

type EmotionType = Types.EmotionType

export type FragmentEmotionDefinition = {
	-- Ключи — ровно PetSpeciesConfig.EmotionTypes.
	SpawnWeights: { [EmotionType]: number },
	EssenceModifiers: { [EmotionType]: number },
}

local FragmentEmotionConfig: FragmentEmotionDefinition = {
	SpawnWeights = {
		Joyful = 1,
		Nostalgic = 1,
		Fearful = 1,
	},
	EssenceModifiers = {
		Joyful = 1.1,
		Nostalgic = 1.0,
		Fearful = 0.9,
	},
}

-- Проверки при загрузке: тип без веса никогда не выпадет, тип без модификатора уронит
-- конвейер — такой конфиг должен ронять старт сервера.
do
	local isFinite = UpgradeEffects.IsFinite
	local emotions = PetSpeciesConfig.EmotionTypes

	local function checkKeys(tableName: string, values: { [string]: number })
		for key in values do
			assert(
				table.find(emotions, key :: any) ~= nil,
				`FragmentEmotionConfig: {tableName}.{key} — нет такой эмоции в PetSpeciesConfig.EmotionTypes`
			)
		end
	end
	checkKeys("SpawnWeights", FragmentEmotionConfig.SpawnWeights :: any)
	checkKeys("EssenceModifiers", FragmentEmotionConfig.EssenceModifiers :: any)

	local weightSum = 0
	for _, emotion in emotions do
		local weight = FragmentEmotionConfig.SpawnWeights[emotion]
		assert(
			isFinite(weight) and weight >= 0,
			`FragmentEmotionConfig: некорректный SpawnWeights.{emotion} {weight}`
		)
		weightSum += weight
		local modifier = FragmentEmotionConfig.EssenceModifiers[emotion]
		assert(
			isFinite(modifier) and modifier > 0,
			`FragmentEmotionConfig: некорректный EssenceModifiers.{emotion} {modifier}`
		)
	end
	assert(weightSum > 0, "FragmentEmotionConfig: сумма SpawnWeights должна быть больше 0")
end

return FragmentEmotionConfig
