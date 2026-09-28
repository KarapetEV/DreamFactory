--[[
	Тесты таблицы локализации (S19, раздел 10 ТЗ): чистая проверка данных без Roblox.
	- каждый ключ, который используют UI-модули, есть в Loc.Strings с непустыми ru и en;
	- в таблицах TEXT UI-модулей не осталось строковых литералов (только Loc.Get);
	- плейсхолдеры формата в ru и en совпадают (string.format на местах вызова не меняется);
	- Loc.Get с неизвестным ключом/языком не бросает и возвращает ключ, warn — один раз;
	- дублирующихся ключей в исходнике Loc.luau нет (в литерале таблицы дубль молча затёр бы строку).
	Запуск: lune run src/tests/run (из корня репозитория).
]]

local fs = require("@lune/fs")

local Harness = require("./lib/Harness")

type Test = { Name: string, Run: () -> () }

local tests: { Test } = {}

local function test(name: string, run: () -> ())
	table.insert(tests, { Name = name, Run = run })
end

local UI_MODULES = { "HUD", "ShopUI", "PetInventoryUI", "ChaosEventUI" }
local LOC_PATH = "src/shared/Loc"

local function uiSource(name: string): string
	return fs.readFile(`src/client/UI/{name}.luau`)
end

-- Тело «local TEXT = { ... }» модуля.
local function textTable(source: string): string
	local body = string.match(source, "\nlocal TEXT = {\n(.-)\n}\n")
	return assert(body, "в модуле нет таблицы TEXT")
end

local function placeholders(text: string): string
	local list = {}
	for spec in string.gmatch(text, "%%[%d%.]*%a") do
		table.insert(list, spec)
	end
	return table.concat(list, ",")
end

test("Все ключи Loc.Get из 4 UI-модулей есть в Loc.Strings с непустыми ru и en", function()
	local loc = Harness.NewWorld():LoadModule(LOC_PATH)
	local total = 0
	for _, name in UI_MODULES do
		local source = uiSource(name)
		local count = 0
		for key in string.gmatch(source, 'Loc%.Get%("([^"]+)"%)') do
			count += 1
			local entry = loc.Strings[key]
			assert(entry, `{name}: ключа {key} нет в Loc.Strings`)
			assert(type(entry.ru) == "string" and entry.ru ~= "", `{key}: пустой ru`)
			assert(type(entry.en) == "string" and entry.en ~= "", `{key}: пустой en`)
			assert(string.sub(key, 1, #name + 1) == name .. ".", `{key}: ключ не из пространства {name}`)
		end
		assert(count > 0, `{name}: Loc.Get не используется`)
		total += count
	end
	local defined = 0
	for _ in loc.Strings do
		defined += 1
	end
	assert(total == defined, `в Loc.Strings {defined} ключей, UI использует {total}: лишние или неиспользуемые строки`)
end)

test("В таблицах TEXT UI-модулей не осталось захардкоженных строк", function()
	for _, name in UI_MODULES do
		for line in string.gmatch(textTable(uiSource(name)), "[^\n]+") do
			local field, key = string.match(line, '^\t(%w+) = Loc%.Get%("([^"]+)"%),$')
			assert(field, `{name}: строка TEXT не через Loc.Get: {line}`)
			assert(key == `{name}.{field}`, `{name}.{field}: ключ {key} не совпадает с полем`)
		end
	end
end)

test("Плейсхолдеры формата в ru и en совпадают", function()
	local loc = Harness.NewWorld():LoadModule(LOC_PATH)
	for key, entry in loc.Strings do
		assert(placeholders(entry.ru) == placeholders(entry.en), `{key}: «{entry.ru}» vs «{entry.en}»`)
	end
end)

test("Нет дублирующихся ключей в исходнике Loc.luau", function()
	local seen = {}
	local count = 0
	for key in string.gmatch(fs.readFile(LOC_PATH .. ".luau"), '\n\t%["([^"]+)"%] = {') do
		assert(not seen[key], `ключ {key} повторяется`)
		seen[key] = true
		count += 1
	end
	assert(count > 0, "ключи не найдены — формат исходника изменился, тест устарел")
end)

test("Loc.Get: язык по умолчанию ru, явный en; неизвестный ключ/язык не бросает и возвращает ключ", function()
	local world = Harness.NewWorld()
	local loc = world:LoadModule(LOC_PATH)
	assert(loc.DefaultLocale == "ru")
	assert(loc.Get("HUD.RebirthButton") == "Перерождение")
	assert(loc.Get("HUD.RebirthButton", "en") == "Rebirth")

	for _ = 1, 3 do
		assert(loc.Get("HUD.NoSuchKey") == "HUD.NoSuchKey")
	end
	assert(loc.Get("HUD.RebirthButton", "de" :: any) == "HUD.RebirthButton", "нет языка — ключ")
	assert(#world.Warnings == 2, `warn один раз на ключ, получено {#world.Warnings}`)
end)

return tests
