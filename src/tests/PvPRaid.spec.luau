--[[
	Тесты PvP-рейда (PvPRaidSystem): потолок кражи (StealPercent vs HardCap), щит при входе,
	grace-окно цели после рейда, кулдаун пары attacker→target, формула защиты (стражи +
	Fearful-петы цели через настоящий кэш PetSystem), двойная доставка запроса, выход цели,
	изоляция битых профилей, игнор клиентских аргументов, дистанция до рейд-инстанса и
	load-time проверки PvPConfig/GuardConfig.

	Запуск: lune run src/tests/run (из корня репозитория).
]]

local Harness = require("./lib/Harness")

type Test = { Name: string, Run: () -> () }

local tests: { Test } = {}

local function test(name: string, run: () -> ())
	table.insert(tests, { Name = name, Run = run })
end

-- PvPRaidSystem в изоляции: DataSystem — профили в памяти, FactorySystem — счётчик
-- PushSnapshot, PetSystem — настоящий модуль (без Init) поверх того же DataSystem, ремоуты —
-- перехват обработчика. patches — подмена полей PvPConfig/GuardConfig для теста.
local function setup(patches: { PvP: { [string]: any }?, Guard: { [string]: any }? }?)
	local world = Harness.NewWorld()
	local _, dataSystem = world:NewServer()
	local profiles = {}
	local handlers = {}
	local pushes = {}

	local fakeFactory = {
		PushSnapshot = function(player)
			pushes[player.UserId] = (pushes[player.UserId] or 0) + 1
		end,
	}
	local fakeData = {
		GetData = function(p)
			return profiles[p]
		end,
		-- Как настоящий DataSystem: опрос до загрузки профиля, выхода игрока или таймаута.
		WaitForData = function(p, timeout)
			local deadline = world.Now + (timeout or 60)
			while not profiles[p] and p.Parent ~= nil and world.Now < deadline do
				world.Task.wait(0.1)
			end
			return profiles[p]
		end,
		BuildDefaultProfile = dataSystem.BuildDefaultProfile,
	}
	local function remote(name: string)
		return {
			OnServerEvent = {
				Connect = function(_self, fn)
					handlers[name] = fn
				end,
			},
			FireClient = function() end,
		}
	end
	local fakeRemotes = {
		RequestRaidStart = remote("RequestRaidStart"),
		HatchCocoon = remote("HatchCocoon"),
		EquipPet = remote("EquipPet"),
		UnequipPet = remote("UnequipPet"),
		PetSnapshot = remote("PetSnapshot"),
	}

	local function patched(path: string, patch: { [string]: any }?)
		local config = world:LoadModule(path)
		if patch then
			config = table.clone(config)
			for key, value in patch do
				config[key] = value
			end
		end
		return config
	end
	local pvpConfig = patched("src/shared/Config/PvPConfig", patches and patches.PvP)
	local guardConfig = patched("src/shared/Config/GuardConfig", patches and patches.Guard)

	local pets = world:LoadModule("src/server/Systems/PetSystem", {
		["src/server/Systems/DataSystem"] = fakeData,
		["src/shared/Remotes"] = fakeRemotes,
	})
	local system = world:LoadModule("src/server/Systems/PvPRaidSystem", {
		["src/server/Systems/DataSystem"] = fakeData,
		["src/server/Systems/FactorySystem"] = fakeFactory,
		["src/server/Systems/PetSystem"] = pets,
		["src/shared/Remotes"] = fakeRemotes,
		["src/shared/Config/PvPConfig"] = pvpConfig,
		["src/shared/Config/GuardConfig"] = guardConfig,
	})
	system.Init()

	local completed = {}
	system.OnRaidCompleted:Connect(function(attacker, target, stolen)
		table.insert(completed, { Attacker = attacker.UserId, Target = target.UserId, Stolen = stolen })
	end)

	local t = {
		World = world,
		System = system,
		Pets = pets,
		Config = pvpConfig,
		Guard = guardConfig,
		Profiles = profiles,
		Pushes = pushes,
		Completed = completed,
		Handlers = handlers,
	}

	-- Игрок заходит на сервер с профилем (Essence = essence) и без щита входа — щит
	-- проверяется отдельными тестами (keepShield = true оставляет выставленный при входе).
	function t.Join(userId: number, essence: number?, keepShield: boolean?)
		local player = world:NewPlayer(userId)
		local data = dataSystem.BuildDefaultProfile()
		data.Currency.Essence = essence or 10_000
		profiles[player] = data
		table.insert(world.Players, player)
		world:FirePlayerAdded(player)
		if not keepShield then
			data.PvP.ShieldExpiresAt = nil
		end
		return player, data
	end

	-- Персонаж player в offset studs (по X) от рейд-инстанса цели targetId.
	function t.PlaceAt(player, targetId: number, offset: number?)
		local center = assert(system.GetRaidInstancePosition(targetId), `нет рейд-инстанса у {targetId}`)
		local shift = center - center
		shift.X = offset or 0
		local root = {
			Position = center + shift,
			IsA = function(_self, name)
				return name == "BasePart"
			end,
		}
		local humanoid = { Health = 100 }
		player.Character = {
			FindFirstChildOfClass = function(_self, className)
				return if className == "Humanoid" then humanoid else nil
			end,
			FindFirstChild = function(_self, name)
				return if name == "HumanoidRootPart" then root else nil
			end,
		}
	end

	function t.Raid(attacker, targetId: any, ...)
		handlers.RequestRaidStart(attacker, targetId, ...)
	end

	-- Встать у цели и атаковать; пропускает окно rate limit, чтобы тесты про кулдауны
	-- проверяли именно кулдауны.
	function t.RaidAt(attacker, targetId: number, ...)
		world:Advance(pvpConfig.RequestWindow + 0.01)
		t.PlaceAt(attacker, targetId)
		t.Raid(attacker, targetId, ...)
	end

	function t.Leave(player)
		world:FirePlayerRemoving(player)
		player.Parent = nil
		local index = table.find(world.Players, player)
		if index then
			table.remove(world.Players, index)
		end
		profiles[player] = nil
	end

	function t.RaidParts()
		local list = {}
		for _, instance in world.Instances do
			if instance.ClassName == "Part" and not instance.Destroyed then
				table.insert(list, instance)
			end
		end
		return list
	end

	return t
end

local function expectedStolen(t, essence: number, defense: number): number
	return math.floor(math.min(essence * t.Config.StealPercent, t.Config.HardCap) * (1 - defense))
end

local function near(a: number, b: number): boolean
	return math.abs(a - b) < 1e-9
end

------------------------------------------------------------------------------------------
-- Сумма кражи
------------------------------------------------------------------------------------------

test("Кража = StealPercent от Essence цели, если это меньше HardCap", function()
	local t = setup()
	local attacker, a = t.Join(1, 100)
	local _, d = t.Join(2, 10_000)
	assert(10_000 * t.Config.StealPercent < t.Config.HardCap, "предпосылка теста")

	t.RaidAt(attacker, 2)
	local stolen = expectedStolen(t, 10_000, 0)
	assert(stolen > 0)
	assert(d.Currency.Essence == 10_000 - stolen, `цель: {d.Currency.Essence}`)
	assert(a.Currency.Essence == 100 + stolen, `атакующий: {a.Currency.Essence}`)
	assert(#t.Completed == 1 and t.Completed[1].Stolen == stolen)
end)

test("Кража упирается в HardCap, если StealPercent больше", function()
	local t = setup()
	local attacker, a = t.Join(1, 0)
	local big = t.Config.HardCap * 100
	local _, d = t.Join(2, big)
	assert(big * t.Config.StealPercent > t.Config.HardCap, "предпосылка теста")

	t.RaidAt(attacker, 2)
	assert(a.Currency.Essence == t.Config.HardCap, `украдено {a.Currency.Essence}`)
	assert(d.Currency.Essence == big - t.Config.HardCap)
end)

test("Essence сохраняется: сколько ушло у цели, столько пришло атакующему", function()
	local t = setup()
	local attacker, a = t.Join(1, 1234.5)
	local _, d = t.Join(2, 7777.25)
	local before = a.Currency.Essence + d.Currency.Essence
	t.RaidAt(attacker, 2)
	assert(#t.Completed == 1)
	assert(near(a.Currency.Essence + d.Currency.Essence, before), "сумма не изменилась")
	assert(t.Completed[1].Stolen % 1 == 0, "украдено целое")
end)

test("Пустая цель: nothing-to-steal, состояние не меняется", function()
	local t = setup()
	local attacker = t.Join(1, 50)
	local _, d = t.Join(2, 0)
	t.RaidAt(attacker, 2)
	assert(#t.Completed == 0)
	assert(d.PvP.LastRaidedAt == nil, "grace не выставлен")

	-- Кулдаун пары тоже не записан: пополнившуюся цель можно атаковать сразу.
	d.Currency.Essence = 10_000
	t.RaidAt(attacker, 2)
	assert(#t.Completed == 1)
end)

------------------------------------------------------------------------------------------
-- Щит, grace, кулдаун пары
------------------------------------------------------------------------------------------

test("Щит при входе выставляется и блокирует рейд до истечения", function()
	local t = setup()
	local attacker = t.Join(1, 0)
	local _, d = t.Join(2, 10_000, true)
	local now = 1_000_000 + math.floor(t.World.Now)
	assert(d.PvP.ShieldExpiresAt == now + t.Config.ShieldDuration, `щит {d.PvP.ShieldExpiresAt}`)

	t.RaidAt(attacker, 2)
	assert(#t.Completed == 0, "под щитом рейд отклонён")
	assert(d.Currency.Essence == 10_000)

	t.World:Advance(t.Config.ShieldDuration)
	t.RaidAt(attacker, 2)
	assert(#t.Completed == 1, "после щита рейд проходит")
end)

test("Щит входа не укорачивает более длинный уже выставленный щит", function()
	local t = setup()
	local world = t.World
	local _, dataSystem = world:NewServer()
	local player = world:NewPlayer(5)
	local data = dataSystem.BuildDefaultProfile()
	local long = 1_000_000 + 10 * t.Config.ShieldDuration
	data.PvP.ShieldExpiresAt = long
	t.Profiles[player] = data
	table.insert(world.Players, player)
	world:FirePlayerAdded(player)
	assert(data.PvP.ShieldExpiresAt == long)
end)

test("Успешный рейд снимает щит атакующего", function()
	local t = setup()
	local attacker, a = t.Join(1, 0, true)
	t.Join(2, 10_000)
	assert(a.PvP.ShieldExpiresAt ~= nil, "щит входа у атакующего")
	t.RaidAt(attacker, 2)
	assert(#t.Completed == 1)
	assert(a.PvP.ShieldExpiresAt == nil, "щит снят")
end)

test("Отказанный рейд щит атакующего не трогает", function()
	local t = setup()
	local attacker, a = t.Join(1, 0, true)
	t.Join(2, 10_000, true)
	local shield = a.PvP.ShieldExpiresAt
	t.RaidAt(attacker, 2)
	assert(#t.Completed == 0 and a.PvP.ShieldExpiresAt == shield)
end)

test("Профиль грузится дольше 60 с — щит и рейд-инстанс всё равно появляются", function()
	local t = setup()
	local world = t.World
	local _, dataSystem = world:NewServer()
	local player = world:NewPlayer(7)
	table.insert(world.Players, player)
	world:FirePlayerAdded(player)
	world:Advance(120)
	assert(t.System.GetRaidInstancePosition(7) == nil, "профиля ещё нет")

	local data = dataSystem.BuildDefaultProfile()
	t.Profiles[player] = data
	world:Advance(0.2)
	assert(t.System.GetRaidInstancePosition(7) ~= nil, "инстанс создан после загрузки")
	assert(data.PvP.ShieldExpiresAt ~= nil, "щит выставлен")
end)

test("Grace после рейда блокирует повторный рейд другого атакующего", function()
	local t = setup()
	local first = t.Join(1, 0)
	local second, s = t.Join(3, 0)
	local _, d = t.Join(2, 10_000)

	t.RaidAt(first, 2)
	assert(#t.Completed == 1)
	assert(d.PvP.LastRaidedAt == 1_000_000 + math.floor(t.World.Now), "LastRaidedAt записан")
	local afterFirst = d.Currency.Essence

	t.RaidAt(second, 2)
	assert(#t.Completed == 1, "второй атакующий впритык отклонён")
	assert(d.Currency.Essence == afterFirst and s.Currency.Essence == 0)

	t.World:Advance(t.Config.RaidedGraceDuration)
	t.RaidAt(second, 2)
	assert(#t.Completed == 2, "после grace — можно")
end)

test("Кулдаун пары: та же цель блокирована, другая — нет", function()
	local t = setup()
	local c = t.Config
	assert(c.RaidedGraceDuration < c.AttackCooldownPerTarget, "предпосылка теста")
	local attacker = t.Join(1, 0)
	local other = t.Join(4, 0)
	t.Join(2, 10_000)
	t.Join(3, 10_000)

	t.RaidAt(attacker, 2)
	assert(#t.Completed == 1)
	-- Grace цели прошёл, кулдаун пары 1→2 — нет.
	t.World:Advance(c.RaidedGraceDuration)
	t.RaidAt(attacker, 2)
	assert(#t.Completed == 1, "та же цель — кулдаун")

	t.RaidAt(attacker, 3)
	assert(#t.Completed == 2 and t.Completed[2].Target == 3, "другая цель не блокируется")

	t.RaidAt(other, 2)
	assert(#t.Completed == 3 and t.Completed[3].Attacker == 4, "другой атакующий этой цели не на кулдауне")

	t.World:Advance(c.AttackCooldownPerTarget)
	t.RaidAt(attacker, 2)
	assert(#t.Completed == 4, "после кулдауна пары — можно")
end)

test("Кулдаун пары переживает реджойн атакующего на этот же сервер", function()
	local t = setup()
	local attacker = t.Join(1, 0)
	t.Join(2, 10_000)
	t.RaidAt(attacker, 2)
	assert(#t.Completed == 1)
	t.Leave(attacker)

	t.World:Advance(t.Config.RaidedGraceDuration)
	local again = t.Join(1, 0)
	t.RaidAt(again, 2)
	assert(#t.Completed == 1, "реджойн не сбрасывает кулдаун пары")
end)

------------------------------------------------------------------------------------------
-- Защита: стражи и Fearful-петы цели
------------------------------------------------------------------------------------------

test("Стражи снижают кражу по формуле GuardConfig", function()
	local t = setup()
	local g = t.Guard
	local attacker, a = t.Join(1, 0)
	local _, d = t.Join(2, 10_000)
	d.PvP.GuardsPlaced = { "SleepyWisp", "NightWarden" }
	local defense = g.Types.SleepyWisp.Defense + g.Types.NightWarden.Defense
	assert(near(t.System.ComputeDefense(d.PvP.GuardsPlaced, 0), defense))

	t.RaidAt(attacker, 2)
	local stolen = expectedStolen(t, 10_000, defense)
	assert(stolen < expectedStolen(t, 10_000, 0), "защита снижает")
	assert(a.Currency.Essence == stolen, `украдено {a.Currency.Essence}, ожидалось {stolen}`)
end)

test("Стражи: неизвестные id — 0, сверх MaxGuards не считаются, потолок MaxReduction", function()
	local t = setup({ Guard = { MaxGuards = 2 } })
	local g = t.Guard
	local ComputeDefense = t.System.ComputeDefense
	assert(near(ComputeDefense({ "Bogus", "LullabyTurret" }, 0), g.Types.LullabyTurret.Defense), "неизвестный id")
	assert(near(ComputeDefense({ 5 :: any, "LullabyTurret" }, 0), g.Types.LullabyTurret.Defense), "не строка")
	assert(
		near(ComputeDefense({ "SleepyWisp", "SleepyWisp", "NightWarden" }, 0), 2 * g.Types.SleepyWisp.Defense),
		"третий сверх MaxGuards не считается"
	)
	assert(ComputeDefense({}, 1e9) == g.MaxReduction, "потолок")
	assert(ComputeDefense({}, 0 / 0) == 0, "NaN от петов игнорируется")
end)

test("Fearful-петы ЦЕЛИ снижают кражу в той же формуле защиты", function()
	local t = setup()
	local attacker, a = t.Join(1, 0)
	local target, d = t.Join(2, 10_000)
	table.insert(d.Pets, {
		Id = "p1",
		SpeciesId = "CloudFox",
		Rarity = "Legendary",
		Level = 1,
		Equipped = true,
	})
	d.PvP.GuardsPlaced = { "SleepyWisp" }
	t.Pets.RefreshBonuses(target)
	local fearful = t.Pets.GetCachedBonuses(target).FearfulDefense
	assert(fearful > 0, "кэш PetSystem видит Fearful")

	t.RaidAt(attacker, 2)
	local defense = t.Guard.Types.SleepyWisp.Defense + fearful * t.Guard.FearfulPetDefenseScale
	local stolen = expectedStolen(t, 10_000, defense)
	assert(stolen < expectedStolen(t, 10_000, t.Guard.Types.SleepyWisp.Defense), "пет добавляет защиту")
	assert(a.Currency.Essence == stolen, `украдено {a.Currency.Essence}, ожидалось {stolen}`)
end)

test("Fearful-петы атакующего кражу не меняют", function()
	local t = setup()
	local attacker, a = t.Join(1, 0)
	t.Join(2, 10_000)
	table.insert(a.Pets, {
		Id = "p1",
		SpeciesId = "CloudFox",
		Rarity = "Secret",
		Level = 1,
		Equipped = true,
	})
	t.Pets.RefreshBonuses(attacker)
	t.RaidAt(attacker, 2)
	assert(a.Currency.Essence == expectedStolen(t, 10_000, 0))
end)

test("Не надетый Fearful-пет цели защиты не даёт", function()
	local t = setup()
	local target, d = t.Join(2, 10_000)
	table.insert(d.Pets, { Id = "p1", SpeciesId = "CloudFox", Rarity = "Epic", Level = 1, Equipped = false })
	t.Pets.RefreshBonuses(target)
	assert(t.Pets.GetCachedBonuses(target).FearfulDefense == 0)
end)

------------------------------------------------------------------------------------------
-- Повторы, выход цели, битые профили, аргументы клиента
------------------------------------------------------------------------------------------

test("Двойная доставка запроса не удваивает кражу", function()
	local t = setup()
	local attacker, a = t.Join(1, 0)
	local _, d = t.Join(2, 10_000)
	t.PlaceAt(attacker, 2)
	t.Raid(attacker, 2)
	t.Raid(attacker, 2) -- тот же кадр, в пределах rate limit
	local stolen = expectedStolen(t, 10_000, 0)
	assert(#t.Completed == 1, `рейдов {#t.Completed}`)
	assert(a.Currency.Essence == stolen and d.Currency.Essence == 10_000 - stolen)
end)

test("Цель вышла до обработки запроса — отказ без ошибки и без изменений", function()
	local t = setup()
	local attacker, a = t.Join(1, 0)
	local target = t.Join(2, 10_000)
	t.PlaceAt(attacker, 2)
	t.Leave(target)
	t.Raid(attacker, 2)
	assert(#t.Completed == 0)
	assert(a.Currency.Essence == 0)
	assert(t.System.GetRaidInstancePosition(2) == nil, "инстанс цели удалён")
end)

test("Цель ещё на сервере, но профиль уже освобождён — отказ", function()
	local t = setup()
	local attacker, a = t.Join(1, 0)
	local target = t.Join(2, 10_000)
	t.PlaceAt(attacker, 2)
	t.Profiles[target] = nil -- DataSystem снял профиль (PlayerRemoving в процессе)
	t.Raid(attacker, 2)
	assert(#t.Completed == 0 and a.Currency.Essence == 0)
end)

test("Битый профиль атакующего не роняет обработчик и не трогает цель", function()
	local t = setup()
	local attacker, a = t.Join(1, 0)
	local other, o = t.Join(3, 0)
	local _, d = t.Join(2, 10_000)
	a.Currency = "garbage" :: any

	t.RaidAt(attacker, 2)
	assert(#t.Completed == 0)
	assert(d.Currency.Essence == 10_000 and d.PvP.LastRaidedAt == nil, "цель не тронута")

	t.RaidAt(other, 2)
	assert(#t.Completed == 1, "другой атакующий работает")
	assert(o.Currency.Essence > 0)
end)

test("Битый профиль цели — отказ, остальные цели доступны", function()
	local cases = {
		function(d)
			d.PvP.GuardsPlaced = "x"
		end,
		function(d)
			d.PvP = nil
		end,
		function(d)
			d.PvP.ShieldExpiresAt = "soon"
		end,
		function(d)
			d.PvP.LastRaidedAt = 0 / 0
		end,
		function(d)
			d.Currency.Essence = 0 / 0
		end,
		function(d)
			d.Currency.Essence = -5
		end,
	}
	for i, corrupt in cases do
		local t = setup()
		local attacker, a = t.Join(1, 0)
		local _, bad = t.Join(2, 10_000)
		local _, good = t.Join(3, 10_000)
		corrupt(bad)

		t.RaidAt(attacker, 2)
		assert(#t.Completed == 0, `случай {i}: битая цель отклонена`)
		assert(a.Currency.Essence == 0, `случай {i}: атакующему ничего`)

		t.RaidAt(attacker, 3)
		assert(#t.Completed == 1, `случай {i}: здоровая цель доступна`)
		assert(good.Currency.Essence < 10_000)
	end
end)

test("Ошибка внутри транзакции (Currency цели — не таблица) не роняет обработчик", function()
	local t = setup()
	local attacker, a = t.Join(1, 0)
	local _, d = t.Join(2, 10_000)
	d.Currency = setmetatable({}, {
		__index = function()
			error("boom")
		end,
	}) :: any
	t.RaidAt(attacker, 2)
	assert(#t.Completed == 0 and a.Currency.Essence == 0)
end)

test("Аргументы клиента сверх UserId (сумма, защита) игнорируются", function()
	local t = setup()
	local attacker, a = t.Join(1, 0)
	t.Join(2, 10_000)
	t.RaidAt(attacker, 2, 1e12, { Stolen = 1e12, Defense = -5 })
	assert(a.Currency.Essence == expectedStolen(t, 10_000, 0))
end)

test("Некорректный targetUserId и рейд на себя отклоняются", function()
	local t = setup()
	local attacker, a = t.Join(1, 10_000)
	t.Join(2, 10_000)
	t.PlaceAt(attacker, 2)
	for _, bad in { "2", {}, 0 / 0, 2.5, -2, 0, math.huge, nil :: any, true } do
		t.World:Advance(t.Config.RequestWindow + 0.01)
		t.Raid(attacker, bad)
	end
	t.World:Advance(t.Config.RequestWindow + 0.01)
	t.PlaceAt(attacker, 1)
	t.Raid(attacker, 1)
	assert(#t.Completed == 0)
	assert(a.Currency.Essence == 10_000)
end)

test("Рейд на игрока, которого нет на сервере, отклоняется", function()
	local t = setup()
	local attacker, a = t.Join(1, 0)
	t.Join(2, 10_000)
	t.PlaceAt(attacker, 2)
	t.Raid(attacker, 999)
	assert(#t.Completed == 0 and a.Currency.Essence == 0)
end)

------------------------------------------------------------------------------------------
-- Дистанция, rate limit, снимки, рейд-инстансы
------------------------------------------------------------------------------------------

test("Атакующий должен стоять у рейд-инстанса цели", function()
	local t = setup()
	local c = t.Config
	local attacker = t.Join(1, 0)
	t.Join(2, 10_000)
	t.Join(3, 10_000)

	t.PlaceAt(attacker, 2, c.RaidRange + c.DistanceTolerance + 1)
	t.Raid(attacker, 2)
	assert(#t.Completed == 0, "слишком далеко")

	-- Стоя у инстанса другой цели, атаковать эту нельзя.
	t.World:Advance(c.RequestWindow + 0.01)
	t.PlaceAt(attacker, 3)
	t.Raid(attacker, 2)
	assert(#t.Completed == 0, "у чужого инстанса")

	t.World:Advance(c.RequestWindow + 0.01)
	attacker.Character = nil
	t.Raid(attacker, 2)
	assert(#t.Completed == 0, "без персонажа")

	t.World:Advance(c.RequestWindow + 0.01)
	t.PlaceAt(attacker, 2, c.RaidRange + c.DistanceTolerance - 0.5)
	t.Raid(attacker, 2)
	assert(#t.Completed == 1, "в пределах допуска")
end)

test("Rate limit: лишние запросы в окне отбрасываются до транзакции", function()
	local t = setup({ PvP = { MaxRequestsPerWindow = 1 } })
	local attacker = t.Join(1, 0)
	t.Join(2, 10_000)
	t.Join(3, 10_000)
	t.PlaceAt(attacker, 2, 1000) -- первый запрос отклонён дистанцией, но съел окно
	t.Raid(attacker, 2)
	t.PlaceAt(attacker, 2)
	t.Raid(attacker, 2)
	assert(#t.Completed == 0, "второй запрос в окне отброшен")
	t.World:Advance(t.Config.RequestWindow + 0.01)
	t.Raid(attacker, 2)
	assert(#t.Completed == 1)
end)

test("После рейда снимок экономики уходит обоим, отказ — без снимков", function()
	local t = setup()
	local attacker = t.Join(1, 0)
	t.Join(2, 10_000, true) -- под щитом
	t.RaidAt(attacker, 2)
	assert(t.Pushes[1] == nil and t.Pushes[2] == nil, "на отказ снимков нет")

	t.World:Advance(t.Config.ShieldDuration)
	t.RaidAt(attacker, 2)
	assert(t.Pushes[1] == 1 and t.Pushes[2] == 1, `снимки: {t.Pushes[1]}/{t.Pushes[2]}`)
end)

test("Рейд-инстанс создаётся на входе, удаляется на выходе, слот переиспользуется", function()
	local t = setup()
	local c = t.Config
	local p1 = t.Join(1)
	t.Join(2)
	assert(#t.RaidParts() == 2)
	local pos1 = t.System.GetRaidInstancePosition(1)
	local pos2 = t.System.GetRaidInstancePosition(2)
	assert(near((pos2 - pos1).Magnitude, c.RaidInstanceSpacing), "соседние слоты")

	t.Leave(p1)
	assert(#t.RaidParts() == 1)
	t.Join(3)
	local pos3 = t.System.GetRaidInstancePosition(3)
	assert(near((pos3 - pos1).Magnitude, 0), "освободившийся слот занят снова")
end)

------------------------------------------------------------------------------------------
-- Конфиги
------------------------------------------------------------------------------------------

local function expectLoadFailure(path: string, name: string, cases: { { string } })
	local world = Harness.NewWorld()
	local fs = require("@lune/fs")
	local luau = require("@lune/luau")
	local original = fs.readFile(path .. ".luau")
	for _, case in cases do
		local from, to = case[1], case[2]
		assert(string.find(original, from, 1, true), `в {name} есть «{from}»`)
		local patchedSource = string.gsub(original, string.gsub(from, "%p", "%%%0"), to)
		local env = world:_makeEnv({}, path)
		local ok, err = pcall(function()
			luau.load(patchedSource, { debugName = name, environment = env })()
		end)
		assert(not ok and string.find(tostring(err), name, 1, true), `«{to}» должен ронять загрузку, получено {err}`)
	end
end

test("PvPConfig: некорректные значения роняют загрузку", function()
	expectLoadFailure("src/shared/Config/PvPConfig", "PvPConfig", {
		{ "StealPercent = 0.15", "StealPercent = 1.5" },
		{ "StealPercent = 0.15", "StealPercent = 0" },
		{ "HardCap = 5_000", "HardCap = 0/0" },
		{ "AttackCooldownPerTarget = 600", "AttackCooldownPerTarget = 0" },
		{ "RaidedGraceDuration = 120", "RaidedGraceDuration = -1" },
		{ "RaidInstanceSpacing = 80", "RaidInstanceSpacing = 10" },
	})
end)

test("GuardConfig: некорректные значения роняют загрузку", function()
	expectLoadFailure("src/shared/Config/GuardConfig", "GuardConfig", {
		{ "MaxReduction = 0.6", "MaxReduction = 1" },
		{ "Defense = 0.15", "Defense = 0.9" },
		{ "Defense = 0.05", "Defense = -0.05" },
		{ "FearfulPetDefenseScale = 0.5", "FearfulPetDefenseScale = 0/0" },
	})
end)

------------------------------------------------------------------------------------------
-- Аналитика (S18)
------------------------------------------------------------------------------------------

test("PvP-атака: событие PvPRaid атакующему с украденной суммой; отказ — без события", function()
	local t = setup()
	local attacker = t.Join(1, 100)
	t.Join(2, 10_000)
	t.Join(3, 0)
	t.RaidAt(attacker, 3) -- nothing-to-steal
	assert(#t.World.AnalyticsEvents == 0, "отказ не логируется")

	t.RaidAt(attacker, 2)
	local stolen = t.Completed[1].Stolen
	local raids = {}
	for _, event in t.World.AnalyticsEvents do
		if event.Kind == "Custom" and event.Name == "PvPRaid" then
			table.insert(raids, event)
		end
	end
	assert(#raids == 1 and raids[1].Player == attacker and raids[1].Value == stolen)
end)

------------------------------------------------------------------------------------------
-- Кумулятивный лимит потерь цели (S19)
------------------------------------------------------------------------------------------

-- Цель с большим балансом: каждый рейд без защиты упирается в HardCap (5 000).
local CAP_PATCH = { PvP = { MaxStolenPerTargetWindow = 12_000, StolenWindowDuration = 1_800 } }

-- Пропустить grace-окно цели после прошлого рейда (оно от любого атакующего).
local function afterGrace(t)
	t.World:Advance(t.Config.RaidedGraceDuration + 1)
end

test("Лимит окна: три разных атакующих подряд не уносят больше MaxStolenPerTargetWindow", function()
	local t = setup(CAP_PATCH)
	local _, d = t.Join(9, 100_000)
	local attackers = {}
	for id = 1, 4 do
		attackers[id] = t.Join(id, 0)
	end
	for id = 1, 4 do
		afterGrace(t)
		t.RaidAt(attackers[id], 9)
	end
	local stolen = {}
	for _, raid in t.Completed do
		table.insert(stolen, raid.Stolen)
	end
	assert(table.concat(stolen, ",") == "5000,5000,2000", `кражи: {table.concat(stolen, ",")}`)
	assert(d.Currency.Essence == 100_000 - 12_000 and d.PvP.StolenInWindow == 12_000)
	assert(#t.World.Warnings == 0, "отказ по лимиту — не подозрительная активность")
end)

test("Частичный остаток лимита урезает кражу, а не блокирует рейд", function()
	local t = setup({ PvP = { MaxStolenPerTargetWindow = 7_000 } })
	local a1 = t.Join(1, 0)
	local a2, a = t.Join(2, 0)
	local _, d = t.Join(9, 100_000)
	t.RaidAt(a1, 9)
	afterGrace(t)
	t.RaidAt(a2, 9)
	assert(#t.Completed == 2 and t.Completed[2].Stolen == 2_000, "второй рейд урезан до остатка")
	assert(a.Currency.Essence == 2_000 and d.Currency.Essence == 93_000)
end)

test("Окно лимита истекает: после StolenWindowDuration цель снова можно грабить на полный лимит", function()
	local t = setup(CAP_PATCH)
	local _, d = t.Join(9, 100_000)
	for id = 1, 3 do
		afterGrace(t)
		t.RaidAt(t.Join(id, 0), 9)
	end
	local start = d.PvP.StolenWindowStartsAt
	assert(d.PvP.StolenInWindow == 12_000 and type(start) == "number")
	afterGrace(t)
	local late = t.Join(4, 0)
	t.RaidAt(late, 9)
	assert(#t.Completed == 3, "лимит исчерпан — отказ")

	t.World:Advance(t.Config.StolenWindowDuration)
	t.RaidAt(late, 9)
	assert(#t.Completed == 4 and t.Completed[4].Stolen == 5_000, "новое окно")
	assert(d.PvP.StolenInWindow == 5_000 and d.PvP.StolenWindowStartsAt > start)
end)

test("Лимит — у цели, а не у пары: смена цели атакующим не обходит и не тратит чужой лимит", function()
	local t = setup({ PvP = { MaxStolenPerTargetWindow = 6_000 } })
	local a1 = t.Join(1, 0)
	local a2 = t.Join(2, 0)
	local _, x = t.Join(8, 100_000)
	local _, y = t.Join(9, 100_000)
	t.RaidAt(a1, 9) -- 5 000 из лимита Y
	t.RaidAt(a1, 8) -- другая цель: полный рейд, лимит Y не трогается
	assert(x.PvP.StolenInWindow == 5_000 and y.PvP.StolenInWindow == 5_000)
	afterGrace(t)
	t.RaidAt(a2, 9) -- другой атакующий на Y: только остаток лимита Y
	assert(t.Completed[3].Target == 9 and t.Completed[3].Stolen == 1_000)
	assert(y.PvP.StolenInWindow == 6_000 and y.Currency.Essence == 94_000)
end)

test("Битые StolenInWindow / StolenWindowStartsAt — отказ, цель не тронута", function()
	for _, corrupt in {
		function(pvp)
			pvp.StolenInWindow = "много"
		end,
		function(pvp)
			pvp.StolenInWindow = 0 / 0
		end,
		function(pvp)
			pvp.StolenInWindow = -1
		end,
		function(pvp)
			pvp.StolenInWindow = nil
		end,
		function(pvp)
			pvp.StolenWindowStartsAt = "вчера"
		end,
		function(pvp)
			pvp.StolenWindowStartsAt = math.huge
		end,
		function(pvp)
			pvp.EssenceAtWindowStart = "много"
		end,
		function(pvp)
			pvp.EssenceAtWindowStart = -5
		end,
	} do
		local t = setup()
		local attacker = t.Join(1, 0)
		local _, d = t.Join(9, 100_000)
		corrupt(d.PvP)
		t.RaidAt(attacker, 9)
		assert(#t.Completed == 0 and d.Currency.Essence == 100_000, "рейд отклонён")
	end
end)

test("Профиль v7 мигрирует в v8: StolenInWindow = 0, окна ещё не было", function()
	local world = Harness.NewWorld()
	local _, dataSystem = world:NewServer()
	assert(dataSystem.CURRENT_SCHEMA_VERSION >= 8)
	local v7 = { Meta = { SchemaVersion = 7 }, PvP = { LastRaidedAt = 5, GuardsPlaced = { "Sentinel" } } }
	local migrated = assert(dataSystem.MigrateProfileData(v7))
	assert(migrated.Meta.SchemaVersion == dataSystem.CURRENT_SCHEMA_VERSION)
	assert(migrated.PvP.StolenInWindow == 0 and migrated.PvP.StolenWindowStartsAt == nil)
	assert(migrated.PvP.LastRaidedAt == 5 and migrated.PvP.GuardsPlaced[1] == "Sentinel")
end)

------------------------------------------------------------------------------------------
-- Относительный лимит потерь цели (S19)
------------------------------------------------------------------------------------------

-- Рой: count разных атакующих по очереди грабят цель targetId (с паузой на grace цели).
local function swarm(t, targetId: number, count: number, firstId: number?)
	for i = 1, count do
		afterGrace(t)
		t.RaidAt(t.Join((firstId or 100) + i, 0), targetId)
	end
end

test("Бедная цель: относительный лимит останавливает рой атакующих задолго до нуля", function()
	local t = setup()
	local start = 2_000
	assert(start < t.Config.MaxStolenPerTargetWindow, "предпосылка: абсолютный лимит для неё не срабатывает")
	local _, d = t.Join(9, start)
	swarm(t, 9, 10)
	local cap = math.floor(start * t.Config.MaxStolenPercentPerTargetWindow)
	assert(d.PvP.StolenInWindow == cap, `унесено {d.PvP.StolenInWindow}, лимит {cap}`)
	assert(d.Currency.Essence == start - cap, `баланс {d.Currency.Essence}`)
	assert(#t.Completed < 10, "остальные атакующие получили отказ")
	assert(d.PvP.EssenceAtWindowStart == start)
end)

test("Богатая цель: действует абсолютный лимит, как раньше", function()
	local t = setup()
	local start = 200_000
	local relative = start * t.Config.MaxStolenPercentPerTargetWindow
	assert(relative > t.Config.MaxStolenPerTargetWindow, "предпосылка: относительный лимит мягче")
	local _, d = t.Join(9, start)
	swarm(t, 9, 6)
	assert(d.PvP.StolenInWindow == t.Config.MaxStolenPerTargetWindow)
	assert(d.Currency.Essence == start - t.Config.MaxStolenPerTargetWindow)
end)

test("EssenceAtWindowStart фиксируется на старте окна и не меняется внутри него", function()
	local t = setup()
	local _, d = t.Join(9, 2_000)
	swarm(t, 9, 1)
	local first = t.Completed[1].Stolen
	assert(d.PvP.EssenceAtWindowStart == 2_000, "баланс ДО кражи открывшего окно рейда")
	local cap = math.floor(2_000 * t.Config.MaxStolenPercentPerTargetWindow)

	-- Внутри окна баланс вырос (переработка, покупка) — база лимита прежняя.
	d.Currency.Essence = 50_000
	swarm(t, 9, 1, 200)
	assert(d.PvP.EssenceAtWindowStart == 2_000)
	assert(t.Completed[2].Stolen == cap - first, "урезано по базе окна, а не по новому балансу")
	assert(d.PvP.StolenInWindow == cap)

	-- Баланс упал — база тоже не меняется, лимит исчерпан.
	d.Currency.Essence = 1_000
	swarm(t, 9, 1, 300)
	assert(#t.Completed == 2 and d.PvP.EssenceAtWindowStart == 2_000)

	-- Новое окно берёт текущий баланс.
	t.World:Advance(t.Config.StolenWindowDuration)
	d.Currency.Essence = 40_000
	swarm(t, 9, 1, 400)
	assert(#t.Completed == 3 and d.PvP.EssenceAtWindowStart == 40_000, "ротация окна обновила базу")
	assert(d.PvP.StolenInWindow == t.Completed[3].Stolen)
end)

test("Профиль v8 мигрирует в v9: EssenceAtWindowStart = 0, остальное PvP не тронуто", function()
	local world = Harness.NewWorld()
	local _, dataSystem = world:NewServer()
	assert(dataSystem.CURRENT_SCHEMA_VERSION == 9)
	local v8 = {
		Meta = { SchemaVersion = 8 },
		PvP = { StolenInWindow = 700, StolenWindowStartsAt = 123, GuardsPlaced = {} },
	}
	local migrated = assert(dataSystem.MigrateProfileData(v8))
	assert(migrated.Meta.SchemaVersion == 9)
	assert(migrated.PvP.EssenceAtWindowStart == 0)
	assert(migrated.PvP.StolenInWindow == 700 and migrated.PvP.StolenWindowStartsAt == 123)
end)

test("PvPConfig: MaxStolenPercentPerTargetWindow вне (0, 1] роняет загрузку", function()
	for _, bad in { "0", "1.5", "-0.1", "0 / 0" } do
		local world = Harness.NewWorld()
		world.SourcePatches["src/shared/Config/PvPConfig"] = function(source)
			local patched = string.gsub(source, "MaxStolenPercentPerTargetWindow = [%d%.]+,", `MaxStolenPercentPerTargetWindow = {bad},`)
			return patched
		end
		local ok, err = pcall(world.LoadModule, world, "src/shared/Config/PvPConfig")
		assert(not ok and string.find(tostring(err), "MaxStolenPercentPerTargetWindow", 1, true), `значение {bad}: {err}`)
	end
end)

return tests
