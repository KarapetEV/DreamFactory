--[[
	Тесты иконок временных баффов (чистый BuffTimer, конфиг VisualConfig.BuffIcons): видимость
	по сроку из атрибута, серое заливает иконку сверху вниз по мере истечения, продление покупкой
	возвращает иконку в цвет, вход посреди баффа, битые значения; у каждого баффа есть иконка.

	Запуск: lune run src/tests/run (из корня репозитория).
]]

local Harness = require("./lib/Harness")

type Test = { Name: string, Run: () -> () }

local tests: { Test } = {}

local function test(name: string, run: () -> ())
	table.insert(tests, { Name = name, Run = run })
end

local function load(path: string): any
	return Harness.NewWorld():LoadModule(path)
end

local BUFF_TIMER = "src/client/UI/BuffTimer"
local DURATION = 20
local T0 = 1_000_000

local function near(a: number, b: number): boolean
	return math.abs(a - b) < 1e-9
end

test("BuffTimer: купленный бафф — цветная иконка, серое растёт сверху вниз, по истечении скрыта", function()
	local bt = load(BUFF_TIMER)
	local timer = bt.new()
	local expiresAt = T0 + DURATION

	local s = bt.Update(timer, expiresAt, T0, DURATION)
	assert(s.Visible and s.SecondsLeft == 20 and near(s.Grey, 0), "сразу после покупки — целиком цветная")

	s = bt.Update(timer, expiresAt, T0 + 5, DURATION)
	assert(near(s.Grey, 0.25) and s.SecondsLeft == 15, `четверть срока — четверть серая, {s.Grey}`)

	s = bt.Update(timer, expiresAt, T0 + 15.5, DURATION)
	assert(near(s.Grey, 15.5 / 20) and s.SecondsLeft == 5, "остаток округляется вверх")

	local previous = -1
	for i = 0, 19 do
		s = bt.Update(timer, expiresAt, T0 + i, DURATION)
		assert(s.Grey >= previous, "серое только растёт")
		previous = s.Grey
	end

	s = bt.Update(timer, expiresAt, T0 + 20, DURATION)
	assert(not s.Visible, "истёк — скрыта")
end)

test("BuffTimer: продление покупкой — иконка снова цветная, шкала от нового остатка", function()
	local bt = load(BUFF_TIMER)
	local timer = bt.new()
	bt.Update(timer, T0 + 20, T0, DURATION)
	local s = bt.Update(timer, T0 + 20, T0 + 10, DURATION)
	assert(near(s.Grey, 0.5))

	-- Докупили: сервер продлил до max(срок, now) + 20 = T0 + 40.
	s = bt.Update(timer, T0 + 40, T0 + 10, DURATION)
	assert(near(s.Grey, 0) and s.SecondsLeft == 30, "после продления — целиком цветная, 30 с")
	s = bt.Update(timer, T0 + 40, T0 + 25, DURATION)
	assert(near(s.Grey, 0.5), `половина новой шкалы (30 с) — половина серая, {s.Grey}`)
end)

test("BuffTimer: вход посреди баффа — серое сразу показывает прошедшее от базовой длительности", function()
	local bt = load(BUFF_TIMER)
	local s = bt.Update(bt.new(), T0 + 5, T0, DURATION)
	assert(s.Visible and near(s.Grey, 0.75), `осталось 5 из 20 — три четверти серые, {s.Grey}`)
end)

test("BuffTimer: нет атрибута, мусор, NaN, inf, прошлое — иконка скрыта; шкала сбрасывается", function()
	local bt = load(BUFF_TIMER)
	local timer = bt.new()
	for _, value in { nil, "1000020", 0 / 0, math.huge, T0 - 1 } do
		local s = bt.Update(timer, value, T0, DURATION)
		assert(not s.Visible, tostring(value))
	end
	-- Тот же срок после сброса считается новым: шкала от текущего остатка.
	bt.Update(timer, T0 + 20, T0, DURATION)
	bt.Update(timer, nil, T0 + 1, DURATION)
	local s = bt.Update(timer, T0 + 20, T0 + 1, DURATION)
	assert(s.Visible and near(s.Grey, 1 / 20))
end)

test("VisualConfig.BuffIcons: иконка у каждого баффа; без иконки или лишняя — конфиг не грузится", function()
	local config = load("src/shared/Config/VisualConfig")
	local buffConfig = load("src/shared/Config/BuffConfig")
	for _, id in buffConfig.BuffIds do
		local icon = config.BuffIcons.Icons[id]
		assert(icon and icon.Symbol ~= "", id)
	end

	local function loadPatched(from: string, to: string)
		local world = Harness.NewWorld()
		world.SourcePatches["src/shared/Config/VisualConfig"] = function(source: string): string
			local start, finish = string.find(source, from, 1, true)
			assert(start, "патч не применился — тест устарел")
			return string.sub(source, 1, start - 1) .. to .. string.sub(source, finish + 1)
		end
		return pcall(world.LoadModule, world, "src/shared/Config/VisualConfig")
	end
	local ok, err = loadPatched("\t\t\tSpeedBoost = {", "\t\t\tFlyBoost = {")
	assert(not ok and string.find(tostring(err), "BuffIcons.Icons", 1, true), tostring(err))
end)

test("VisualConfig.BuffIcons: картинки — загруженные Image-ассеты; не rbxassetid://<число> — конфиг не грузится", function()
	local config = load("src/shared/Config/VisualConfig")
	assert(config.BuffIcons.Icons.MagnetBoost.Image == "rbxassetid://102586834440836")
	assert(config.BuffIcons.Icons.SpeedBoost.Image == "rbxassetid://125239100169292")

	local world = Harness.NewWorld()
	world.SourcePatches["src/shared/Config/VisualConfig"] = function(source: string): string
		local patched, count = string.gsub(source, "rbxassetid://125239100169292", "125239100169292")
		assert(count == 1, "патч не применился — тест устарел")
		return patched
	end
	local ok, err = pcall(world.LoadModule, world, "src/shared/Config/VisualConfig")
	assert(not ok and string.find(tostring(err), "Image", 1, true), tostring(err))
end)

return tests
