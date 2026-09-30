--!strict

--[[
	Компактная строка «какие петы надеты» для атрибута игрока Attributes.EquippedPets.
	Её пишет сервер (PetSystem, при пересчёте бонусов), а клиенты всех игроков рисуют по ней
	моделей петов, следующих за владельцем. Только отображение: бонусы сервер считает из профиля.

	Формат: записи через ";", поля записи через ":" — SpeciesId:Rarity:M, где M = 1 у
	мутировавшего пета, иначе 0. Порядок — порядок инвентаря, не больше slots записей
	(те же петы, что дают бонус в PetSystem.GetAggregatedBonuses).
	Неизвестные виды/редкости пропускаются и при кодировании, и при разборе: битая запись в
	профиле или подделанный атрибут не роняют рендер.
]]

local Types = require(script.Parent.Types)
local PetSpeciesConfig = require(script.Parent.Config.PetSpeciesConfig)

export type EquippedPet = {
	SpeciesId: string,
	Rarity: string,
	Mutated: boolean,
}

-- Потолок разбираемых записей: подделанная длинная строка не заставит клиент строить сотни моделей.
local MAX_DECODED = 12

local EquippedPetsCodec = {}

EquippedPetsCodec.MaxDecoded = MAX_DECODED

local function isKnown(speciesId: unknown, rarity: unknown): boolean
	return type(speciesId) == "string"
		and PetSpeciesConfig.Species[speciesId] ~= nil
		and type(rarity) == "string"
		and PetSpeciesConfig.RarityDisplayNames[rarity] ~= nil
end

function EquippedPetsCodec.Encode(pets: { Types.PetRecord }, slots: number): string
	local entries: { string } = {}
	if type(pets) ~= "table" or type(slots) ~= "number" then
		return ""
	end
	for _, pet in pets do
		if #entries >= slots then
			break
		end
		if type(pet) == "table" and pet.Equipped == true and isKnown(pet.SpeciesId, pet.Rarity) then
			local mutated = if type(pet.Mutation) == "string" and pet.Mutation ~= "" then "1" else "0"
			table.insert(entries, `{pet.SpeciesId}:{pet.Rarity}:{mutated}`)
		end
	end
	return table.concat(entries, ";")
end

function EquippedPetsCodec.Decode(value: unknown): { EquippedPet }
	local result: { EquippedPet } = {}
	if type(value) ~= "string" then
		return result
	end
	for entry in string.gmatch(value, "[^;]+") do
		if #result >= MAX_DECODED then
			break
		end
		local speciesId, rarity, mutated = string.match(entry, "^([%w_]+):([%w_]+):([01])$")
		if speciesId and isKnown(speciesId, rarity) then
			table.insert(result, {
				SpeciesId = speciesId,
				Rarity = rarity :: string,
				Mutated = mutated == "1",
			})
		end
	end
	return result
end

return EquippedPetsCodec
