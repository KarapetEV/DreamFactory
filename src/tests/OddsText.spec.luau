--[[
	Тесты публикуемого текста шансов (S12, раздел 5.7 ТЗ): текст строится из PetRarityConfig —
	единственного источника правды — и пересчитывается при изменении весов.
	Запуск: lune run src/tests/run (из корня репозитория).
]]

local Harness = require("./lib/Harness")

type Test = { Name: string, Run: () -> () }

local tests: { Test } = {}

local function test(name: string, run: () -> ())
	table.insert(tests, { Name = name, Run = run })
end

local function expectEqual(actual: any, expected: any, label: string?)
	assert(actual == expected, `{label or "значение"}: ожидалось «{tostring(expected)}», получено «{tostring(actual)}»`)
end

-- MonetizationSystem с подменённой таблицей шансов (остальные зависимости — заглушки).
local function loadMonetization(world, rarityConfig: any?)
	local overrides: { [string]: any } = {
		["src/server/Systems/DataSystem"] = {},
		["src/server/Systems/FactorySystem"] = {},
		["src/server/Systems/PetSystem"] = {},
	}
	if rarityConfig then
		overrides["src/server/Config/PetRarityConfig"] = rarityConfig
	end
	return world:LoadModule("src/server/Systems/MonetizationSystem", overrides)
end

test("FormatPercent: целые, дробные, мелкие шансы", function()
	local world = Harness.NewWorld()
	local OddsText = world:LoadModule("src/shared/OddsText")
	expectEqual(OddsText.FormatPercent(1), "100%")
	expectEqual(OddsText.FormatPercent(0.7), "70%")
	expectEqual(OddsText.FormatPercent(0.07), "7%")
	expectEqual(OddsText.FormatPercent(0.015), "1,5%")
	expectEqual(OddsText.FormatPercent(0.00123), "0,12%")
	expectEqual(OddsText.FormatPercent(0.0001), "0,01%")
	expectEqual(OddsText.FormatPercent(0.00001), "<0,01%", "не округляется в 0%")
	for _, bad in { 0, -0.1, 1.5, 0 / 0, math.huge } do
		assert(not pcall(OddsText.FormatPercent, bad), `шанс {bad} отвергнут`)
	end
end)

test("Format: порядок как в таблице, названия редкостей, без названия — ошибка", function()
	local world = Harness.NewWorld()
	local OddsText = world:LoadModule("src/shared/OddsText")
	local names = { Common = "Обычный", Rare = "Редкий", Epic = "Эпический" }
	local text = OddsText.Format({
		{ Rarity = "Common", Chance = 0.6 },
		{ Rarity = "Rare", Chance = 0.25 },
		{ Rarity = "Epic", Chance = 0.15 },
	}, names)
	expectEqual(text, "Обычный — 60%, Редкий — 25%, Эпический — 15%")
	assert(not pcall(OddsText.Format, { { Rarity = "Secret", Chance = 1 } }, names), "сырой Id в UI не попадает")
	assert(not pcall(OddsText.Format, {}, names), "пустая таблица отвергнута")
end)

test("текст кокона из реального PetRarityConfig", function()
	local world = Harness.NewWorld()
	local monetization = loadMonetization(world)
	expectEqual(monetization.GetCocoonOddsText("DrowsyCocoon"), "Обычный — 70%, Редкий — 25%, Легендарный — 5%")
	expectEqual(
		monetization.GetCocoonOddsText("LucidCocoon"),
		"Обычный — 40%, Редкий — 40%, Эпический — 15%, Легендарный — 5%"
	)
	expectEqual(monetization.GetCocoonOddsText("NoSuchCocoon"), nil)
end)

test("текст пересчитывается при изменении весов в PetRarityConfig", function()
	local world = Harness.NewWorld()
	local rarity = Harness.DeepCopy(world:LoadModule("src/server/Config/PetRarityConfig"))
	local drowsy = rarity.Cocoons.DrowsyCocoon
	drowsy[1].Chance = 0.6
	drowsy[2].Chance = 0.3
	drowsy[3].Chance = 0.1
	local monetization = loadMonetization(world, rarity)
	expectEqual(monetization.GetCocoonOddsText("DrowsyCocoon"), "Обычный — 60%, Редкий — 30%, Легендарный — 10%")

	-- Новая редкость в таблице — сразу в тексте.
	drowsy[3].Chance = 0.095
	table.insert(drowsy, { Rarity = "Secret", Chance = 0.005, Species = { "MoonOwl" } })
	expectEqual(
		monetization.GetCocoonOddsText("DrowsyCocoon"),
		"Обычный — 60%, Редкий — 30%, Легендарный — 9,5%, Секретный — 0,5%"
	)
end)

test("каждый кокон: проценты в тексте совпадают с Chance ролла 1-в-1", function()
	local world = Harness.NewWorld()
	local rarity = world:LoadModule("src/server/Config/PetRarityConfig")
	local species = world:LoadModule("src/shared/Config/PetSpeciesConfig")
	local monetization = loadMonetization(world)
	for cocoonId, odds in rarity.Cocoons do
		local text = assert(monetization.GetCocoonOddsText(cocoonId))
		local index = 0
		for name, percent in string.gmatch(text, "([^,]+) — ([%d,]+)%%") do
			index += 1
			local entry = odds[index]
			expectEqual((string.gsub(name, "^%s+", "")), species.RarityDisplayNames[entry.Rarity], `{cocoonId}#{index}`)
			local value = tonumber((string.gsub(percent, ",", ".")))
			assert(math.abs(value - entry.Chance * 100) < 0.005, `{cocoonId}/{entry.Rarity}: {percent}% vs {entry.Chance}`)
		end
		expectEqual(index, #odds, `{cocoonId}: все редкости в тексте`)
	end
end)

return tests
