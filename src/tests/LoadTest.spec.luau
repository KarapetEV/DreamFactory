--[[
	Синтетический scale-тест (S19, чек-лист раздела 12 ТЗ — «нагрузочный тест»).

	Честно о границах: lune — не движок Roblox. FPS, сетевой лаг, физику, частицы и реальную
	нагрузку на DataStore этот тест не измеряет. Он проверяет то, что можно headless:
	- все серверные системы (Data, Collection, Factory, Pet, Rebirth, ChaosBoss, PvPRaid,
	  BattlePass, Monetization) подняты вместе, как в init.server, с общим кэшем модулей;
	- PLAYERS фейковых игроков одновременно проходят полный цикл: сбор → конвейер → апгрейд →
	  PvP-рейд → удар по Хаос-боссу → вылупление → XP пропуска → rebirth — без ошибок и
	  предупреждений, за разумное реальное время;
	- после выхода всех игроков ни один модуль не держит ссылку на Player (сквозная проверка
	  утечек по всем per-player таблицам сразу): объекты игроков собираются GC.

	Запуск: lune run src/tests/run (из корня репозитория).
]]

local Harness = require("./lib/Harness")

type Test = { Name: string, Run: () -> () }

local tests: { Test } = {}

local function test(name: string, run: () -> ())
	table.insert(tests, { Name = name, Run = run })
end

local PLAYERS = 120
-- Потолок реального времени прогона (с большим запасом: цель — поймать деградацию
-- вроде O(n²) по игрокам, а не мерить производительность).
local MAX_REAL_SECONDS = 60

local SYSTEMS = {
	"DataSystem",
	"CollectionSystem",
	"FactorySystem",
	"PetSystem",
	"RebirthSystem",
	"ChaosBossSystem",
	"PvPRaidSystem",
	"BattlePassSystem",
	"MonetizationSystem",
}

local REMOTE_NAMES = {
	"RequestCollect",
	"PurchaseUpgrade",
	"EconomySnapshot",
	"HatchCocoon",
	"EquipPet",
	"UnequipPet",
	"PetSnapshot",
	"PerformRebirth",
	"RequestAttackBoss",
	"ChaosSnapshot",
	"RequestRaidStart",
}

-- Персонаж-заглушка с перемещаемым корнем (серверные проверки дистанции читают root.Position).
local function giveCharacter(world, player)
	local root = {
		Position = world.Vector3(0, 0, 0),
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
	return root
end

local function buildServer(world)
	local handlers = {}
	local fired = 0
	local fakeRemotes = {}
	for _, name in REMOTE_NAMES do
		fakeRemotes[name] = {
			OnServerEvent = {
				Connect = function(_self, fn)
					handlers[name] = fn
				end,
			},
			-- Счётчик, а не список: тест утечек не должен сам держать ссылки на Player.
			FireClient = function()
				fired += 1
			end,
		}
	end

	-- Босс с HP ровно на удар каждого игрока: ивент заканчивается победой на последнем ударе.
	local chaosConfig = table.clone(world:LoadModule("src/shared/Config/ChaosBossConfig"))
	chaosConfig.BossMaxHealth = PLAYERS * chaosConfig.DamagePerHit

	local load = world:ModuleLoader({
		["src/shared/Remotes"] = fakeRemotes,
		["src/shared/Config/ChaosBossConfig"] = chaosConfig,
	})
	local systems = {}
	for _, name in SYSTEMS do
		systems[name] = load(`src/server/Systems/{name}`)
	end
	world:Spawn(function()
		for _, name in SYSTEMS do
			systems[name].Init()
		end
	end)
	world:Advance(1)
	return systems, handlers, chaosConfig, function()
		return fired
	end
end

test(`Scale: {PLAYERS} игроков проходят полный цикл всех систем без ошибок, без утечек Player`, function()
	local startedAt = os.clock()
	local world = Harness.NewWorld()
	local systems, handlers, chaosConfig, firedCount = buildServer(world)
	local S = systems
	-- При Init системы честно предупреждают о заглушках id (GamePassId/ProductId = 0) — это
	-- ожидаемо; дальше новых предупреждений быть не должно.
	local initWarnings = #world.Warnings
	local function newWarning(): string?
		return world.Warnings[initWarnings + 1]
	end

	-- Vector3 модулей: берём готовый объект из конфига и строим от него (та же метатаблица).
	local origin = world:LoadModule("src/shared/Config/PvPConfig").RaidInstanceOrigin
	local function at(position)
		return origin - origin + position
	end
	world.Vector3 = function(x, y, z)
		local v = origin - origin
		v.X, v.Y, v.Z = x, y, z
		return v
	end

	-- Вход игроков.
	local players, roots = {}, {}
	for id = 1, PLAYERS do
		local player = world:NewPlayer(id)
		player.Name = `LoadPlayer{id}`
		players[id] = player
		roots[id] = giveCharacter(world, player)
		table.insert(world.Players, player)
		world:FirePlayerAdded(player)
	end
	world:Advance(5)
	local data = {}
	for id, player in players do
		data[id] = assert(S.DataSystem.GetData(player), `профиль игрока {id} загружен`)
		data[id].PvP.ShieldExpiresAt = nil -- щит входа мешал бы рейду
	end

	-- 1. Сбор: фрагменты общие и спавнятся порциями — игроки разбирают их по мере появления.
	local collected = 0
	for _ = 1, 200 do
		if collected == PLAYERS then
			break
		end
		for id, player in players do
			if data[id].Meta.FirstCollectAt == nil then
				for _, part in world.Instances do
					if part.ClassName == "Part" and part:GetAttribute("FragmentId") and not part.Destroyed then
						roots[id].Position = at(part.Position)
						handlers.RequestCollect(player, part:GetAttribute("FragmentId"))
						if data[id].Meta.FirstCollectAt then
							collected += 1
						end
						break
					end
				end
			end
		end
		world:Advance(3)
	end
	assert(collected == PLAYERS, `собрали {collected} из {PLAYERS}`)

	-- 2. Конвейер: собранное перерабатывается.
	world:Advance(30)
	for id in players do
		assert(data[id].Meta.FirstProcessAt, `игрок {id}: конвейер не отработал`)
	end

	-- 3. Апгрейд (Essence — как у прокачанного игрока; цены берёт сервер).
	local upgradeId = next(world:LoadModule("src/shared/Config/UpgradeConfig"))
	for id, player in players do
		data[id].Currency.Essence = 1_000_000
		handlers.PurchaseUpgrade(player, upgradeId, 1)
	end
	world:Advance(2)

	-- 4. PvP: каждый грабит следующего по кругу.
	for id, player in players do
		local targetId = id % PLAYERS + 1
		roots[id].Position = at(assert(S.PvPRaidSystem.GetRaidInstancePosition(targetId)))
		handlers.RequestRaidStart(player, targetId)
	end
	world:Advance(2)

	-- 5. Хаос: шкалу накачивают события конвейера (Fearful), затем каждый бьёт босса один раз.
	local pump = world:NewPlayer(0) -- «игрок» без профиля: XP пропуска не получает
	for _ = 1, math.ceil(chaosConfig.ActivationThreshold / chaosConfig.FearfulGainPerEvent) do
		S.FactorySystem.OnEssenceProduced:Fire(pump, 1, "Fearful")
	end
	assert(S.ChaosBossSystem.GetState().Active, "Хаос-ивент стартовал")
	for id, player in players do
		roots[id].Position = at(chaosConfig.BossPosition)
		handlers.RequestAttackBoss(player)
	end
	local chaos = S.ChaosBossSystem.GetState()
	assert(not chaos.Active and chaos.EventId == 1, "босс повержен ударами всех игроков")
	world:Advance(2)

	-- 6. Вылупление и 7. rebirth.
	local cocoonId = next(world:LoadModule("src/shared/Config/CocoonConfig"))
	local minEssence = world:LoadModule("src/shared/Config/RebirthConfig").MinEssence
	for id, player in players do
		data[id].Currency.Essence = math.max(data[id].Currency.Essence, minEssence) + 1_000_000
		handlers.HatchCocoon(player, cocoonId)
	end
	world:Advance(2)
	for _, player in players do
		handlers.PerformRebirth(player)
	end
	world:Advance(2)

	for id in players do
		local d = data[id]
		assert(d.Meta.FirstUpgradeAt and d.Meta.FirstPetAt, `игрок {id}: апгрейд/пет`)
		assert(#d.Pets == 1 and d.Rebirth.Count == 1, `игрок {id}: пет {#d.Pets}, rebirth {d.Rebirth.Count}`)
		assert(d.PvP.LastRaidedAt and d.PvP.StolenInWindow > 0, `игрок {id}: не ограблен`)
		local m = d.Monetization
		assert(m.BattlePassSeasonId ~= nil and (m.BattlePassTier > 0 or m.BattlePassXP > 0), `игрок {id}: XP пропуска`)
	end
	assert(firedCount() > PLAYERS, "снимки клиентам уходили")
	assert(newWarning() == nil, `предупреждение: {newWarning()}`)

	-- Выход всех игроков и проверка, что никто не держит Player.
	local tracked = setmetatable({}, { __mode = "k" })
	for _, player in players do
		tracked[player] = true
		world:FirePlayerRemoving(player)
		player.Parent = nil
	end
	world.Players = {}
	-- Запоздавшие запросы уже вышедших игроков (пришли после PlayerRemoving) не должны
	-- заводить per-player состояние заново.
	for _, player in players do
		handlers.RequestCollect(player, 1)
		handlers.PurchaseUpgrade(player, upgradeId, 2)
		handlers.HatchCocoon(player, cocoonId)
		handlers.PerformRebirth(player)
		handlers.RequestAttackBoss(player)
		handlers.RequestRaidStart(player, 1)
	end
	world:Advance(600) -- финальные записи, отложенные повторы снимков, выход циклов автосейва
	for id in players do
		assert(S.DataSystem.GetData(players[id]) == nil, "профиль освобождён")
	end
	assert(newWarning() == nil, `предупреждение при выходе: {newWarning()}`)

	world.AnalyticsEvents = {} -- лог стаба аналитики сам хранит Player
	table.clear(players)
	table.clear(roots)
	table.clear(data)
	pump = nil
	-- В Luau нет collectgarbage("collect"): гоняем инкрементальный GC давлением аллокаций,
	-- пока слабая таблица не опустеет (живой Player в ней остался бы навсегда).
	local function countTracked(): number
		local n = 0
		for _ in tracked do
			n += 1
		end
		return n
	end
	local leaked = countTracked()
	for _ = 1, 400 do
		if leaked == 0 then
			break
		end
		local garbage = {}
		for i = 1, 2_000 do
			garbage[i] = table.create(64, i)
		end
		garbage = nil
		leaked = countTracked()
	end
	assert(leaked == 0, `после выхода не собрано {leaked} из {PLAYERS} Player — утечка per-player состояния`)

	local elapsed = os.clock() - startedAt
	print(`        scale: {PLAYERS} игроков, полный цикл за {string.format("%.2f", elapsed)} с реального времени`)
	assert(elapsed < MAX_REAL_SECONDS, `слишком медленно: {elapsed} с`)
end)

return tests
