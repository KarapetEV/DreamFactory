--!strict

--[[
	Сезонный пропуск (раздел 7.3 GDD). Не секрет — лежит в shared: будущему UI пропуска нужны
	пороги тиров и списки наград. Логика — BattlePassSystem; XP, тиры и выдачу наград считает
	только сервер по этой таблице.

	Прогресс игрока (Monetization в профиле): BattlePassSeasonId, BattlePassTier, BattlePassXP,
	BattlePassPremium. Ротация сезона = новый SeasonId в этом файле + старый SeasonId в
	PastSeasonIds. Сезон профиля nil или из PastSeasonIds → прогресс сбрасывается при первом
	начислении XP. Сезон профиля, которого здесь нет вовсе, — более НОВЫЙ сезон (профиль побывал
	на сервере новой версии во время поэтапного деплоя): такой прогресс сервер не трогает, иначе
	старый сервер «откатил» бы сезон и стёр оплаченный премиум.

	Тиры: TierThresholds[i] — XP для перехода с тира i − 1 на тир i (тир 0 — стартовый, без
	награды). XP копится внутри тира и вычитается при переходе; на MaxTier XP больше не копится.
	За достижение тира i выдаются FreeRewards[i] и, при купленной премиум-ветке, PremiumRewards[i].
	Премиум, купленный позже, ретроактивно выдаёт PremiumRewards всех уже пройденных тиров.

	XP — фиксированное число за событие-источник (не за сумму Essence: иначе Rebirth-множитель
	перекашивал бы прогресс так же, как шкалу Хаоса — см. ChaosBossConfig).

	Каркас: заглушечные значения. Реальный баланс считает economy-balancer.
]]

local UpgradeEffects = require(script.Parent.Parent.UpgradeEffects)
local PetSpeciesConfig = require(script.Parent.PetSpeciesConfig)

export type FreeReward = {
	Essence: number, -- ≥ 0; 0 — тир без валюты
	Decor: string?, -- id косметики фабрики (Factory.Decor)
}

export type PremiumReward = {
	Essence: number,
	Decor: string?,
	-- Эксклюзивный пет сезона (вид из PetSpeciesConfig, редкость — PremiumPetRarity).
	PetSpeciesId: string?,
}

export type BattlePassDefinition = {
	SeasonId: string,
	-- Все прошлые SeasonId (ротация только вперёд). Пополнять при каждой смене сезона.
	PastSeasonIds: { string },
	MaxTier: number,
	TierThresholds: { number }, -- длина = MaxTier
	XPPerFactoryCycle: number, -- за событие FactorySystem.OnEssenceProduced
	XPPerRebirth: number,
	XPPerChaosHit: number, -- за засчитанный удар по Хаос-боссу
	XPPerRaid: number, -- атакующему за успешный рейд
	XPPerHatch: number,
	FreeRewards: { [number]: FreeReward }, -- ключи 1..MaxTier
	PremiumRewards: { [number]: PremiumReward }, -- ключи 1..MaxTier
	-- Редкость пета из PremiumRewards (должна быть в PetSpeciesConfig.Rarities).
	PremiumPetRarity: string,
}

local BattlePassConfig: BattlePassDefinition = {
	SeasonId = "S1",
	PastSeasonIds = {},
	MaxTier = 10,
	TierThresholds = { 100, 150, 200, 250, 300, 350, 400, 450, 500, 600 },

	XPPerFactoryCycle = 1,
	XPPerRebirth = 150,
	XPPerChaosHit = 2,
	XPPerRaid = 25,
	XPPerHatch = 10,

	FreeRewards = {
		[1] = { Essence = 200 },
		[2] = { Essence = 300 },
		[3] = { Essence = 400, Decor = "SeasonLantern" },
		[4] = { Essence = 500 },
		[5] = { Essence = 700 },
		[6] = { Essence = 900 },
		[7] = { Essence = 1_100, Decor = "SeasonBanner" },
		[8] = { Essence = 1_300 },
		[9] = { Essence = 1_500 },
		[10] = { Essence = 2_000 },
	},
	PremiumRewards = {
		[1] = { Essence = 500 },
		[2] = { Essence = 600, Decor = "SeasonPremiumRug" },
		[3] = { Essence = 800 },
		[4] = { Essence = 1_000 },
		[5] = { Essence = 1_200, Decor = "SeasonPremiumClock" },
		[6] = { Essence = 1_500 },
		[7] = { Essence = 1_800 },
		[8] = { Essence = 2_100, Decor = "SeasonPremiumArch" },
		[9] = { Essence = 2_500 },
		-- ЗАГЛУШКА эксклюзивного пета сезона: существующий вид как арт-плейсхолдер,
		-- до появления настоящего сезонного вида.
		[10] = { Essence = 3_000, PetSpeciesId = "MoonOwl" },
	},
	PremiumPetRarity = "Legendary",
}

-- Проверки при загрузке: дыра в наградах или рассинхрон порогов с MaxTier дали бы тир без
-- награды (или падение посреди выдачи) — такой конфиг роняет старт сервера.
do
	local c = BattlePassConfig
	local isFinite = UpgradeEffects.IsFinite

	local function positive(name: string, value: number)
		assert(isFinite(value) and value > 0, `BattlePassConfig: {name} должен быть > 0, получено {value}`)
	end

	assert(type(c.SeasonId) == "string" and c.SeasonId ~= "", "BattlePassConfig: пустой SeasonId")
	local seenSeasons: { [string]: true } = { [c.SeasonId] = true }
	for _, past in c.PastSeasonIds do
		assert(type(past) == "string" and past ~= "", "BattlePassConfig: пустой id в PastSeasonIds")
		assert(not seenSeasons[past], `BattlePassConfig: сезон {past} повторяется (или совпадает с текущим)`)
		seenSeasons[past] = true
	end
	assert(
		isFinite(c.MaxTier) and c.MaxTier >= 1 and c.MaxTier % 1 == 0,
		`BattlePassConfig: некорректный MaxTier {c.MaxTier}`
	)

	local thresholdCount = 0
	for _ in c.TierThresholds do
		thresholdCount += 1
	end
	assert(
		thresholdCount == c.MaxTier and #c.TierThresholds == c.MaxTier,
		`BattlePassConfig: в TierThresholds {thresholdCount} значений, а MaxTier = {c.MaxTier}`
	)
	for tier, threshold in c.TierThresholds do
		positive(`TierThresholds[{tier}]`, threshold)
	end

	positive("XPPerFactoryCycle", c.XPPerFactoryCycle)
	positive("XPPerRebirth", c.XPPerRebirth)
	positive("XPPerChaosHit", c.XPPerChaosHit)
	positive("XPPerRaid", c.XPPerRaid)
	positive("XPPerHatch", c.XPPerHatch)

	assert(
		table.find(PetSpeciesConfig.Rarities, c.PremiumPetRarity) ~= nil,
		`BattlePassConfig: PremiumPetRarity {c.PremiumPetRarity} нет в PetSpeciesConfig.Rarities`
	)

	local function checkRewards(name: string, rewards: { [number]: any }, allowPet: boolean)
		for tier = 1, c.MaxTier do
			local reward = rewards[tier]
			assert(type(reward) == "table", `BattlePassConfig: в {name} нет награды тира {tier}`)
			assert(
				isFinite(reward.Essence) and reward.Essence >= 0,
				`BattlePassConfig: {name}[{tier}].Essence некорректна: {reward.Essence}`
			)
			assert(
				reward.Decor == nil or (type(reward.Decor) == "string" and reward.Decor ~= ""),
				`BattlePassConfig: {name}[{tier}].Decor некорректен`
			)
			local speciesId = reward.PetSpeciesId
			if speciesId ~= nil then
				assert(allowPet, `BattlePassConfig: {name}[{tier}] — пет только в премиум-ветке`)
				assert(
					type(speciesId) == "string" and PetSpeciesConfig.Species[speciesId] ~= nil,
					`BattlePassConfig: {name}[{tier}].PetSpeciesId {speciesId} нет в PetSpeciesConfig`
				)
			end
		end
		for key in rewards do
			assert(
				type(key) == "number" and key % 1 == 0 and key >= 1 and key <= c.MaxTier,
				`BattlePassConfig: в {name} лишний ключ {key} (ожидаются тиры 1..{c.MaxTier})`
			)
		end
	end
	checkRewards("FreeRewards", c.FreeRewards, false)
	checkRewards("PremiumRewards", c.PremiumRewards, true)
end

return BattlePassConfig
