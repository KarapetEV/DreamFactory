--!strict

--[[
	BeltLoad — какие фрагменты показать на ленте фабрики: по разбивке буфера сервера
	(EconomySnapshot.RawFragmentsByEmotion) и числу мест на ленте. Чистая функция (lune-тесты).

	- Влезает весь буфер — на ленте ровно его содержимое (3 Joyful + 1 Fearful → 3 жёлтых и
	  1 фиолетовый).
	- Не влезает — места делятся пропорционально (метод наибольших остатков), но каждая эмоция,
	  которая есть в буфере, получает хотя бы одно место, пока мест хватает.
	- Порядок — PetSpeciesConfig.EmotionTypes: в нём же конвейер разбирает буфер (сначала все
	  Joyful), а не в порядке сбора.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.shared.Types)
local PetSpeciesConfig = require(ReplicatedStorage.shared.Config.PetSpeciesConfig)

type EmotionType = Types.EmotionType

local BeltLoad = {}

local function count(value: unknown): number
	if type(value) ~= "number" or value ~= value or value == math.huge or value <= 0 then
		return 0
	end
	return math.floor(value)
end

function BeltLoad.Allocate(byEmotion: unknown, slots: number): { EmotionType }
	local emotions = PetSpeciesConfig.EmotionTypes
	local counts: { number } = {}
	local total = 0
	for index, emotion in emotions do
		counts[index] = if type(byEmotion) == "table" then count((byEmotion :: any)[emotion]) else 0
		total += counts[index]
	end

	local places: { number } = table.create(#emotions, 0)
	if total <= slots then
		places = counts
	elseif slots > 0 then
		-- Пропорционально: целые части, затем остаток — по убыванию дробных частей.
		local remainders: { { Index: number, Fraction: number } } = {}
		local used = 0
		for index, value in counts do
			local exact = value * slots / total
			places[index] = math.floor(exact)
			used += places[index]
			table.insert(remainders, { Index = index, Fraction = exact - places[index] })
		end
		table.sort(remainders, function(a, b)
			return a.Fraction > b.Fraction
		end)
		for i = 1, slots - used do
			local index = remainders[i].Index
			places[index] += 1
		end
		-- Эмоция из буфера не пропадает с ленты: место забирается у самой многочисленной.
		for index, value in counts do
			if value > 0 and places[index] == 0 then
				local largest = 1
				for other = 2, #places do
					if places[other] > places[largest] then
						largest = other
					end
				end
				if places[largest] > 1 then
					places[largest] -= 1
					places[index] = 1
				end
			end
		end
	end

	local result: { EmotionType } = {}
	for index, emotion in emotions do
		for _ = 1, places[index] do
			table.insert(result, emotion)
		end
	end
	return result
end

return BeltLoad
