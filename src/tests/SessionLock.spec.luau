--[[
	Регрессионные тесты session-lock (ProfileStoreService) и миграций (DataSystem).
	Раздел 6 ТЗ; находка M-2 из security-ревью перед S4.

	Запуск: lune run src/tests/run (из корня репозитория).
]]

local Harness = require("./lib/Harness")

local KEY = "Player_42"

type Test = { Name: string, Run: () -> () }

local tests: { Test } = {}

local function test(name: string, run: () -> ())
	table.insert(tests, { Name = name, Run = run })
end

local function lockOf(world: any): any
	local record = world.Records[KEY]
	return record and record.Meta.ActiveSession
end

-- Синхронно выполнить yield-функцию внутри мира и вернуть её результат.
local function runIn(world: any, fn: () -> any, timeout: number?): any
	local result = "<не завершилось>"
	world:Spawn(function()
		result = fn()
	end)
	world:Advance(timeout or 120)
	return result
end

------------------------------------------------------------------------------------------
-- M-2: гонки внутри одного сервера
------------------------------------------------------------------------------------------

test("M2-a: реджойн на тот же сервер при медленной первой загрузке", function()
	local world = Harness.NewWorld()
	local sessionLost = false
	local server = world:NewServer(function()
		sessionLost = true
	end)

	local p1, p2 = world:NewPlayer(), world:NewPlayer()
	local r1, r2 = "pending", "pending"

	world.StoreDelays = { 3 } -- первая загрузка висит 3 с
	world:Spawn(function()
		r1 = server.LoadProfile(p1)
	end)
	world:Spawn(function()
		world.Task.wait(1)
		p1.Parent = nil -- игрок вышел во время загрузки
		r2 = server.LoadProfile(p2) -- и сразу перезашёл
	end)
	world:Advance(60)

	assert(r1 == nil, "ушедшему игроку профиль не выдаётся")
	assert(type(r2) == "table" and r2.Active, "перезашедший игрок должен загрузиться")
	assert(lockOf(world) and lockOf(world).LoadId == r2.LoadId, "лок принадлежит загрузке p2, а не снят релизом p1")

	assert(runIn(world, function()
		return server.SaveProfile(p2)
	end) == true, "автосейв p2 проходит")
	assert(not sessionLost, "p2 не кикается")
end)

test("M2-b: двойной LoadProfile для одного Player даёт один профиль и один захват", function()
	local world = Harness.NewWorld()
	local server = world:NewServer()
	local player = world:NewPlayer()
	local a, b

	world.StoreDelays = { 2 }
	world:Spawn(function()
		a = server.LoadProfile(player)
	end)
	world:Spawn(function()
		b = server.LoadProfile(player)
	end)
	world:Advance(60)

	assert(a ~= nil and a == b, "оба вызова возвращают один и тот же профиль")
	assert(world.Records[KEY].Meta.SessionLoadCount == 1, "лок захвачен ровно один раз")
end)

test("M2-c: медленный релиз старого профиля не снимает лок новой загрузки", function()
	local world = Harness.NewWorld()
	local sessionLost = false
	local server = world:NewServer(function()
		sessionLost = true
	end)
	local q1, q2 = world:NewPlayer(), world:NewPlayer()

	assert(runIn(world, function()
		return server.LoadProfile(q1)
	end), "первая загрузка")

	world.StoreDelays = { 2 } -- финальная запись q1 висит 2 с
	world:Spawn(function()
		q1.Parent = nil
		server.ReleaseProfile(q1)
	end)
	local q2Profile
	world:Spawn(function()
		q2Profile = server.LoadProfile(q2)
	end)
	world:Advance(60)

	assert(q2Profile and lockOf(world).LoadId == q2Profile.LoadId, "лок принадлежит новой загрузке")
	assert(runIn(world, function()
		return server.SaveProfile(q2)
	end) == true, "автосейв нового профиля проходит")
	assert(not sessionLost, "новый профиль не теряет сессию")
end)

------------------------------------------------------------------------------------------
-- Регрессия: межсерверный session-lock
------------------------------------------------------------------------------------------

test("Новый игрок получает дефолтный профиль", function()
	local world = Harness.NewWorld()
	local server = world:NewServer()
	local profile = runIn(world, function()
		return server.LoadProfile(world:NewPlayer())
	end)

	assert(profile, "профиль загружен")
	assert(profile.Data.Currency.Essence == 0)
	assert(profile.Data.Rebirth.Count == 0)
	assert(profile.Data.Rebirth.CurrentBiome == "DreamMeadow")
	assert(profile.Data.Meta.SchemaVersion >= 1)
	assert(lockOf(world).LoadId == profile.LoadId)
end)

test("Второй сервер ждёт релиза первого и получает его финальные данные", function()
	local world = Harness.NewWorld()
	local serverA = world:NewServer()
	local serverB = world:NewServer()
	local onA, onB = world:NewPlayer(), world:NewPlayer()

	local profileA = runIn(world, function()
		return serverA.LoadProfile(onA)
	end)
	profileA.Data.Currency.Essence = 100

	local profileB
	world:Spawn(function()
		profileB = serverB.LoadProfile(onB)
	end)
	world:Spawn(function()
		world.Task.wait(7) -- B уже несколько раз упёрся в лок
		profileA.Data.Currency.Essence = 777
		onA.Parent = nil
		serverA.ReleaseProfile(onA)
	end)
	world:Advance(60)

	assert(profileB, "B загрузил профиль после релиза A")
	assert(profileB.Data.Currency.Essence == 777, "B видит финальную запись A, а не промежуточную")
end)

test("Живой лок перехватывается на последней попытке; старый владелец не может писать", function()
	local world = Harness.NewWorld()
	local lostOnA = false
	local serverA = world:NewServer(function()
		lostOnA = true
	end)
	local serverB = world:NewServer()
	local onA, onB = world:NewPlayer(), world:NewPlayer()

	local profileA = runIn(world, function()
		return serverA.LoadProfile(onA)
	end)
	profileA.Data.Currency.Essence = 50
	assert(runIn(world, function()
		return serverA.SaveProfile(onA)
	end))

	local startedAt = world.Now
	local profileB = runIn(world, function()
		return serverB.LoadProfile(onB)
	end)
	assert(profileB, "B перехватил лок")
	assert(world.Now - startedAt >= 30, "перехват только после ожидания (~35 с)")

	profileA.Data.Currency.Essence = 999_999 -- попытка «дюпа» со старого сервера
	assert(runIn(world, function()
		return serverA.SaveProfile(onA)
	end) == false, "запись потерявшего лок отменяется")
	assert(lostOnA, "старому серверу сообщено о потере сессии")
	assert(world.Records[KEY].Data.Currency.Essence == 50, "данные в хранилище не перезаписаны")
	assert(lockOf(world).LoadId == profileB.LoadId)
end)

test("Протухший лок (упавший сервер) перехватывается без ожидания", function()
	local world = Harness.NewWorld()
	local crashed = world:NewServer()
	local fresh = world:NewServer()

	assert(runIn(world, function()
		return crashed.LoadProfile(world:NewPlayer())
	end))
	world:Advance(11 * 60) -- пульса нет дольше STALE_LOCK_SECONDS

	local startedAt = world.Now
	local profile
	world:Spawn(function()
		profile = fresh.LoadProfile(world:NewPlayer())
	end)
	world:Advance(1)
	assert(profile, "лок перехвачен")
	assert(world.Now - startedAt <= 1, "без ретраев")
end)

test("ReleaseAll снимает лок, сохраняет данные и запрещает новые загрузки", function()
	local world = Harness.NewWorld()
	local server = world:NewServer()
	local player = world:NewPlayer()

	local profile = runIn(world, function()
		return server.LoadProfile(player)
	end)
	profile.Data.Currency.Essence = 5

	runIn(world, function()
		server.ReleaseAll()
		return nil
	end)
	assert(lockOf(world) == nil, "лок снят")
	assert(world.Records[KEY].Data.Currency.Essence == 5, "финальные данные записаны")
	assert(runIn(world, function()
		return server.LoadProfile(world:NewPlayer())
	end) == nil, "после выключения загрузки запрещены")
end)

------------------------------------------------------------------------------------------
-- Миграции DataSystem
------------------------------------------------------------------------------------------

test("Миграция: запись без SchemaVersion дозаполняется, существующие данные сохраняются", function()
	local world = Harness.NewWorld()
	local _, dataSystem = world:NewServer()

	local legacy = { Currency = { Essence = 10 }, Pets = { { Id = "pet-1" } } }
	local migrated = dataSystem.MigrateProfileData(legacy)

	assert(migrated, "миграция прошла")
	assert(migrated.Currency.Essence == 10, "валюта не потеряна")
	assert(#migrated.Pets == 1 and migrated.Pets[1].Id == "pet-1", "петы не потеряны")
	assert(migrated.Factory.Level ~= nil, "недостающие разделы дозаполнены")
	assert(migrated.Meta.SchemaVersion == dataSystem.CURRENT_SCHEMA_VERSION)
end)

test("Миграция: данные более новой схемы не трогаются", function()
	local world = Harness.NewWorld()
	local _, dataSystem = world:NewServer()

	local newer = { Meta = { SchemaVersion = 9999 }, Currency = { Essence = 1 } }
	local snapshot = Harness.DeepCopy(newer)
	local migrated, reason = dataSystem.MigrateProfileData(newer)

	assert(migrated == nil and type(reason) == "string", "загрузка отклонена с причиной")
	assert(newer.Factory == nil and newer.Meta.SchemaVersion == snapshot.Meta.SchemaVersion, "данные не мутированы")
end)

-- Глубокое сравнение; NaN считается равным NaN (иначе запись с SchemaVersion = 0/0 не сравнить).
local function deepEqual(a: any, b: any): boolean
	if type(a) ~= "table" or type(b) ~= "table" then
		return a == b or (a ~= a and b ~= b)
	end
	for k, v in a do
		if not deepEqual(v, b[k]) then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end

test("S4-2: повреждённые Meta/SchemaVersion отклоняются как corrupt без мутаций", function()
	local world = Harness.NewWorld()
	local _, dataSystem = world:NewServer()

	local cases: { { Name: string, Meta: any } } = {
		{ Name = "SchemaVersion = \"abc\"", Meta = { SchemaVersion = "abc" } },
		{ Name = "SchemaVersion = \"2\"", Meta = { SchemaVersion = "2" } },
		{ Name = "SchemaVersion = 1.5", Meta = { SchemaVersion = 1.5 } },
		{ Name = "SchemaVersion = -1", Meta = { SchemaVersion = -1 } },
		{ Name = "SchemaVersion = NaN", Meta = { SchemaVersion = 0 / 0 } },
		{ Name = "SchemaVersion = inf", Meta = { SchemaVersion = math.huge } },
		{ Name = "SchemaVersion = -inf", Meta = { SchemaVersion = -math.huge } },
		{ Name = "SchemaVersion = true", Meta = { SchemaVersion = true } },
		{ Name = "Meta = 5", Meta = 5 },
		{ Name = "Meta = \"x\"", Meta = "x" },
	}
	for _, case in cases do
		local data = { Meta = case.Meta, Currency = { Essence = 10 }, Factory = { StorageCapacity = 100 } }
		local snapshot = Harness.DeepCopy(data)
		local migrated, reason, kind = dataSystem.MigrateProfileData(data)

		assert(migrated == nil and type(reason) == "string", `{case.Name}: загрузка отклонена с причиной`)
		assert(kind == "corrupt", `{case.Name}: вид ошибки corrupt, а не {kind}`)
		assert(deepEqual(data, snapshot), `{case.Name}: данные не мутированы`)
	end
end)

test("S4-2: слишком новая схема отклоняется как newer-schema", function()
	local world = Harness.NewWorld()
	local _, dataSystem = world:NewServer()

	local data = { Meta = { SchemaVersion = dataSystem.CURRENT_SCHEMA_VERSION + 1 } }
	local snapshot = Harness.DeepCopy(data)
	local migrated, reason, kind = dataSystem.MigrateProfileData(data)
	assert(migrated == nil and type(reason) == "string" and kind == "newer-schema")
	assert(deepEqual(data, snapshot), "данные не мутированы")
end)

test("S4-2: Meta = nil и SchemaVersion = nil по-прежнему мигрируют с версии 0", function()
	local world = Harness.NewWorld()
	local _, dataSystem = world:NewServer()

	for _, data in { { Currency = { Essence = 7 } }, { Meta = { FirstJoinAt = 1 }, Currency = { Essence = 7 } } } do
		local migrated, reason, kind = dataSystem.MigrateProfileData(data)
		assert(migrated, `миграция прошла: {reason}`)
		assert(reason == nil and kind == nil)
		assert(migrated.Currency.Essence == 7, "валюта сохранена")
		assert(migrated.Factory.StorageCapacityLevel == 0, "дозаполнено reconcile()")
		assert(migrated.Meta.SchemaVersion == dataSystem.CURRENT_SCHEMA_VERSION)
	end
end)

-- DataSystem.Init с отдельным ProfileStoreService («процесс сервера» без NewServer) и игрок
-- с методом Kick. Профиль в хранилище подкладывается заранее.
local function joinWithRecord(storedData: any): (any, any, { string })
	local world = Harness.NewWorld()
	world.Records[KEY] = {
		Data = storedData,
		Meta = { ActiveSession = nil, LastUpdate = 0, SessionLoadCount = 0 },
	}
	local kicks = {}
	local player = world:NewPlayer() :: any
	function player:Kick(message: string)
		table.insert(kicks, message)
		self.Parent = nil
	end
	world.Players = { player }

	local dataSystem = world:LoadModule("src/server/Systems/DataSystem")
	world:Spawn(function()
		dataSystem.Init() -- подхватывает уже вошедших игроков (world.Players)
	end)
	world:Advance(60)
	return world, dataSystem, kicks
end

test("S4-2: onPlayerAdded при повреждённом профиле кикает игрока и снимает лок", function()
	for _, stored in { { Meta = { SchemaVersion = 1.5 }, Currency = { Essence = 3 } }, { Meta = 5, Currency = { Essence = 3 } } } do
		local snapshot = Harness.DeepCopy(stored)
		local world, dataSystem, kicks = joinWithRecord(stored)

		assert(#kicks == 1 and string.find(kicks[1], "Не удалось прочитать сохранение", 1, true), "кик с текстом о порче")
		assert(lockOf(world) == nil, "лок снят")
		assert(deepEqual(world.Records[KEY].Data, snapshot), "данные записаны как есть")
		assert(dataSystem.GetData(world.Players[1]) == nil, "профиль не выдан системам")
	end
end)

test("S4-2: onPlayerAdded при слишком новой схеме кикает с прежним текстом", function()
	local world, _, kicks = joinWithRecord({ Meta = { SchemaVersion = 9999 } })
	assert(#kicks == 1 and string.find(kicks[1], "Сервер обновляется", 1, true), "кик про обновление сервера")
	assert(lockOf(world) == nil, "лок снят")
end)

test("S4-2: onPlayerAdded с нормальным профилем не кикает", function()
	local world, dataSystem, kicks = joinWithRecord({ Meta = { SchemaVersion = 2 }, Currency = { Essence = 3 } })
	assert(#kicks == 0, "без кика")
	local data = dataSystem.GetData(world.Players[1])
	assert(data and data.Currency.Essence == 3, "профиль выдан")
	assert(lockOf(world) ~= nil, "лок держится")
end)

------------------------------------------------------------------------------------------
-- Fallback на in-memory хранилище в Studio (S2-fix)
------------------------------------------------------------------------------------------

-- Профиль загружается, правится и сохраняется, а настоящий DataStore не трогается.
local function assertWorksInMemory(world: any, server: any)
	local player = world:NewPlayer()
	local profile = runIn(world, function()
		return server.LoadProfile(player)
	end)
	assert(type(profile) == "table" and profile.Active, "профиль загружен через in-memory хранилище")

	profile.Data.Currency.Essence = 7
	assert(runIn(world, function()
		return server.SaveProfile(player)
	end) == true, "сохранение работает")
	assert(world.Records[KEY] == nil, "настоящий DataStore не использовался")

	local hasWarning = false
	for _, message in world.Warnings do
		if string.find(message, "in-memory", 1, true) then
			hasWarning = true
		end
	end
	assert(hasWarning, "предупреждение о том, что прогресс не сохраняется")
end

test("Studio: GetDataStore бросает ошибку (плейс не опубликован) — работаем через in-memory", function()
	local world = Harness.NewWorld()
	world.IsStudio = true
	world.GetDataStoreError = "You must publish this place to the web to access DataStore."

	local server = world:NewServer() -- не должно бросать
	assertWorksInMemory(world, server)
end)

test("Studio: пробная запись отклонена (нет доступа к API) — тот же fallback", function()
	local world = Harness.NewWorld()
	world.IsStudio = true
	world.Store.UpdateAsync = function()
		error("Studio access to APIs is not allowed", 0)
	end

	local server = world:NewServer()
	assertWorksInMemory(world, server)
end)

test("Studio: доступный DataStore используется как обычно", function()
	local world = Harness.NewWorld()
	world.IsStudio = true

	local server = world:NewServer()
	local player = world:NewPlayer()
	assert(runIn(world, function()
		return server.LoadProfile(player)
	end), "профиль загружен")
	assert(world.Records[KEY] ~= nil, "запись ушла в настоящий DataStore")
end)

test("Вне Studio: ошибка GetDataStore не глотается (без молчаливой потери прогресса)", function()
	local world = Harness.NewWorld()
	world.IsStudio = false
	world.GetDataStoreError = "DataStore unavailable"

	local ok, err = pcall(function()
		world:NewServer()
	end)
	assert(not ok, "Init должен упасть, а не подменить хранилище")
	assert(string.find(tostring(err), "DataStore unavailable", 1, true), "исходная причина сохранена")
end)

return tests
