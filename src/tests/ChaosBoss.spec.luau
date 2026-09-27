--[[
	Тесты Хаос-босса (ChaosBossSystem): шкала от Fearful/Joyful, спавн по порогу, серверная
	валидация RequestAttackBoss (дистанция, кулдаун, двойная доставка), общий пул HP без
	перебора урона добивающим, вклад по UserId при выходе игрока, награда по вкладу
	(победа/таймаут), изоляция битых профилей и load-time проверки ChaosBossConfig.

	Запуск: lune run src/tests/run (из корня репозитория).
]]

local Harness = require("./lib/Harness")

type Test = { Name: string, Run: () -> () }

local tests: { Test } = {}

local function test(name: string, run: () -> ())
	table.insert(tests, { Name = name, Run = run })
end

-- ChaosBossSystem в изоляции: FactorySystem подменён (настоящий Signal OnEssenceProduced +
-- счётчик PushSnapshot), DataSystem — профили в памяти, ремоута — перехват обработчика.
-- configPatch — поля ChaosBossConfig, подменяемые для теста (без load-time проверок).
local function setup(configPatch: { [string]: any }?, beforeInit: ((world: any) -> ())?)
	local world = Harness.NewWorld()
	local _, dataSystem = world:NewServer()
	local profiles = {}
	local handlers = {}
	local pushes = {}

	local signalModule = world:LoadModule("src/shared/Signal")
	local fakeFactory = {
		OnEssenceProduced = signalModule.new(),
		PushSnapshot = function(player)
			pushes[player.UserId] = (pushes[player.UserId] or 0) + 1
		end,
	}
	local fakeData = {
		GetData = function(p)
			return profiles[p]
		end,
		WaitForData = function(p)
			return profiles[p]
		end,
		BuildDefaultProfile = dataSystem.BuildDefaultProfile,
	}
	-- Отправленные ChaosSnapshot: { Player, Snapshot, At } в порядке отправки.
	local sent = {}
	local fakeRemotes = {
		ChaosSnapshot = {
			OnServerEvent = {
				Connect = function(_self, fn)
					handlers.ChaosSnapshot = fn
				end,
			},
			FireClient = function(_self, player, snapshot)
				table.insert(sent, { Player = player, Snapshot = snapshot, At = world.Now })
			end,
		},
		RequestAttackBoss = {
			OnServerEvent = {
				Connect = function(_self, fn)
					handlers.RequestAttackBoss = fn
				end,
			},
			FireClient = function() end,
		},
	}

	local config = world:LoadModule("src/shared/Config/ChaosBossConfig")
	if configPatch then
		config = table.clone(config)
		for key, value in configPatch do
			config[key] = value
		end
	end

	local system = world:LoadModule("src/server/Systems/ChaosBossSystem", {
		["src/server/Systems/FactorySystem"] = fakeFactory,
		["src/server/Systems/DataSystem"] = fakeData,
		["src/shared/Remotes"] = fakeRemotes,
		["src/shared/Config/ChaosBossConfig"] = config,
	})
	if beforeInit then
		beforeInit(world)
	end
	system.Init()

	local ended = {}
	system.OnEventEnded:Connect(function(id, outcome, rewards)
		table.insert(ended, { Id = id, Outcome = outcome, Rewards = rewards })
	end)

	local t = {
		Sent = sent,
		Handlers = handlers,
		Profiles = profiles,
		World = world,
		System = system,
		Config = config,
		Factory = fakeFactory,
		Pushes = pushes,
		Ended = ended,
	}

	-- Игрок с дефолтным профилем и персонажем в distance studs от центра босса.
	function t.AddPlayer(userId: number, distance: number?)
		local player = world:NewPlayer(userId)
		local data = dataSystem.BuildDefaultProfile()
		profiles[player] = data
		table.insert(world.Players, player)
		t.Place(player, distance or 0)
		return player, data
	end

	function t.Place(player, distance: number)
		local offset = config.BossPosition - config.BossPosition
		offset.X = distance
		local root = {
			Position = config.BossPosition + offset,
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

	-- Выход с сервера: как Players после PlayerRemoving (Parent = nil, нет в GetPlayers).
	function t.Leave(player)
		world:FirePlayerRemoving(player)
		player.Parent = nil
		local index = table.find(world.Players, player)
		if index then
			table.remove(world.Players, index)
		end
	end

	-- Снимки, отправленные игроку (по UserId и, если передан, конкретному Player).
	function t.SentTo(userId: number, player: any?)
		local list = {}
		for _, entry in sent do
			if entry.Player.UserId == userId and (player == nil or entry.Player == player) then
				table.insert(list, entry.Snapshot)
			end
		end
		return list
	end

	function t.LastTo(userId: number, player: any?)
		local list = t.SentTo(userId, player)
		return list[#list]
	end

	function t.ClearSent()
		table.clear(sent)
	end

	-- Вход игрока на сервер (PlayerAdded) после Init.
	function t.Join(userId: number)
		local player = world:NewPlayer(userId)
		table.insert(world.Players, player)
		world:FirePlayerAdded(player)
		return player
	end

	function t.Produce(emotion: string, count: number?)
		for _ = 1, count or 1 do
			fakeFactory.OnEssenceProduced:Fire({ UserId = 0 }, 1, emotion)
		end
	end

	-- Довести шкалу до порога — старт ивента.
	function t.StartEvent()
		t.Produce("Fearful", math.ceil(config.ActivationThreshold / config.FearfulGainPerEvent))
		assert(system.GetState().Active, "ивент стартовал")
	end

	function t.Attack(player)
		handlers.RequestAttackBoss(player)
	end

	function t.AttackWithArgs(player, ...)
		handlers.RequestAttackBoss(player, ...)
	end

	-- Пропустить кулдаун удара.
	function t.Cooldown()
		world:Advance(config.AttackCooldown + 0.01)
	end

	function t.BossParts()
		local list = {}
		for _, instance in world.Instances do
			if instance.Name == "ChaosBoss" and not instance.Destroyed then
				table.insert(list, instance)
			end
		end
		return list
	end

	return t
end

local function near(a: number, b: number): boolean
	return math.abs(a - b) < 1e-9
end

------------------------------------------------------------------------------------------
-- Шкала Хаоса
------------------------------------------------------------------------------------------

test("Fearful поднимает шкалу, Joyful немного опускает, Nostalgic не влияет", function()
	local t = setup()
	local c = t.Config
	t.Produce("Fearful", 3)
	assert(near(t.System.GetState().ChaosLevel, 3 * c.FearfulGainPerEvent), "рост от Fearful")
	t.Produce("Joyful")
	assert(near(t.System.GetState().ChaosLevel, 3 * c.FearfulGainPerEvent - c.JoyfulDecayPerEvent), "спад от Joyful")
	t.Produce("Nostalgic", 5)
	assert(near(t.System.GetState().ChaosLevel, 3 * c.FearfulGainPerEvent - c.JoyfulDecayPerEvent), "Nostalgic нейтрален")
	assert(c.JoyfulDecayPerEvent < c.FearfulGainPerEvent, "спад меньше роста")
end)

test("Joyful не уводит шкалу ниже нуля; мусорный emotionType игнорируется", function()
	local t = setup()
	t.Produce("Joyful", 10)
	assert(t.System.GetState().ChaosLevel == 0, "пол — 0")
	t.Factory.OnEssenceProduced:Fire({ UserId = 0 }, 1, nil)
	t.Factory.OnEssenceProduced:Fire({ UserId = 0 }, 1, 5)
	assert(t.System.GetState().ChaosLevel == 0 and not t.System.GetState().Active)
end)

test("При достижении порога спавнится босс с полным HP", function()
	local t = setup()
	local c = t.Config
	local needed = math.ceil(c.ActivationThreshold / c.FearfulGainPerEvent)
	t.Produce("Fearful", needed - 1)
	assert(not t.System.GetState().Active, "до порога — нет ивента")
	assert(#t.BossParts() == 0)

	t.Produce("Fearful")
	local state = t.System.GetState()
	assert(state.Active, "ивент активен")
	assert(state.BossHealth == c.BossMaxHealth, "полное HP")
	local parts = t.BossParts()
	assert(#parts == 1, `один босс, найдено {#parts}`)
	assert(parts[1].Anchored and parts[1]:GetAttribute("Health") == c.BossMaxHealth)
end)

test("Во время боя шкала заморожена, второй босс не спавнится", function()
	local t = setup()
	t.StartEvent()
	local level = t.System.GetState().ChaosLevel
	t.Produce("Fearful", 1000)
	t.Produce("Joyful", 3)
	assert(t.System.GetState().ChaosLevel == level, "шкала не меняется")
	assert(#t.BossParts() == 1, "босс один")
end)

------------------------------------------------------------------------------------------
-- Валидация удара
------------------------------------------------------------------------------------------

test("Удар без активного ивента отклоняется", function()
	local t = setup()
	local p = t.AddPlayer(1)
	t.Attack(p)
	assert(t.System.GetContribution(1) == 0)
	assert(t.System.GetState().BossHealth == 0)
end)

test("Удар засчитывается: урон из конфига, вклад по UserId", function()
	local t = setup()
	local p = t.AddPlayer(1, 5)
	t.StartEvent()
	t.Attack(p)
	local c = t.Config
	assert(t.System.GetState().BossHealth == c.BossMaxHealth - c.DamagePerHit, "HP уменьшилось на DamagePerHit")
	assert(t.System.GetContribution(1) == c.DamagePerHit)
	assert(t.BossParts()[1]:GetAttribute("Health") == c.BossMaxHealth - c.DamagePerHit, "атрибут обновлён")
end)

test("Удар мимо дистанции отклоняется без урона", function()
	local t = setup()
	local c = t.Config
	local far = t.AddPlayer(1, c.AttackRange + c.DistanceTolerance + 1)
	local noChar = t.AddPlayer(2)
	noChar.Character = nil
	t.StartEvent()
	t.Attack(far)
	t.Attack(noChar)
	assert(t.System.GetState().BossHealth == c.BossMaxHealth, "урона нет")
	assert(t.System.GetContribution(1) == 0 and t.System.GetContribution(2) == 0)

	-- На границе (с допуском) — засчитывается.
	t.Place(far, c.AttackRange + c.DistanceTolerance)
	t.Attack(far)
	assert(t.System.GetContribution(1) == c.DamagePerHit, "на границе допуска удар проходит")
end)

test("Удар на кулдауне отклоняется без урона, после кулдауна — проходит", function()
	local t = setup()
	local c = t.Config
	local p = t.AddPlayer(1)
	t.StartEvent()
	t.Attack(p)
	t.World:Advance(c.AttackCooldown / 2)
	t.Attack(p)
	assert(t.System.GetContribution(1) == c.DamagePerHit, "второй удар внутри кулдауна не засчитан")
	t.Cooldown()
	t.Attack(p)
	assert(t.System.GetContribution(1) == 2 * c.DamagePerHit, "после кулдауна засчитан")
end)

test("Двойная доставка RequestAttackBoss не удваивает урон одного удара", function()
	local t = setup()
	local c = t.Config
	local p = t.AddPlayer(1)
	t.StartEvent()
	t.Attack(p)
	t.Attack(p) -- тот же момент времени: двойной клик / повтор пакета
	assert(t.System.GetState().BossHealth == c.BossMaxHealth - c.DamagePerHit)
	assert(t.System.GetContribution(1) == c.DamagePerHit)
end)

test("Аргументы клиента игнорируются: урон всегда из конфига", function()
	local t = setup()
	local c = t.Config
	local p = t.AddPlayer(1)
	t.StartEvent()
	-- Модифицированный клиент шлёт «урон» и мусор — обработчик их не читает.
	t.AttackWithArgs(p, 1e9, "kill", { Damage = 1e9 })
	assert(t.System.GetContribution(1) == c.DamagePerHit, "урон не от клиента")
end)

test("Спам запросов упирается в rate limit и пишет подозрительную активность", function()
	local t = setup()
	local c = t.Config
	local p = t.AddPlayer(1)
	t.StartEvent()
	for _ = 1, c.SuspiciousRejectThreshold + c.MaxRequestsPerWindow do
		t.Attack(p)
	end
	assert(t.System.GetContribution(1) == c.DamagePerHit, "засчитан один удар")
	local logged = false
	for _, message in t.World.Warnings do
		if string.find(message, "Подозрительная активность", 1, true) then
			logged = true
		end
	end
	assert(logged, "спам записан в лог")
end)

test("Честный клик чаще кулдауна не пишет подозрительную активность", function()
	local t = setup()
	local c = t.Config
	local p = t.AddPlayer(1)
	t.StartEvent()
	-- 4 клика/с (в пределах rate limit) при кулдауне 0.5 с — половина отклоняется по кулдауну.
	for _ = 1, 4 * 60 do
		t.Attack(p)
		t.World:Advance(0.25)
		if not t.System.GetState().Active then
			break
		end
	end
	assert(c.MaxRequestsPerWindow >= 4, "4 клика/с не упираются в rate limit")
	for _, message in t.World.Warnings do
		assert(not string.find(message, "Подозрительная активность", 1, true), `ложное срабатывание: {message}`)
	end
end)

test("Удар игрока без загруженного профиля отклоняется и не съедает HP", function()
	local t = setup()
	local c = t.Config
	local p = t.AddPlayer(1)
	t.Profiles[p] = nil -- профиль ещё грузится / потерян лок
	t.StartEvent()
	t.Attack(p)
	assert(t.System.GetState().BossHealth == c.BossMaxHealth, "HP не тронуто")
	assert(t.System.GetContribution(1) == 0)
end)

------------------------------------------------------------------------------------------
-- Общий пул HP и завершение победой
------------------------------------------------------------------------------------------

test("Параллельные удары суммируются; добивающий не получает урон сверх остатка HP", function()
	local t = setup({ BossMaxHealth = 25, DamagePerHit = 10 })
	local a, dataA = t.AddPlayer(1)
	local b, dataB = t.AddPlayer(2)
	local essenceA, essenceB = dataA.Currency.Essence, dataB.Currency.Essence
	t.StartEvent()

	t.Attack(a)
	t.Attack(b) -- тот же момент
	assert(t.System.GetState().BossHealth == 5, "HP 25 - 10 - 10")

	t.Cooldown()
	t.Attack(b) -- добивает остаток 5
	t.Attack(a) -- в тот же момент, босса уже нет

	local state = t.System.GetState()
	assert(not state.Active, "победа")
	assert(state.BossHealth == 0, "HP не ниже нуля")
	assert(#t.Ended == 1 and t.Ended[1].Outcome == "Victory")
	local rewards = t.Ended[1].Rewards
	local c = t.Config
	local rate = c.RewardEssencePerDamage * c.VictoryRewardMultiplier
	assert(near(rewards[1], 10 * rate), `вклад A = 10, награда {rewards[1]}`)
	assert(near(rewards[2], 15 * rate), `вклад B = 10 + 5 (не 20), награда {rewards[2]}`)
	assert(near(dataA.Currency.Essence, essenceA + 10 * rate), "Essence A начислена")
	assert(near(dataB.Currency.Essence, essenceB + 15 * rate), "Essence B начислена")
	assert(t.Pushes[1] == 1 and t.Pushes[2] == 1, "снимок экономики отправлен")
end)

test("После победы состояние сброшено: шкала 0, вклад очищен, босс убран", function()
	local t = setup({ BossMaxHealth = 10, DamagePerHit = 10 })
	local p = t.AddPlayer(1)
	t.StartEvent()
	t.Attack(p)
	local state = t.System.GetState()
	assert(not state.Active and state.ChaosLevel == 0 and state.BossHealth == 0)
	assert(t.System.GetContribution(1) == 0, "вклад очищен")
	assert(#t.BossParts() == 0, "босс уничтожен")

	-- Шкала снова растёт с нуля.
	t.Produce("Fearful")
	assert(near(t.System.GetState().ChaosLevel, t.Config.FearfulGainPerEvent))
end)

------------------------------------------------------------------------------------------
-- Таймаут
------------------------------------------------------------------------------------------

test("Таймаут без победы раздаёт награду по вкладу (без победного множителя)", function()
	local t = setup()
	local c = t.Config
	local a, dataA = t.AddPlayer(1)
	local b, dataB = t.AddPlayer(2)
	local _idle, dataIdle = t.AddPlayer(3)
	local essenceA, essenceB, essenceIdle = dataA.Currency.Essence, dataB.Currency.Essence, dataIdle.Currency.Essence
	t.StartEvent()
	t.Attack(a)
	t.Attack(b)
	t.Cooldown()
	t.Attack(b)

	t.World:Advance(c.EventDuration)
	assert(not t.System.GetState().Active, "ивент завершён таймаутом")
	assert(#t.Ended == 1 and t.Ended[1].Outcome == "Timeout")
	assert(near(dataA.Currency.Essence, essenceA + c.DamagePerHit * c.RewardEssencePerDamage))
	assert(near(dataB.Currency.Essence, essenceB + 2 * c.DamagePerHit * c.RewardEssencePerDamage))
	assert(dataIdle.Currency.Essence == essenceIdle, "не бил — ничего не получил")
	assert(t.Ended[1].Rewards[3] == nil)
	assert(#t.BossParts() == 0 and t.System.GetState().ChaosLevel == 0)
end)

test("Таймер прошлого ивента не завершает следующий", function()
	local t = setup({ BossMaxHealth = 10, DamagePerHit = 10 })
	local c = t.Config
	local p = t.AddPlayer(1)
	t.StartEvent()
	t.Attack(p) -- победа сразу
	t.World:Advance(c.EventDuration / 2)
	t.StartEvent() -- второй ивент
	local secondId = t.System.GetState().EventId
	t.World:Advance(c.EventDuration / 2 + 0.01) -- сработал таймер первого
	assert(t.System.GetState().Active and t.System.GetState().EventId == secondId, "второй ивент жив")
	t.World:Advance(c.EventDuration / 2)
	assert(not t.System.GetState().Active, "второй завершился своим таймером")
	assert(#t.Ended == 2 and t.Ended[2].Outcome == "Timeout")
end)

------------------------------------------------------------------------------------------
-- Выход игроков и битые профили
------------------------------------------------------------------------------------------

test("Выход посреди боя: бой идёт дальше, вклад вышедшего учтён в HP, но награды нет", function()
	local t = setup({ BossMaxHealth = 30, DamagePerHit = 10 })
	local leaver, leaverData = t.AddPlayer(1)
	local stayer, stayerData = t.AddPlayer(2)
	local leaverEssence, stayerEssence = leaverData.Currency.Essence, stayerData.Currency.Essence
	t.StartEvent()

	t.Attack(leaver)
	t.Leave(leaver)
	assert(t.System.GetContribution(1) == 10, "вклад вышедшего сохранён до завершения")
	t.Attack(leaver) -- запоздалый запрос после выхода
	assert(t.System.GetContribution(1) == 10, "после выхода урон не засчитывается")

	t.Attack(stayer)
	t.Cooldown()
	t.Attack(stayer) -- добивает: 10 (вышедший) + 20 = 30
	assert(not t.System.GetState().Active, "победа с учётом вклада вышедшего")

	local rewards = t.Ended[1].Rewards
	assert(rewards[1] == nil, "вышедший награду не получил")
	assert(leaverData.Currency.Essence == leaverEssence, "его профиль не тронут")
	local c = t.Config
	assert(near(stayerData.Currency.Essence, stayerEssence + 20 * c.RewardEssencePerDamage * c.VictoryRewardMultiplier))
	assert(t.System.GetContribution(1) == 0, "вклад очищен после завершения")
end)

test("Битый профиль одного участника не ломает выдачу остальным", function()
	local t = setup()
	local c = t.Config
	local broken, brokenData = t.AddPlayer(1)
	local healthy, healthyData = t.AddPlayer(2)
	local healthyEssence = healthyData.Currency.Essence
	t.StartEvent()
	t.Attack(broken)
	t.Attack(healthy)
	;(brokenData :: any).Currency = 5

	t.World:Advance(c.EventDuration)
	assert(not t.System.GetState().Active, "ивент завершён")
	assert(near(healthyData.Currency.Essence, healthyEssence + c.DamagePerHit * c.RewardEssencePerDamage))
	assert(t.Ended[1].Rewards[1] == nil and t.Ended[1].Rewards[2] ~= nil)
	local logged = false
	for _, message in t.World.Warnings do
		if string.find(message, "Не удалось выдать награду", 1, true) then
			logged = true
		end
	end
	assert(logged, "ошибка записана в лог")
end)

test("Ошибка снимка после записи награды не прячет выданную награду", function()
	local t = setup()
	local c = t.Config
	local p, data = t.AddPlayer(1)
	local essence = data.Currency.Essence
	t.Factory.PushSnapshot = function()
		error("битый раздел профиля")
	end
	t.StartEvent()
	t.Attack(p)
	t.World:Advance(c.EventDuration)
	local expected = c.DamagePerHit * c.RewardEssencePerDamage
	assert(near(data.Currency.Essence, essence + expected), "награда записана один раз")
	assert(near(t.Ended[1].Rewards[1], expected), "и отражена в rewards")
end)

test("Реджойн до завершения: вклад по UserId, награду получает новый Player", function()
	local t = setup()
	local c = t.Config
	local first = t.AddPlayer(1)
	t.StartEvent()
	t.Attack(first)
	t.Leave(first)
	local _second, data = t.AddPlayer(1)
	local essence = data.Currency.Essence
	t.World:Advance(c.EventDuration)
	assert(near(data.Currency.Essence, essence + c.DamagePerHit * c.RewardEssencePerDamage))
end)

------------------------------------------------------------------------------------------
-- Рассылка ChaosSnapshot
------------------------------------------------------------------------------------------

test("Старт ивента рассылается всем сразу: общее состояние + личный вклад 0", function()
	local t = setup()
	local c = t.Config
	t.AddPlayer(1)
	t.AddPlayer(2)
	t.StartEvent()
	for _, userId in { 1, 2 } do
		local snap = t.LastTo(userId)
		assert(snap, `игрок {userId} получил снимок`)
		assert(snap.Active == true and snap.BossHealth == c.BossMaxHealth and snap.BossMaxHealth == c.BossMaxHealth)
		assert(snap.ActivationThreshold == c.ActivationThreshold and snap.EventId == 1)
		assert(snap.Contribution == 0 and snap.Ended == nil)
	end
end)

test("Каждый игрок получает свой Contribution, а не чужой", function()
	local t = setup()
	local c = t.Config
	local a = t.AddPlayer(1)
	t.AddPlayer(2)
	t.StartEvent()
	t.World:Advance(c.SnapshotInterval) -- интервал после рассылки старта прошёл: удар шлётся сразу
	t.Attack(a)
	assert(t.LastTo(1).Contribution == c.DamagePerHit, "свой вклад")
	assert(t.LastTo(2).Contribution == 0, "у второго — его собственный (0)")
	assert(t.LastTo(2).BossHealth == c.BossMaxHealth - c.DamagePerHit, "общее HP одинаковое")
end)

test("HP: пачка ударов внутри интервала — одна отложенная рассылка с итоговым HP", function()
	local t = setup()
	local c = t.Config
	local players = {}
	for userId = 1, 5 do
		players[userId] = t.AddPlayer(userId)
	end
	t.StartEvent()
	t.ClearSent()

	-- Удары сразу после старта (внутри интервала): ни один не шлётся немедленно.
	for _, p in players do
		t.Attack(p)
	end
	assert(#t.Sent == 0, `внутри интервала ничего не отправлено, отправлено {#t.Sent}`)

	t.World:Advance(c.SnapshotInterval + 0.01)
	assert(#t.SentTo(1) == 1, `одна отложенная рассылка, получено {#t.SentTo(1)}`)
	assert(t.LastTo(1).BossHealth == c.BossMaxHealth - 5 * c.DamagePerHit, "в ней — итоговое HP")
	assert(#t.Sent == 5, "по одному снимку на игрока")

	-- Долгая серия ударов: соседние рассылки не ближе интервала, последнее HP доходит.
	t.ClearSent()
	for _ = 1, 10 do
		t.Cooldown()
		for _, p in players do
			t.Attack(p)
		end
	end
	t.World:Advance(c.SnapshotInterval + 0.01)
	local times = {}
	for _, entry in t.Sent do
		if entry.Player.UserId == 1 then
			table.insert(times, entry.At)
		end
	end
	assert(#times >= 2, "серия ударов разослана")
	assert(#times <= 11, `рассылок {#times} при 10 окнах кулдауна — не на каждый удар`)
	for i = 2, #times do
		assert(times[i] - times[i - 1] >= c.SnapshotInterval - 1e-9, `интервал {times[i] - times[i - 1]}`)
	end
	assert(t.LastTo(1).BossHealth == t.System.GetState().BossHealth, "последнее HP дошло")
end)

test("Шкала Хаоса рассылается с тем же throttle (для индикатора HUD)", function()
	local t = setup()
	local c = t.Config
	t.AddPlayer(1)
	t.Produce("Fearful", 10)
	assert(#t.SentTo(1) == 1, "первое изменение — сразу, остальные ждут")
	t.World:Advance(c.SnapshotInterval + 0.01)
	assert(#t.SentTo(1) == 2, `отложенная рассылка, всего {#t.SentTo(1)}`)
	assert(near(t.LastTo(1).ChaosLevel, 10 * c.FearfulGainPerEvent), "итоговая шкала")
	assert(t.LastTo(1).Active == false)

	-- Без изменений (Nostalgic) — ничего не шлётся.
	t.ClearSent()
	t.Produce("Nostalgic", 3)
	t.World:Advance(c.SnapshotInterval * 2)
	assert(#t.Sent == 0)
end)

test("Конец ивента: награда участникам, 0 — неучаствовавшему, вышедшему — ничего", function()
	local t = setup({ BossMaxHealth = 20, DamagePerHit = 10 })
	local c = t.Config
	local a = t.AddPlayer(1)
	t.AddPlayer(2) -- не бьёт
	local leaver = t.AddPlayer(3)
	t.StartEvent()
	t.Attack(leaver)
	t.Leave(leaver)
	t.ClearSent()
	t.Attack(a) -- добивает

	local rate = c.RewardEssencePerDamage * c.VictoryRewardMultiplier
	local endA = t.LastTo(1)
	assert(endA and endA.Ended, "участник получил снимок завершения сразу")
	assert(endA.Active == false and endA.BossHealth == 0 and endA.ChaosLevel == 0)
	assert(endA.Ended.Outcome == "Victory" and endA.Ended.EventId == 1)
	assert(endA.Ended.Damage == 10 and near(endA.Ended.Reward, 10 * rate))
	assert(endA.Contribution == 0, "текущий вклад сброшен вместе с ивентом")

	local endB = t.LastTo(2)
	assert(endB.Ended and endB.Ended.Reward == 0 and endB.Ended.Damage == 0, "не участвовал — 0")
	assert(#t.SentTo(3) == 0, "вышедшему ничего не отправлено")

	-- Отложенных рассылок после завершения нет (актуальное состояние уже отправлено).
	local before = #t.Sent
	t.World:Advance(c.SnapshotInterval * 2)
	assert(#t.Sent == before, "лишних рассылок нет")
end)

test("Победа внутри интервала throttle: отложенная рассылка после снимка завершения не уходит", function()
	local t = setup({ BossMaxHealth = 30, DamagePerHit = 10 })
	local c = t.Config
	local a = t.AddPlayer(1)
	local b = t.AddPlayer(2)
	local killer = t.AddPlayer(3)
	t.StartEvent()
	t.World:Advance(c.SnapshotInterval)
	t.Attack(a) -- сразу (интервал прошёл)
	t.Attack(b) -- внутри интервала: запланирована отложенная рассылка
	t.World:Advance(c.SnapshotInterval / 2)
	assert(t.LastTo(1).BossHealth == 20, "отложенная ещё не ушла")
	t.Attack(killer) -- добивает внутри интервала: снимок завершения раньше отложенной
	assert(t.LastTo(1).Ended, "снимок завершения ушёл")
	local count = #t.SentTo(1)
	t.World:Advance(c.SnapshotInterval * 3)
	assert(#t.SentTo(1) == count, "отложенная рассылка после завершения ничего не отправила")
end)

test("Конец по таймауту рассылается с Outcome = Timeout и наградой", function()
	local t = setup()
	local c = t.Config
	local a = t.AddPlayer(1)
	t.StartEvent()
	t.Attack(a)
	t.World:Advance(c.EventDuration)
	local snap = t.LastTo(1)
	assert(snap.Ended and snap.Ended.Outcome == "Timeout")
	assert(near(snap.Ended.Reward, c.DamagePerHit * c.RewardEssencePerDamage))
end)

test("Вошедший посреди боя сразу получает актуальное состояние и ровно один повтор", function()
	local t = setup()
	local c = t.Config
	local a = t.AddPlayer(1)
	t.StartEvent()
	t.Attack(a)

	t.Join(7)
	local first = t.SentTo(7)
	assert(#first == 1, "снимок сразу при входе")
	assert(first[1].Active and first[1].BossHealth == c.BossMaxHealth - c.DamagePerHit, "актуальное HP")

	-- Повтор собирается заново и видит изменения после входа.
	t.Cooldown()
	t.Attack(a)
	t.World:Advance(c.InitialSnapshotResendDelay)
	assert(t.LastTo(7).BossHealth == c.BossMaxHealth - 2 * c.DamagePerHit, "повтор с актуальным HP")

	t.ClearSent()
	t.World:Advance(c.InitialSnapshotResendDelay * 3)
	assert(#t.SentTo(7) == 0, "повтор один, не цикл")
end)

test("Реджойн до конца ивента: новый Player сразу видит свой прежний вклад", function()
	local t = setup()
	local c = t.Config
	local first = t.AddPlayer(1)
	t.StartEvent()
	t.Attack(first)
	t.Leave(first)

	local again = t.Join(1)
	local snap = t.LastTo(1, again)
	assert(snap and snap.Contribution == c.DamagePerHit, "вклад по UserId")
	assert(snap.Active)
end)

test("Вышедший до повтора первого снимка повтор не получает", function()
	local t = setup()
	local c = t.Config
	local p = t.Join(5)
	assert(#t.SentTo(5) == 1)
	t.Leave(p)
	t.World:Advance(c.InitialSnapshotResendDelay + 0.01)
	assert(#t.SentTo(5) == 1, "после выхода не шлём")
end)

test("Игроки, бывшие на сервере до Init, получают начальный снимок", function()
	local t = setup(nil, function(world)
		table.insert(world.Players, world:NewPlayer(9))
	end)
	assert(#t.SentTo(9) == 1, "снимок при Init")
	t.World:Advance(t.Config.InitialSnapshotResendDelay + 0.01)
	assert(#t.SentTo(9) == 2, "и повтор")
end)

test("FireServer на ChaosSnapshot логируется один раз и ничего не меняет", function()
	local t = setup()
	local p = t.AddPlayer(1)
	t.Handlers.ChaosSnapshot(p, { Active = true })
	t.Handlers.ChaosSnapshot(p, { Active = true })
	local count = 0
	for _, message in t.World.Warnings do
		if string.find(message, "серверный вход ChaosSnapshot", 1, true) then
			count += 1
		end
	end
	assert(count == 1, `записей {count}`)
	assert(not t.System.GetState().Active)
end)

------------------------------------------------------------------------------------------
-- Конфиг
------------------------------------------------------------------------------------------

test("ChaosBossConfig: некорректные значения роняют загрузку", function()
	local world = Harness.NewWorld()
	local source = world:LoadModule("src/shared/Config/ChaosBossConfig")
	assert(source.ActivationThreshold > 0)

	-- Load-time assert проверяем, подменив исходник конфига.
	local cases = {
		{ "ActivationThreshold = 500", "ActivationThreshold = 0" },
		{ "AttackCooldown = 0.5", "AttackCooldown = 0" },
		{ "JoyfulDecayPerEvent = 0.25", "JoyfulDecayPerEvent = 2" },
		{ "DamagePerHit = 10", "DamagePerHit = 0/0" },
		{ "VictoryRewardMultiplier = 1.5", "VictoryRewardMultiplier = 0.5" },
	}
	local fs = require("@lune/fs")
	local luau = require("@lune/luau")
	local original = fs.readFile("src/shared/Config/ChaosBossConfig.luau")
	for _, case in cases do
		local from, to = case[1], case[2]
		assert(string.find(original, from, 1, true), `в конфиге есть «{from}»`)
		local patched = string.gsub(original, string.gsub(from, "%p", "%%%0"), to)
		local env = world:_makeEnv({}, "src/shared/Config/ChaosBossConfig")
		local ok, err = pcall(function()
			luau.load(patched, { debugName = "ChaosBossConfig", environment = env })()
		end)
		assert(not ok and string.find(tostring(err), "ChaosBossConfig", 1, true), `«{to}» должен ронять загрузку, получено {err}`)
	end
end)

------------------------------------------------------------------------------------------
-- Аналитика и сигнал удара (S18)
------------------------------------------------------------------------------------------

local function customEvents(world, name: string)
	local list = {}
	for _, event in world.AnalyticsEvents do
		if event.Kind == "Custom" and event.Name == name then
			table.insert(list, event)
		end
	end
	return list
end

test("Участие в Хаос-ивенте: ChaosEventJoined один раз на игрока за ивент; OnBossHit на каждый удар", function()
	local t = setup()
	local p1 = t.AddPlayer(1, 5)
	local p2 = t.AddPlayer(2, 5)
	local hits = {}
	t.System.OnBossHit:Connect(function(player, dealt, id)
		table.insert(hits, { Player = player, Dealt = dealt, EventId = id })
	end)
	t.StartEvent()
	local eventId = t.System.GetState().EventId

	t.Attack(p1)
	t.Attack(p1) -- кулдаун: не засчитан
	t.Cooldown()
	t.Attack(p1)
	t.Attack(p2)
	local joined = customEvents(t.World, "ChaosEventJoined")
	assert(#joined == 2, `событий участия {#joined}`)
	assert(joined[1].Player == p1 and joined[1].Value == eventId and joined[2].Player == p2)
	assert(#hits == 3, `засчитанных ударов {#hits}`)
	assert(hits[1].Player == p1 and hits[1].Dealt == t.Config.DamagePerHit and hits[1].EventId == eventId)
end)

return tests
