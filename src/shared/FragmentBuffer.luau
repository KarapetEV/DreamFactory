--!strict

--[[
	Буфер сырых фрагментов по эмоциям (Factory.RawFragments, Types.FragmentBuffer). Чистые
	функции без Instance — общие для CollectionSystem (наполнение), FactorySystem (переработка,
	снимок для HUD) и RebirthSystem (сброс).

	Ёмкость склада ограничивает СУММУ по типам. Порядок типов — PetSpeciesConfig.EmotionTypes.
]]

local Types = require(script.Parent.Types)
local UpgradeEffects = require(script.Parent.UpgradeEffects)
local PetSpeciesConfig = require(script.Parent.Config.PetSpeciesConfig)

type FragmentBuffer = Types.FragmentBuffer

local isFinite = UpgradeEffects.IsFinite

local FragmentBuffer = {}

-- Пустой буфер: 0 для каждой эмоции.
function FragmentBuffer.Empty(): FragmentBuffer
	local buffer: any = {}
	for _, emotion in PetSpeciesConfig.EmotionTypes do
		buffer[emotion] = 0
	end
	return buffer
end

-- Сумма по всем эмоциям. nil — буфер повреждён (не таблица или значение какой-то эмоции
-- не конечное неотрицательное число): такой буфер нельзя ни пополнять, ни перерабатывать.
function FragmentBuffer.Total(buffer: unknown): number?
	if type(buffer) ~= "table" then
		return nil
	end
	local total = 0
	for _, emotion in PetSpeciesConfig.EmotionTypes do
		local value = (buffer :: any)[emotion]
		if not isFinite(value) or value < 0 then
			return nil
		end
		total += value
	end
	return total
end

-- Копия буфера только из известных эмоций (лишние поля не утекают). nil — буфер повреждён
-- (те же правила, что у Total).
function FragmentBuffer.Copy(buffer: unknown): FragmentBuffer?
	if FragmentBuffer.Total(buffer) == nil then
		return nil
	end
	local copy: any = {}
	for _, emotion in PetSpeciesConfig.EmotionTypes do
		copy[emotion] = (buffer :: any)[emotion]
	end
	return copy
end

return FragmentBuffer
