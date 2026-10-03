--[[
	Тесты MovementGuard: доверенная позиция следует за нормальным перемещением, телепорт её не
	сдвигает (одно предупреждение за окно), восстановление после скачка — не быстрее ходьбы,
	частые запросы не разгоняют точку выше потолка, респавн через CharacterAdded — не скачок
	(база только с позиции спавна), окно скорости скользящее, вертикальные потолки, NaN,
	период без корня, выход игрока, легитимное ускорение (Speed Boost через BuffSystem) и его снятие.

	Запуск: lune run src/tests/run (из корня репозитория).
]]

local Harness = require("./lib/Harness")

type Test = { Name: string, Run: () -> () }

local tests: { Test } = {}

local function test(name: string, run: () -> ())
	table.insert(tests, { Name = name, Run = run })
end

-- Мир с MovementGuard; init = false — без Init (как юнит-тесты систем: нет подписок и
-- фонового замера).
local function setup(init: boolean?)
	local world = Harness.NewWorld()
	-- DataSystem — профили в памяти (для BuffSystem в тестах Speed Boost; MovementGuard его не читает).
	local profiles = {}
	local load = world:ModuleLoader({
		["src/server/Systems/DataSystem"] = {
			GetData = function(p)
				return profiles[p]
			end,
		},
		-- BuffSystem.Init подписывается на ActivateBuff; запросы клиента здесь не нужны.
		["src/shared/Remotes"] = {
			ActivateBuff = { OnServerEvent = { Connect = function() end } },
		},
	})
	local guard = load("src/server/Services/MovementGuard")
	local config = load("src/server/Config/MovementGuardConfig")
	-- Vector3 модулей: строим от готового объекта из конфига (та же метатаблица).
	local base = load("src/shared/Config/ChaosBossConfig").BossPosition
	local function vec(x: number, y: number, z: number)
		local v = base - base
		v.X, v.Y, v.Z = x, y, z
		return v
	end

	if init ~= false then
		guard.Init()
	end

	local t = { World = world, Guard = guard, Config = config, Vec = vec, Load = load, Profiles = profiles }

	-- Игрок заходит и спавнится в (x, y, z); базовая точка взята к возврату.
	function t.Join(userId: number, x: number?, y: number?, z: number?)
		local player = world:NewPlayer(userId)
		table.insert(world.Players, player)
		world:FirePlayerAdded(player)
		local character, root, humanoid = world:NewCharacter(vec(x or 0, y or 0, z or 0))
		world:SpawnCharacter(player, character)
		world:Advance(0.1)
		return player, root, humanoid, character
	end

	function t.Trusted(player)
		return guard.GetTrustedPosition(player)
	end

	function t.GuardWarnings(): number
		local count = 0
		for _, text in world.Warnings do
			if string.find(text, "[MovementGuard]", 1, true) then
				count += 1
			end
		end
		return count
	end

	return t
end

local function at(v, x: number, y: number, z: number): boolean
	return v ~= nil and math.abs(v.X - x) < 1e-6 and math.abs(v.Y - y) < 1e-6 and math.abs(v.Z - z) < 1e-6
end

------------------------------------------------------------------------------------------
-- Нормальное перемещение и телепорт
------------------------------------------------------------------------------------------

test("Обычная ходьба (WalkSpeed 16) не блокируется: доверенная позиция идёт за персонажем", function()
	local t = setup()
	local player, root = t.Join(1)
	-- 10 секунд ходьбы по X со скоростью 16 studs/s шагами по 0.1 с, фоновый замер работает.
	for step = 1, 100 do
		root.Position = t.Vec(1.6 * step, 0, 0)
		t.World:Advance(0.1)
		assert(at(t.Trusted(player), 1.6 * step, 0, 0), `шаг {step} принят`)
	end
	assert(t.GuardWarnings() == 0, "честная ходьба не логируется")
end)

test("Телепорт не сдвигает доверенную позицию; предупреждение — одно на окно", function()
	local t = setup()
	local player, root = t.Join(1, 10, 0, 10)
	t.World:Advance(1)

	root.Position = t.Vec(500, 0, 10)
	assert(at(t.Trusted(player), 10, 0, 10), "сразу после скачка — старая точка")
	t.World:Advance(0.5) -- фоновые замеры тоже не принимают скачок
	assert(at(t.Trusted(player), 10, 0, 10), "фоновый замер не сдвинул точку")
	for _ = 1, 5 do
		t.Trusted(player)
	end
	assert(t.GuardWarnings() == 1, `одно предупреждение, получено {t.GuardWarnings()}`)
	assert(string.find(t.World.Warnings[#t.World.Warnings], "TestPlayer (1)", 1, true), "в логе Name и UserId")

	-- Вернулся назад (эксплойтер «откатил» телепорт) — позиция снова нормальная.
	root.Position = t.Vec(12, 0, 10)
	assert(at(t.Trusted(player), 12, 0, 10))

	-- Новое окно лога — новое предупреждение о следующем скачке.
	t.World:Advance(t.Config.SuspiciousLogWindow + 1)
	root.Position = t.Vec(-500, 0, 10)
	t.Trusted(player)
	assert(t.GuardWarnings() == 2, "второе предупреждение в новом окне")
end)

test("После скачка точка догоняет персонажа только на RecoverySpeed, а не на потолке скорости", function()
	local t = setup()
	local c = t.Config
	local player, root = t.Join(1)
	t.World:Advance(1)

	local distance = 400
	root.Position = t.Vec(distance, 0, 0)
	assert(at(t.Trusted(player), 0, 0, 0))
	-- Бегом на потолке уже можно было бы дойти — но после скачка это не засчитывается.
	t.World:Advance(distance / c.MaxHorizontalSpeed + 1)
	assert(at(t.Trusted(player), 0, 0, 0), "телепорт + ожидание не быстрее ходьбы")
	t.World:Advance(distance / c.RecoverySpeed - distance / c.MaxHorizontalSpeed)
	assert(at(t.Trusted(player), distance, 0, 0), "честного игрока после «флинга» отпускает без респавна")

	-- После восстановления — снова обычный потолок (бег на 90% потолка принимается).
	local x = distance
	for _ = 1, 10 do
		x += c.MaxHorizontalSpeed * 0.9 * 0.1
		root.Position = t.Vec(x, 0, 0)
		t.World:Advance(0.1)
		assert(at(t.Trusted(player), x, 0, 0), `после восстановления шаг до {x} принят`)
	end
end)

test("Частые запросы не разгоняют доверенную точку: допуск не складывается по замерам", function()
	local t = setup()
	local c = t.Config
	local player, root = t.Join(1)
	t.World:Advance(1)
	-- Speed-hack «лесенкой»: запрос каждые 0.01 с, каждый шаг чуть быстрее потолка —
	-- по отдельности каждый укладывается в запас ведра.
	local step = (c.MaxHorizontalSpeed + 4 * c.BurstRefillRate) * 0.01
	local x = 0
	local elapsed = 0
	for _ = 1, 500 do
		x += step
		root.Position = t.Vec(x, 0, 0)
		t.World:Advance(0.01)
		elapsed += 0.01
		t.Trusted(player)
	end
	local trusted = assert(t.Trusted(player))
	local limit = (c.MaxHorizontalSpeed + c.BurstRefillRate) * elapsed + c.BurstAllowance
	assert(trusted.X <= limit, `доверенная точка ушла на {trusted.X} studs за {elapsed} с, потолок {limit}`)
	assert(x > limit, "сам персонаж ушёл дальше потолка — тест осмыслен")
end)

test("Серия быстрых легитимных шагов не копит ложную скорость (окно от последней принятой точки)", function()
	local t = setup()
	local c = t.Config
	local player, root = t.Join(1)
	-- 20 с бега на 90% потолка: суммарно далеко, но каждый шаг правдоподобен.
	local speed = c.MaxHorizontalSpeed * 0.9
	local x = 0
	for _ = 1, 200 do
		x += speed * 0.1
		root.Position = t.Vec(x, 0, 0)
		t.World:Advance(0.1)
		assert(at(t.Trusted(player), x, 0, 0), `шаг до x = {x} принят`)
	end
	assert(t.GuardWarnings() == 0)

	-- И обратное: после долгой спокойной сессии средняя скорость «от первой точки» мала, но
	-- мгновенный скачок всё равно ловится — скорость считается по последнему интервалу.
	t.World:Advance(1000)
	root.Position = t.Vec(x + 300, 0, 0)
	assert(at(t.Trusted(player), x, 0, 0), "телепорт после долгой сессии не принят")
end)

test("Пачка репликации в одном кадре (dt = 0) поглощается ведром допуска, но не сверх ёмкости", function()
	local t = setup()
	local c = t.Config
	local player, root = t.Join(1)
	t.World:Advance(1)
	t.Trusted(player)
	root.Position = t.Vec(c.BurstAllowance - 0.5, 0, 0)
	assert(at(t.Trusted(player), c.BurstAllowance - 0.5, 0, 0), "джиттер в пределах ёмкости")
	-- Ведро почти пустое: ещё одна пачка в том же кадре — уже скачок.
	root.Position = t.Vec(2 * c.BurstAllowance, 0, 0)
	assert(at(t.Trusted(player), c.BurstAllowance - 0.5, 0, 0), "сверх ёмкости — скачок")
end)

test("Вертикаль: свободное падение быстрее ходьбы допустимо, взлёт с той же скоростью — нет", function()
	local t = setup()
	local gravity = 196.2 -- Workspace.Gravity по умолчанию
	local height = 300
	local fallTime = math.sqrt(2 * height / gravity) -- ≈ 1.75 с, в конце ≈ 343 studs/s
	local player, root = t.Join(1, 0, height, 0)
	t.World:Advance(1)

	local elapsed = 0
	while elapsed < fallTime do
		elapsed = math.min(elapsed + 0.05, fallTime)
		root.Position = t.Vec(0, height - gravity * elapsed * elapsed / 2, 0)
		t.World:Advance(0.05)
	end
	assert(at(t.Trusted(player), 0, 0, 0), "падение принято")
	assert(t.GuardWarnings() == 0)

	-- Тот же профиль скорости, но вверх — полёт-эксплойт: доверенная точка отстаёт.
	elapsed = 0
	while elapsed < fallTime do
		elapsed = math.min(elapsed + 0.05, fallTime)
		root.Position = t.Vec(0, gravity * elapsed * elapsed / 2, 0)
		t.World:Advance(0.05)
	end
	local trusted = assert(t.Trusted(player))
	assert(trusted.Y < height / 2, `взлёт не принят целиком, доверенная высота {trusted.Y}`)
	assert(t.GuardWarnings() == 1)
end)

test("Вертикаль: честный прыжок (JumpPower 50) проходит, длительный подъём 40 studs/s (fly-hack) — нет", function()
	local t = setup()
	local gravity = 196.2
	local player, root = t.Join(1)
	t.World:Advance(1)
	-- Прыжок: v0 = 50, в воздухе ~0.51 с, пик ~6.4 studs; два прыжка подряд.
	for _ = 1, 2 do
		local airTime = 2 * 50 / gravity
		local elapsed = 0
		while elapsed < airTime do
			elapsed = math.min(elapsed + 0.05, airTime)
			root.Position = t.Vec(0, math.max(50 * elapsed - gravity * elapsed * elapsed / 2, 0), 0)
			t.World:Advance(0.05)
			assert(t.Trusted(player).Y == root.Position.Y, `прыжок принят на высоте {root.Position.Y}`)
		end
	end
	assert(t.GuardWarnings() == 0, "прыжок не логируется")

	-- Fly-hack: ровный подъём 40 studs/s в течение 3 с.
	for step = 1, 60 do
		root.Position = t.Vec(0, 40 * 0.05 * step, 0)
		t.World:Advance(0.05)
	end
	local trusted = assert(t.Trusted(player))
	assert(trusted.Y < 120 * 0.75, `доверенная высота {trusted.Y} из 120 — полёт не принят целиком`)
end)

------------------------------------------------------------------------------------------
-- Респавн и базовая точка
------------------------------------------------------------------------------------------

test("Респавн (CharacterAdded) — не скачок: база переустанавливается без предупреждения", function()
	local t = setup()
	local player, root, humanoid = t.Join(1, 0, 0, 0)
	root.Position = t.Vec(5, 0, 0)
	t.World:Advance(1)

	humanoid.Health = 0
	assert(t.Trusted(player) == nil, "мёртвый персонаж — nil")

	-- Сервер спавнит персонажа на точке возрождения в 1000 studs.
	local character, newRoot = t.World:NewCharacter(t.Vec(1000, 0, 0))
	t.World:SpawnCharacter(player, character)
	assert(t.Trusted(player) == nil, "до взятия базы доверенной позиции нет")
	t.World:Advance(0.1)
	assert(at(t.Trusted(player), 1000, 0, 0), "новая база — точка спавна")
	assert(t.GuardWarnings() == 0, "респавн не логируется")

	-- Телепорт сразу после спавна, ещё до первого запроса, — всё равно скачок от точки спавна.
	newRoot.Position = t.Vec(0, 0, 0)
	assert(at(t.Trusted(player), 1000, 0, 0), "база взята при спавне, а не при первом запросе")
	assert(t.GuardWarnings() == 1)
end)

test("База берётся только когда персонаж в Workspace; до этого — nil, а не позиция из запроса", function()
	local t = setup()
	local player = t.World:NewPlayer(1)
	table.insert(t.World.Players, player)
	t.World:FirePlayerAdded(player)
	local character, root = t.World:NewCharacter(t.Vec(0, 0, 0))
	character.InWorkspace = false
	t.World:SpawnCharacter(player, character)
	t.World:Advance(0.5)
	assert(t.Trusted(player) == nil, "персонаж ещё не в Workspace — базы нет")

	character.InWorkspace = true
	root.Position = t.Vec(50, 0, 0) -- движок поставил его на точку спавна
	t.World:Advance(0.1)
	assert(at(t.Trusted(player), 50, 0, 0), "база — позиция в Workspace")
end)

test("Медленная загрузка дольше SpawnRootTimeout: одно предупреждение, база берётся при появлении", function()
	local t = setup()
	local player = t.World:NewPlayer(1)
	table.insert(t.World.Players, player)
	t.World:FirePlayerAdded(player)
	local character = t.World:NewCharacter(t.Vec(7, 0, 0))
	character.InWorkspace = false
	t.World:SpawnCharacter(player, character)
	t.World:Advance(t.Config.SpawnRootTimeout * 3)
	assert(t.Trusted(player) == nil)
	assert(t.GuardWarnings() == 1, "одно предупреждение о долгой загрузке")

	character.InWorkspace = true
	t.World:Advance(1)
	assert(at(t.Trusted(player), 7, 0, 0), "база взята, игрок не застрял до респавна")
end)

test("Смена Player.Character до обработки CharacterAdded — ожидание базы, не скачок", function()
	local t = setup()
	local player = t.Join(1, 0, 0, 0)
	t.World:Advance(1)
	-- Deferred-сигналы: Character уже новый, подписчики CharacterAdded ещё не отработали.
	local character = t.World:NewCharacter(t.Vec(800, 0, 0))
	player.Character = character
	assert(t.Trusted(player) == nil, "новый персонаж без базы — nil")
	t.World:Advance(1) -- фоновый замер базу тоже не берёт
	assert(t.Trusted(player) == nil)
	assert(t.GuardWarnings() == 0, "не скачок")

	t.World:SpawnCharacter(player, character) -- обработчик CharacterAdded дошёл
	t.World:Advance(0.1)
	assert(at(t.Trusted(player), 800, 0, 0))
end)

test("Без Init (юнит-тесты систем): база — с первого замера, дальше те же проверки", function()
	local t = setup(false)
	local player = t.World:NewPlayer(1)
	local character, root = t.World:NewCharacter(t.Vec(10, 0, 0))
	player.Character = character
	assert(at(t.Trusted(player), 10, 0, 0), "база с первого замера")
	root.Position = t.Vec(500, 0, 0)
	assert(at(t.Trusted(player), 10, 0, 0), "скачок не принят")
end)

------------------------------------------------------------------------------------------
-- Некорректные данные, период без корня, выход
------------------------------------------------------------------------------------------

test("NaN-координаты: не становятся доверенной позицией ни в замере, ни в базе", function()
	local t = setup()
	local player, root = t.Join(1, 5, 0, 5)
	t.World:Advance(1)
	root.Position = t.Vec(0 / 0, 0, 5)
	assert(at(t.Trusted(player), 5, 0, 5), "NaN в замере — скачок")

	-- Спавн с NaN-позицией: базы нет.
	local character = t.World:NewCharacter(t.Vec(0 / 0, 0, 0))
	t.World:SpawnCharacter(player, character)
	t.World:Advance(0.5)
	assert(t.Trusted(player) == nil, "NaN-база не взята")

	-- Без Init — то же для базы с первого замера.
	local lenient = setup(false)
	local p2 = lenient.World:NewPlayer(2)
	p2.Character = lenient.World:NewCharacter(lenient.Vec(1 / 0, 0, 0))
	assert(lenient.Trusted(p2) == nil, "inf-база не взята")
end)

test("Период без живого корня не копит запас скорости: после него — только RecoverySpeed", function()
	local t = setup()
	local c = t.Config
	local player, root, humanoid = t.Join(1)
	t.World:Advance(1)

	humanoid.Health = 0 -- корень «пропал» на 10 с (тот же персонаж)
	t.World:Advance(10)
	humanoid.Health = 100
	local distance = (c.MaxHorizontalSpeed + c.RecoverySpeed) / 2 * 10 -- по потолку прошло бы
	root.Position = t.Vec(distance, 0, 0)
	assert(at(t.Trusted(player), 0, 0, 0), "возврат корня далеко от точки — не принят")
end)

test("Нет персонажа — nil; выход игрока очищает состояние и подписку, не воскрешает их", function()
	local t = setup()
	local player = t.World:NewPlayer(1)
	table.insert(t.World.Players, player)
	t.World:FirePlayerAdded(player)
	assert(t.Trusted(player) == nil, "персонажа ещё нет")

	local p2, root = t.Join(2, 0, 0, 0)
	assert(#p2.CharacterAdded._handlers == 1, "подписка на CharacterAdded есть")
	t.World:FirePlayerRemoving(p2)
	p2.Parent = nil
	table.remove(t.World.Players, table.find(t.World.Players, p2))
	assert(#p2.CharacterAdded._handlers == 0, "подписка отключена")
	root.Position = t.Vec(1, 0, 0)
	assert(t.Trusted(p2) == nil, "после выхода — nil")
	t.World:Advance(1) -- фоновый замер не трогает вышедшего
	assert(t.GuardWarnings() == 0)
end)

test("MovementGuardConfig: load-time assert ловит неположительный потолок и RecoverySpeed выше потолка", function()
	local function loadPatched(from: string, to: string)
		local world = Harness.NewWorld()
		world.SourcePatches["src/server/Config/MovementGuardConfig"] = function(source)
			local patched, count = string.gsub(source, from, to)
			assert(count == 1, `патч {from} не применился`)
			return patched
		end
		return pcall(function()
			world:LoadModule("src/server/Config/MovementGuardConfig")
		end)
	end

	local ok, err = loadPatched("MaxHorizontalSpeed = 32", "MaxHorizontalSpeed = 0")
	assert(not ok and string.find(tostring(err), "MaxHorizontalSpeed", 1, true), `assert потолка: {err}`)
	ok, err = loadPatched("RecoverySpeed = 20", "RecoverySpeed = 50")
	assert(not ok and string.find(tostring(err), "RecoverySpeed", 1, true), `assert RecoverySpeed: {err}`)
end)

------------------------------------------------------------------------------------------
-- Легитимное ускорение: бафф Speed Boost (BuffSystem → SetSpeedMultiplier)
------------------------------------------------------------------------------------------

-- BuffSystem в том же «сервере», что и MovementGuard (общий кэш модулей).
local function withBuffs(t)
	local buffs = t.Load("src/server/Systems/BuffSystem")
	buffs.Init()
	return buffs, t.Load("src/shared/Config/BuffConfig")
end

-- Игроку — один заряд Speed Boost и его активация (как клик по иконке в HUD).
local function activateSpeed(t, buffs, player)
	local data = { Buffs = { SpeedBoostCharges = 1 } }
	t.Profiles[player] = data
	assert(buffs.Activate(player, "SpeedBoost") == nil, "Speed Boost запущен")
	return data
end

-- Бег по X со скоростью speed studs/s шагами по 0.1 с; после каждого шага — запрос позиции.
local function run(t, player, root, speed: number, seconds: number)
	for _ = 1, math.round(seconds / 0.1) do
		root.Position = t.Vec(root.Position.X + speed * 0.1, 0, 0)
		t.World:Advance(0.1)
		t.Trusted(player)
	end
end

-- Лаг репликации посреди бега: stall секунд позиция на сервере стоит, потом догоняет рывком.
local function lagSpike(t, player, root, speed: number, stall: number)
	t.World:Advance(stall)
	root.Position = t.Vec(root.Position.X + speed * stall, 0, 0)
	return t.Trusted(player)
end

test("Speed Boost: бег на скорости баффа с лагом репликации не флагается (без баффа — флагается)", function()
	-- Контроль: тот же бег без баффа — скачок сверх потолка.
	local control = setup()
	local cPlayer, cRoot = control.Join(1)
	run(control, cPlayer, cRoot, 32, 10)
	lagSpike(control, cPlayer, cRoot, 32, 0.6)
	assert(control.GuardWarnings() == 1, "без баффа такой бег — подозрительный скачок")

	local t = setup()
	local buffs, buffConfig = withBuffs(t)
	local speed = buffConfig.Buffs.SpeedBoost.WalkSpeed
	assert(speed == 32, "тест рассчитан на WalkSpeed баффа 32")
	local player, root, humanoid = t.Join(1)
	activateSpeed(t, buffs, player)
	assert(humanoid.WalkSpeed == speed)

	run(t, player, root, speed, 10)
	local x = root.Position.X
	assert(at(lagSpike(t, player, root, speed, 0.6), x + speed * 0.6, 0, 0), "рывок после лага принят")
	run(t, player, root, speed, 5)
	lagSpike(t, player, root, speed, 0.6)
	assert(t.GuardWarnings() == 0, `игрок с баффом не флагается, предупреждений {t.GuardWarnings()}`)
	assert(at(t.Trusted(player), root.Position.X, 0, 0), "доверенная позиция идёт за персонажем")
end)

test("Speed Boost истёк: грейс SpeedDropGrace на стыке, дальше — обычные потолки", function()
	local t = setup()
	local buffs, buffConfig = withBuffs(t)
	local speed = buffConfig.Buffs.SpeedBoost.WalkSpeed
	local player, root, humanoid = t.Join(1)
	activateSpeed(t, buffs, player) -- истекает на 60-й секунде (BuffConfig Duration)
	assert(buffConfig.Buffs.SpeedBoost.Duration == 60, "тест рассчитан на Duration 60")

	-- Бафф снят на ~60.0 с, персонаж по инерции ещё бежит быстро и ловит лаг — в пределах грейса.
	run(t, player, root, speed, 60.5)
	assert(humanoid.WalkSpeed == buffConfig.BaseWalkSpeed, "WalkSpeed вернулся к базовой")
	lagSpike(t, player, root, speed, 0.6)
	assert(t.GuardWarnings() == 0, "на стыке истечения честного игрока не флагает")

	-- Грейс прошёл, а игрок всё ещё движется со скоростью баффа — как без баффа.
	run(t, player, root, speed, 1.5)
	lagSpike(t, player, root, speed, 0.6)
	assert(t.GuardWarnings() == 1, "после грейса ускорение без баффа — снова скачок")
end)

test("Speed Boost не пропускает телепорт: скачок далеко за потолком баффа отклоняется", function()
	local t = setup()
	local buffs = withBuffs(t)
	local player, root = t.Join(1)
	activateSpeed(t, buffs, player)
	run(t, player, root, 32, 2)
	local x = root.Position.X

	root.Position = t.Vec(x + 500, 0, 0)
	assert(at(t.Trusted(player), x, 0, 0), "доверенная точка не сдвинута")
	assert(t.GuardWarnings() == 1)
end)

test("SetSpeedMultiplier: зажат MaxSpeedMultiplier, NaN/ниже 1 — считается 1", function()
	local t = setup()
	local player, root = t.Join(1)
	t.World:Advance(1)

	t.Guard.SetSpeedMultiplier(player, 100)
	t.World:Advance(1)
	-- При ×100 прошёл бы; при потолке ×MaxSpeedMultiplier — нет.
	root.Position = t.Vec(t.Config.MaxHorizontalSpeed * t.Config.MaxSpeedMultiplier + 100, 0, 0)
	assert(at(t.Trusted(player), 0, 0, 0), "множитель зажат")

	local t2 = setup()
	local p2, r2 = t2.Join(1)
	t2.World:Advance(1)
	t2.Guard.SetSpeedMultiplier(p2, 0 / 0)
	t2.Guard.SetSpeedMultiplier(p2, 0.2)
	t2.World:Advance(1)
	r2.Position = t2.Vec(t2.Config.MaxHorizontalSpeed * 2, 0, 0)
	assert(at(t2.Trusted(p2), 0, 0, 0), "NaN и множитель < 1 не ослабляют проверку")
	local warned = false
	for _, text in t2.World.Warnings do
		warned = warned or string.find(text, "Некорректный множитель", 1, true) ~= nil
	end
	assert(warned, "NaN записан в лог")
end)

return tests
