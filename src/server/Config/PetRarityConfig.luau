--!strict

--[[
	Шансы вылупления петов (раздел 5.3 ТЗ). SERVER-ONLY: лежит в ServerScriptService,
	клиент не может ни прочитать, ни подменить таблицу. Единственный источник правды для
	ролла PetSystem.HatchCocoon; текст odds для UI (раздел 5.7) сервер будет генерировать
	из этой же таблицы (сессия монетизации), а не дублировать цифры на клиенте.

	Ролл пета — два независимых броска:
	1. редкость по Cocoons[cocoonId] (Chance по всем редкостям кокона в сумме = 1),
	   затем равновероятный вид из Species выпавшей редкости;
	2. мутация — отдельный бросок поверх редкости с вероятностью Mutation.Chance,
	   тип мутации — по весам Mutation.Types. Шанс мутации от редкости не зависит.

	Каркас: заглушечные значения. Реальный баланс считает economy-balancer.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CocoonConfig = require(ReplicatedStorage.shared.Config.CocoonConfig)
local PetSpeciesConfig = require(ReplicatedStorage.shared.Config.PetSpeciesConfig)
local UpgradeEffects = require(ReplicatedStorage.shared.UpgradeEffects)

export type RarityOdds = {
	Rarity: string,
	Chance: number, -- доля в (0, 1]; по всем редкостям одного кокона сумма = 1
	Species: { string }, -- виды этой редкости; выбирается равновероятно
}

export type MutationType = {
	Id: string,
	Weight: number, -- относительный вес среди мутаций (нормировать не нужно)
}

export type PetRarityDefinition = {
	-- Порядок редкостей в массиве фиксирован — ролл детерминирован для данного случайного числа.
	Cocoons: { [string]: { RarityOdds } },
	Mutation: {
		Chance: number, -- вероятность, что у вылупившегося пета есть мутация, в (0, 1)
		Types: { MutationType },
	},
}

local PetRarityConfig: PetRarityDefinition = {
	Cocoons = {
		DrowsyCocoon = {
			{ Rarity = "Common", Chance = 0.7, Species = { "DozySheep", "PillowMoth" } },
			{ Rarity = "Rare", Chance = 0.25, Species = { "StarJelly" } },
			{ Rarity = "Legendary", Chance = 0.05, Species = { "MoonOwl" } },
		},
		LucidCocoon = {
			{ Rarity = "Common", Chance = 0.4, Species = { "PillowMoth" } },
			{ Rarity = "Rare", Chance = 0.4, Species = { "StarJelly", "CloudFox" } },
			{ Rarity = "Epic", Chance = 0.15, Species = { "DreamWhale" } },
			{ Rarity = "Legendary", Chance = 0.05, Species = { "MoonOwl" } },
		},
	},
	Mutation = {
		Chance = 0.02,
		Types = {
			{ Id = "Shiny", Weight = 3 },
			{ Id = "Nightmare", Weight = 1 },
		},
	},
}

-- Проверки при загрузке: битая таблица шансов должна ронять сервер при старте, а не
-- тихо искажать ролл (например, NaN-шанс, при котором редкость не выпадает никогда).
local isFinite = UpgradeEffects.IsFinite
local SUM_TOLERANCE = 1e-9

for cocoonId in CocoonConfig do
	assert(PetRarityConfig.Cocoons[cocoonId], `PetRarityConfig: нет шансов для кокона {cocoonId} из CocoonConfig`)
end

for cocoonId, odds in PetRarityConfig.Cocoons do
	assert(CocoonConfig[cocoonId], `PetRarityConfig: кокон {cocoonId} отсутствует в CocoonConfig`)
	assert(#odds > 0, `PetRarityConfig: у {cocoonId} пустая таблица шансов`)

	local seen: { [string]: true } = {}
	local sum = 0
	for _, entry in odds do
		assert(type(entry.Rarity) == "string" and entry.Rarity ~= "", `PetRarityConfig: у {cocoonId} редкость без Id`)
		assert(not seen[entry.Rarity], `PetRarityConfig: у {cocoonId} редкость {entry.Rarity} повторяется`)
		assert(
			table.find(PetSpeciesConfig.Rarities, entry.Rarity) ~= nil,
			`PetRarityConfig: у {cocoonId} редкость {entry.Rarity} отсутствует в PetSpeciesConfig.Rarities`
		)
		seen[entry.Rarity] = true
		assert(
			isFinite(entry.Chance) and entry.Chance > 0 and entry.Chance <= 1,
			`PetRarityConfig: у {cocoonId}/{entry.Rarity} некорректный Chance {entry.Chance}`
		)
		assert(#entry.Species > 0, `PetRarityConfig: у {cocoonId}/{entry.Rarity} нет видов`)
		for _, species in entry.Species do
			assert(type(species) == "string" and species ~= "", `PetRarityConfig: у {cocoonId}/{entry.Rarity} пустой вид`)
			-- Каждый вид, который может выпасть, обязан иметь эмоцию и бонус (PetSystem.GetAggregatedBonuses).
			assert(
				PetSpeciesConfig.Species[species],
				`PetRarityConfig: вид {species} ({cocoonId}) отсутствует в PetSpeciesConfig`
			)
		end
		sum += entry.Chance
	end
	assert(math.abs(sum - 1) <= SUM_TOLERANCE, `PetRarityConfig: у {cocoonId} сумма шансов {sum}, а должна быть 1`)
end

do
	local mutation = PetRarityConfig.Mutation
	assert(
		isFinite(mutation.Chance) and mutation.Chance > 0 and mutation.Chance < 1,
		`PetRarityConfig: некорректный Mutation.Chance {mutation.Chance}`
	)
	assert(#mutation.Types > 0, "PetRarityConfig: нет типов мутаций")
	local seen: { [string]: true } = {}
	for _, mutationType in mutation.Types do
		assert(type(mutationType.Id) == "string" and mutationType.Id ~= "", "PetRarityConfig: мутация без Id")
		assert(not seen[mutationType.Id], `PetRarityConfig: мутация {mutationType.Id} повторяется`)
		seen[mutationType.Id] = true
		assert(
			isFinite(mutationType.Weight) and mutationType.Weight > 0,
			`PetRarityConfig: у мутации {mutationType.Id} некорректный вес {mutationType.Weight}`
		)
	end
end

return PetRarityConfig
