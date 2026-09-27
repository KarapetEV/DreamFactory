--!strict

--[[
	Текст публикуемых шансов выпадения (раздел 5.7 ТЗ, раздел 12 GDD: Roblox требует показывать
	odds рандомизированных покупок). Чистая функция без обращений к Instance и конфигам: таблицу
	шансов ей передаёт сервер — PetRarityConfig.Cocoons[cocoonId], та же, по которой идёт ролл
	(PetSystem.RollPet). Поэтому цифры в UI не могут разойтись с логикой: вручную набранного
	текста шансов в проекте нет, правка весов в конфиге сразу меняет текст.

	Формат: «Обычный — 70%, Редкий — 25%, Легендарный — 5%» — порядок как в таблице шансов,
	проценты до сотых без хвостовых нулей, десятичная запятая. Шанс меньше 0,005% не
	округляется в «0%» (это читалось бы как «не выпадает»), а пишется «<0,01%».
]]

export type OddsEntry = {
	Rarity: string,
	Chance: number, -- доля в (0, 1]
}

local OddsText = {}

local function isFinite(value: unknown): boolean
	return type(value) == "number" and value == value and math.abs(value) ~= math.huge
end

-- 0.7 -> "70%", 0.015 -> "1,5%", 0.00123 -> "0,12%", 0.00001 -> "<0,01%".
function OddsText.FormatPercent(chance: number): string
	assert(isFinite(chance) and chance > 0 and chance <= 1, `OddsText: некорректный шанс {chance}`)
	local hundredths = math.floor(chance * 10_000 + 0.5)
	if hundredths == 0 then
		return "<0,01%"
	end
	local text = string.format("%.2f", hundredths / 100)
	text = string.gsub(text, "0+$", "")
	text = string.gsub(text, "%.$", "")
	text = string.gsub(text, "%.", ",")
	return text .. "%"
end

-- Строка шансов по таблице odds. displayNames — название для каждой редкости
-- (PetSpeciesConfig.RarityDisplayNames); редкость без названия — ошибка, а не сырой Id в UI.
function OddsText.Format(odds: { OddsEntry }, displayNames: { [string]: string }): string
	assert(#odds > 0, "OddsText: пустая таблица шансов")
	local parts = table.create(#odds)
	for _, entry in odds do
		local name = displayNames[entry.Rarity]
		assert(type(name) == "string" and name ~= "", `OddsText: нет названия для редкости {entry.Rarity}`)
		table.insert(parts, `{name} — {OddsText.FormatPercent(entry.Chance)}`)
	end
	return table.concat(parts, ", ")
end

return OddsText
