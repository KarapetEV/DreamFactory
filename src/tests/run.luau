--[[
	Раннер юнит-тестов вне Roblox Studio (lune). Запуск из корня репозитория:
		lune run src/tests/run

	Находит все src/tests/*.spec.luau; каждый spec возвращает массив { Name, Run }.
	Код выхода 1, если упал хотя бы один тест — пригодно для CI.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local serde = require("@lune/serde")

local Harness = require("./lib/Harness")

Harness.Configure({
	ReadFile = function(path: string): string
		return fs.readFile(path)
	end,
	Load = function(source: string, chunkName: string, env: { [string]: any })
		return luau.load(source, { debugName = chunkName, environment = env })
	end,
	JsonEncode = function(value: any): string
		return serde.encode("json", value)
	end,
	JsonDecode = function(text: string): any
		return serde.decode("json", text)
	end,
})

local TESTS_DIR = "src/tests"

local specNames = {}
for _, name in fs.readDir(TESTS_DIR) do
	local specName = string.match(name, "^(.+)%.spec%.luau$")
	if specName then
		table.insert(specNames, specName)
	end
end
table.sort(specNames)

local passed, failed = 0, 0

for _, specName in specNames do
	print(`\n{specName}`)
	local tests = require(`./{specName}.spec`)
	for _, case in tests do
		local ok, err = pcall(case.Run)
		if ok then
			passed += 1
			print(`  PASS  {case.Name}`)
		else
			failed += 1
			print(`  FAIL  {case.Name}\n        {err}`)
		end
	end
end

print(`\n{passed} passed, {failed} failed`)
process.exit(if failed > 0 then 1 else 0)
