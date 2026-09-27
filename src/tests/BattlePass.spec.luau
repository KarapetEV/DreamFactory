--[[
	Тесты сезонного пропуска (S18, раздел 7.3 GDD) и аналитики, завязанной на его источники
	(раздел 9 ТЗ):
	- BattlePassConfig: проверки при загрузке (битый конфиг роняет модуль);
	- схема профиля v6 → v7;
	- ротация сезона, начисление XP по каждому источнику, переходы тиров (в т.ч. несколько
	  тиров одним начислением), клампинг на MaxTier, free/premium-награды;
	- премиум через идемпотентный MonetizationSystem.ProcessReceipt: ретроактивные награды,
	  повторная доставка не выдаёт повторно;
	- аналитика: воронка «переработка/апгрейд/пет» (один раз на игрока), события rebirth.

	Сервер собран из настоящих PetSystem/FactorySystem/RebirthSystem/BattlePassSystem/
	MonetizationSystem; профиль — настоящий ProfileStoreService над поддельным DataStore мира
	(для durable-проверок премиума). ChaosBossSystem/PvPRaidSystem — поддельные сигналы (их
	собственные сигналы проверяются в ChaosBoss.spec/PvPRaid.spec).
	Запуск: lune run src/tests/run (из корня репозитория).
]]

local Harness = require("./lib/Harness")

type Test = { Name: string, Run: () -> () }

local tests: { Test } = {}

local function test(name: string, run: () -> ())
	table.insert(tests, { Name = name, Run = run })
end

local GRANTED = "PurchaseGranted"
local NOT_YET = "NotProcessedYet"
local PREMIUM_PRODUCT_ID = 888001
local CONFIG_PATH = "src/shared/Config/BattlePassConfig"

local REMOTE_NAMES = {
	"PurchaseUpgrade",
	"EconomySnapshot",
	"PerformRebirth",
	"HatchCocoon",
	"EquipPet",
	"UnequipPet",
	"PetSnapshot",
}

local function replaceOnce(source: string, from: string, to: string): string
	local startAt, endAt = string.find(source, from, 1, true)
	if not startAt then
		return source
	end
	return string.sub(source, 1, startAt - 1) .. to .. string.sub(source, endAt + 1)
end

-- Конфиг с прошлым сезоном "S0" (текущий — "S1").
local function withPastS0(source: string): string
	return replaceOnce(source, "PastSeasonIds = {},", 'PastSeasonIds = { "S0" },')
end

-- configPatch — подмена исходника BattlePassConfig для всего «сервера» (см. world.SourcePatches).
local function setup(configPatch: ((string) -> string)?)
	local world = Harness.NewWorld()
	if configPatch then
		world.SourcePatches[CONFIG_PATH] = configPatch
	end
	local profileStore, dataSystem = world:NewServer()
	local profiles = {}
	local handlers = {}
	local fired = {} -- имя ремоута -> число FireClient

	local fakeRemotes = {}
	for _, name in REMOTE_NAMES do
		fired[name] = 0
		fakeRemotes[name] = {
			OnServerEvent = {
				Connect = function(_self, fn)
					handlers[name] = fn
				end,
			},
			FireClient = function()
				fired[name] += 1
			end,
		}
	end

	-- Настоящий DevProductConfig с ProductId премиума вместо заглушки 0.
	local devProducts = Harness.DeepCopy(world:LoadModule("src/shared/Config/DevProductConfig"))
	for _, product in devProducts.Products do
		if product.Id == "BattlePassPremium" then
			product.ProductId = PREMIUM_PRODUCT_ID
		end
	end

	local Signal = world:LoadModule("src/shared/Signal")
	local fakeChaos = { OnBossHit = Signal.new() }
	local fakePvP = { OnRaidCompleted = Signal.new() }

	local overrides: { [string]: any } = {
		["src/server/Systems/DataSystem"] = {
			GetData = function(p)
				local profile = profiles[p]
				return if profile and profile.Active then profile.Data else nil
			end,
			WaitForData = function(p)
				local profile = profiles[p]
				return if profile and profile.Active then profile.Data else nil
			end,
			SaveNow = function(p)
				local profile = profiles[p]
				if profile == nil or not profile.Active then
					return false
				end
				return profileStore.SaveProfile(p)
			end,
			BuildDefaultProfile = dataSystem.BuildDefaultProfile,
		},
		["src/shared/Remotes"] = fakeRemotes,
		["src/shared/Config/DevProductConfig"] = devProducts,
		["src/server/Systems/ChaosBossSystem"] = fakeChaos,
		["src/server/Systems/PvPRaidSystem"] = fakePvP,
	}
	local pets = world:LoadModule("src/server/Systems/PetSystem", overrides)
	overrides["src/server/Systems/PetSystem"] = pets
	local factory = world:LoadModule("src/server/Systems/FactorySystem", overrides)
	overrides["src/server/Systems/FactorySystem"] = factory
	local rebirth = world:LoadModule("src/server/Systems/RebirthSystem", overrides)
	overrides["src/server/Systems/RebirthSystem"] = rebirth
	local battlePass = world:LoadModule("src/server/Systems/BattlePassSystem", overrides)
	overrides["src/server/Systems/BattlePassSystem"] = battlePass
	local monetization = world:LoadModule("src/server/Systems/MonetizationSystem", overrides)

	pets.Init()
	factory.Init()
	rebirth.Init()
	battlePass.Init()

	local player = world:NewPlayer(42)
	world.Players = { player }
	local profile
	world:Spawn(function()
		profile = profileStore.LoadProfile(player)
	end)
	world:Advance(120)
	assert(profile, "профиль загрузился")
	profile.Data = assert(dataSystem.MigrateProfileData(profile.Data))
	profiles[player] = profile

	local t = {
		World = world,
		Player = player,
		Data = profile.Data,
		Config = world:LoadModule(CONFIG_PATH),
		Pets = pets,
		Factory = factory,
		Rebirth = rebirth,
		BattlePass = battlePass,
		Monetization = monetization,
		Chaos = fakeChaos,
		PvP = fakePvP,
		Handlers = handlers,
		Fired = fired,
		Overrides = overrides,
		DataSystem = dataSystem,
	}

	function t.BP()
		local m = t.Data.Monetization
		return m.BattlePassTier, m.BattlePassXP, m.BattlePassPremium, m.BattlePassSeasonId
	end

	-- Весь XP сезона: пройденные тиры + XP внутри текущего.
	function t.TotalXP(): number
		local tier, xp = t.BP()
		return t.XPTo(tier) + xp
	end

	-- Сумма XP, нужная с тира 0 до тира n.
	function t.XPTo(n: number): number
		local sum = 0
		for tier = 1, n do
			sum += t.Config.TierThresholds[tier]
		end
		return sum
	end

	function t.FreeEssence(from: number, to: number): number
		local sum = 0
		for tier = from, to do
			sum += t.Config.FreeRewards[tier].Essence
		end
		return sum
	end

	function t.PremiumEssence(from: number, to: number): number
		local sum = 0
		for tier = from, to do
			sum += t.Config.PremiumRewards[tier].Essence
		end
		return sum
	end

	function t.Receipt(purchaseId: string): string?
		local result
		world:Spawn(function()
			result = monetization.ProcessReceipt({
				PlayerId = player.UserId,
				ProductId = PREMIUM_PRODUCT_ID,
				PurchaseId = purchaseId,
				CurrencySpent = 399,
				CurrencyType = "Robux",
				PlaceIdWherePurchased = 1,
			})
		end)
		world:Advance(30)
		return result
	end

	function t.Events(kind: string, name: string?)
		local list = {}
		for _, event in world.AnalyticsEvents do
			if event.Kind == kind and (name == nil or event.Name == name) then
				table.insert(list, event)
			end
		end
		return list
	end

	return t
end

local function loadFails(patch: (string) -> string, expected: string)
	local world = Harness.NewWorld()
	world.SourcePatches[CONFIG_PATH] = function(source: string): string
		local patched = patch(source)
		assert(patched ~= source, "патч конфига не применился — тест устарел")
		return patched
	end
	local ok, err = pcall(world.LoadModule, world, CONFIG_PATH)
	assert(not ok, `битый конфиг загрузился (ожидалось: {expected})`)
	assert(string.find(tostring(err), expected, 1, true), `другая ошибка: {err}`)
end

------------------------------------------------------------------------------------------
-- Конфиг и схема
------------------------------------------------------------------------------------------

test("BattlePassConfig: пороги по числу тиров, награды на каждом тире, пет сезона — существующий вид", function()
	local world = Harness.NewWorld()
	local config = world:LoadModule(CONFIG_PATH)
	local species = world:LoadModule("src/shared/Config/PetSpeciesConfig")
	assert(#config.TierThresholds == config.MaxTier)
	for tier = 1, config.MaxTier do
		assert(config.FreeRewards[tier] and config.PremiumRewards[tier], `тир {tier}`)
	end
	local petId = config.PremiumRewards[config.MaxTier].PetSpeciesId
	assert(petId and species.Species[petId], "на последнем премиум-тире — пет существующего вида")
end)

test("Битый BattlePassConfig роняет загрузку", function()
	loadFails(function(s)
		return replaceOnce(s, "500, 600 }", "500 }")
	end, "TierThresholds")
	loadFails(function(s)
		return replaceOnce(s, "{ 100, 150,", "{ 0, 150,")
	end, "TierThresholds[1]")
	loadFails(function(s)
		return replaceOnce(s, "MaxTier = 10,", "MaxTier = 11,")
	end, "TierThresholds")
	loadFails(function(s)
		return replaceOnce(s, "[5] = { Essence = 700 },", "")
	end, "в FreeRewards нет награды тира 5")
	loadFails(function(s)
		return replaceOnce(s, "[9] = { Essence = 2_500 },", "")
	end, "в PremiumRewards нет награды тира 9")
	loadFails(function(s)
		return replaceOnce(s, "[10] = { Essence = 2_000 },", "[10] = { Essence = 2_000 },\n\t\t[11] = { Essence = 1 },")
	end, "лишний ключ 11")
	loadFails(function(s)
		return replaceOnce(s, "XPPerRaid = 25,", "XPPerRaid = 0,")
	end, "XPPerRaid")
	loadFails(function(s)
		return replaceOnce(s, "XPPerHatch = 10,", "XPPerHatch = 0 / 0,")
	end, "XPPerHatch")
	loadFails(function(s)
		return replaceOnce(s, 'PetSpeciesId = "MoonOwl"', 'PetSpeciesId = "NoSuchPet"')
	end, "NoSuchPet")
	loadFails(function(s)
		return replaceOnce(s, "PastSeasonIds = {},", 'PastSeasonIds = { "S1" },')
	end, "повторяется")
	loadFails(function(s)
		return replaceOnce(s, 'PremiumPetRarity = "Legendary"', 'PremiumPetRarity = "Mythic"')
	end, "PremiumPetRarity")
end)

test("Профиль v6 мигрирует в v7: XP = 0, Premium = false, SeasonId = nil, воронка — nil", function()
	local world = Harness.NewWorld()
	local _, dataSystem = world:NewServer()
	assert(dataSystem.CURRENT_SCHEMA_VERSION == 7)
	local v6 = {
		Meta = { SchemaVersion = 6, FirstJoinAt = 5, LastLoginAt = 6 },
		Monetization = { GamePassesOwned = { "ExtraPetSlots" }, ProcessedReceipts = {}, BattlePassTier = 0 },
	}
	local migrated = assert(dataSystem.MigrateProfileData(v6))
	local m = migrated.Monetization
	assert(migrated.Meta.SchemaVersion == 7)
	assert(m.BattlePassXP == 0 and m.BattlePassPremium == false and m.BattlePassSeasonId == nil and m.BattlePassTier == 0)
	assert(m.GamePassesOwned[1] == "ExtraPetSlots", "остальное не тронуто")
	local meta = migrated.Meta
	assert(meta.FirstCollectAt == nil and meta.FirstProcessAt == nil and meta.FirstUpgradeAt == nil and meta.FirstPetAt == nil)
	assert(meta.FirstJoinAt == 5)

	local fresh = dataSystem.BuildDefaultProfile()
	assert(fresh.Monetization.BattlePassXP == 0 and fresh.Monetization.BattlePassPremium == false)
	assert(fresh.Monetization.BattlePassSeasonId == nil and fresh.Meta.FirstCollectAt == nil)
end)

------------------------------------------------------------------------------------------
-- Ротация сезона
------------------------------------------------------------------------------------------

test("Первое начисление XP запускает сезон: SeasonId записан, прогресс с нуля", function()
	local t = setup()
	local tier, xp, premium, season = t.BP()
	assert(season == nil and tier == 0 and xp == 0 and premium == false)
	assert(t.BattlePass.AddXP(t.Player, 7))
	tier, xp, premium, season = t.BP()
	assert(season == t.Config.SeasonId and tier == 0 and xp == 7 and premium == false)
end)

test("Прогресс прошлого сезона сбрасывается при первом начислении, без наград за старые тиры", function()
	local t = setup(withPastS0)
	local m = t.Data.Monetization
	m.BattlePassSeasonId = "S0"
	m.BattlePassTier = 7
	m.BattlePassXP = 40
	m.BattlePassPremium = true
	local essence = t.Data.Currency.Essence
	assert(t.BattlePass.AddXP(t.Player, 3))
	local tier, xp, premium, season = t.BP()
	assert(season == t.Config.SeasonId and tier == 0 and xp == 3 and premium == false, `{tier}/{xp}/{premium}`)
	assert(t.Data.Currency.Essence == essence, "за тиры прошлого сезона ничего не выдано")
end)

test("Смена SeasonId в конфиге сбрасывает прогресс; повторное начисление — no-op ротации", function()
	local t = setup()
	assert(t.BattlePass.AddXP(t.Player, t.XPTo(2) + 5))
	t.Data.Monetization.BattlePassPremium = true
	assert(t.BP() == 2)

	-- «Новая версия сервера» с другим SeasonId.
	t.World.SourcePatches[CONFIG_PATH] = function(source)
		local patched = replaceOnce(source, 'SeasonId = "S1",', 'SeasonId = "S2",')
		return replaceOnce(patched, "PastSeasonIds = {},", 'PastSeasonIds = { "S1" },')
	end
	local overrides = table.clone(t.Overrides)
	overrides["src/server/Systems/BattlePassSystem"] = nil
	local nextSeason = t.World:LoadModule("src/server/Systems/BattlePassSystem", overrides)
	assert(nextSeason.AddXP(t.Player, 4))
	local tier, xp, premium, season = t.BP()
	assert(season == "S2" and tier == 0 and xp == 4 and premium == false, `{season}/{tier}/{xp}/{premium}`)
	assert(nextSeason.AddXP(t.Player, 4))
	tier, xp = t.BP()
	assert(tier == 0 and xp == 8, "та же строка сезона — прогресс не сбрасывается")
end)

------------------------------------------------------------------------------------------
-- Тиры и награды
------------------------------------------------------------------------------------------

test("Переход тира: XP вычитается, выдаётся FreeRewards тира, снимок экономики уходит", function()
	local t = setup()
	local essence = t.Data.Currency.Essence
	local first = t.Config.TierThresholds[1]
	assert(t.BattlePass.AddXP(t.Player, first - 1))
	assert(t.BP() == 0 and t.Data.Currency.Essence == essence, "порог не достигнут")
	local snapshots = t.Fired.EconomySnapshot

	assert(t.BattlePass.AddXP(t.Player, 3))
	local tier, xp = t.BP()
	assert(tier == 1 and xp == 2, `{tier}/{xp}`)
	assert(t.Data.Currency.Essence == essence + t.Config.FreeRewards[1].Essence)
	assert(t.Fired.EconomySnapshot == snapshots + 1, "HUD получил новый баланс")
end)

test("Одно большое начисление проходит несколько тиров подряд и выдаёт награду каждого", function()
	local t = setup()
	local essence = t.Data.Currency.Essence
	assert(t.BattlePass.AddXP(t.Player, t.XPTo(3) + 5))
	local tier, xp = t.BP()
	assert(tier == 3 and xp == 5, `{tier}/{xp}`)
	assert(t.Data.Currency.Essence == essence + t.FreeEssence(1, 3))
	assert(table.find(t.Data.Factory.Decor, t.Config.FreeRewards[3].Decor), "декор тира 3 выдан")
	assert(#t.Data.Pets == 0, "пет — только в премиум-ветке")
end)

test("На MaxTier XP не копится, повторные начисления ничего не выдают", function()
	local t = setup()
	local essence = t.Data.Currency.Essence
	local max = t.Config.MaxTier
	assert(t.BattlePass.AddXP(t.Player, t.XPTo(max) * 3))
	local tier, xp = t.BP()
	assert(tier == max and xp == 0, `{tier}/{xp}`)
	local after = essence + t.FreeEssence(1, max)
	assert(t.Data.Currency.Essence == after)
	assert(t.BattlePass.AddXP(t.Player, 1_000))
	tier, xp = t.BP()
	assert(tier == max and xp == 0 and t.Data.Currency.Essence == after)
end)

test("С премиумом тир выдаёт free + premium; на последнем тире — пет сезона нужной редкости", function()
	local t = setup()
	assert(t.BattlePass.AddXP(t.Player, 1)) -- старт сезона
	t.Data.Monetization.BattlePassPremium = true
	local essence = t.Data.Currency.Essence
	local max = t.Config.MaxTier
	local petSnapshots = t.Fired.PetSnapshot

	assert(t.BattlePass.AddXP(t.Player, t.XPTo(max)))
	assert(t.BP() == max)
	assert(t.Data.Currency.Essence == essence + t.FreeEssence(1, max) + t.PremiumEssence(1, max))
	assert(table.find(t.Data.Factory.Decor, t.Config.PremiumRewards[2].Decor))
	assert(#t.Data.Pets == 1)
	local pet = t.Data.Pets[1]
	assert(pet.SpeciesId == t.Config.PremiumRewards[max].PetSpeciesId and pet.Rarity == t.Config.PremiumPetRarity)
	assert(pet.Equipped == false and pet.Level == 1 and type(pet.Id) == "string")
	assert(t.Fired.PetSnapshot == petSnapshots + 1, "инвентарь петов обновлён у клиента")
end)

test("Сезон профиля новее сервера (поэтапный деплой): прогресс и премиум не трогаются, квитанция ждёт", function()
	local t = setup()
	local m = t.Data.Monetization
	m.BattlePassSeasonId = "S2" -- сервер знает только S1: S2 — из более новой версии
	m.BattlePassTier = 4
	m.BattlePassXP = 10
	m.BattlePassPremium = true
	local essence = t.Data.Currency.Essence
	assert(not t.BattlePass.AddXP(t.Player, 500), "XP не начислен")
	assert(t.Receipt("bp-newer") == NOT_YET, "премиум доставится на сервере новой версии")
	local tier, xp, premium, season = t.BP()
	assert(season == "S2" and tier == 4 and xp == 10 and premium == true, "прогресс нового сезона цел")
	assert(t.Data.Currency.Essence == essence and #t.Data.Monetization.ProcessedReceipts == 0)
end)

test("Битые данные: начисление не пишет ни прогресс, ни награды", function()
	local t = setup()
	assert(t.BattlePass.AddXP(t.Player, 1))
	t.Data.Currency.Essence = 0 / 0
	assert(not t.BattlePass.AddXP(t.Player, t.XPTo(2)), "переход тира с битой Essence отклонён")
	local tier, xp = t.BP()
	assert(tier == 0 and xp == 1, "XP не записан без награды")

	t.Data.Currency.Essence = 0
	t.Data.Monetization.BattlePassTier = "пять"
	assert(not t.BattlePass.AddXP(t.Player, 5))
	assert(t.Data.Monetization.BattlePassTier == "пять" and t.Data.Monetization.BattlePassXP == 1)
	assert(not t.BattlePass.AddXP(t.Player, 0 / 0) and not t.BattlePass.AddXP(t.Player, -5))
	assert(#t.World.Warnings >= 1)
end)

------------------------------------------------------------------------------------------
-- Источники XP
------------------------------------------------------------------------------------------

test("XP за цикл конвейера — по событию OnEssenceProduced, а не по сумме Essence", function()
	local t = setup()
	t.Data.Rebirth.ClarityMultiplier = 50 -- большой множитель не должен влиять на XP
	t.Data.Factory.RawFragments = { Joyful = 3, Nostalgic = 3, Fearful = 0 }
	local events = 0
	t.Factory.OnEssenceProduced:Connect(function()
		events += 1
	end)
	t.World:Advance(60)
	assert(events >= 2, `событий конвейера {events}`)
	assert(t.TotalXP() == events * t.Config.XPPerFactoryCycle, `XP {t.TotalXP()} при {events} событиях`)
end)

test("XP за rebirth, удар по боссу, рейд (атакующему) и вылупление пета", function()
	local t = setup()
	local c = t.Config
	local rebirthConfig = t.World:LoadModule("src/shared/Config/RebirthConfig")
	t.Data.Currency.Essence = rebirthConfig.MinEssence
	t.Handlers.PerformRebirth(t.Player)
	assert(t.Data.Rebirth.Count == 1)
	assert(t.TotalXP() == c.XPPerRebirth, `rebirth: {t.TotalXP()}`)

	t.Chaos.OnBossHit:Fire(t.Player, 999, 1)
	assert(t.TotalXP() == c.XPPerRebirth + c.XPPerChaosHit, "удар: фиксированный XP, не по урону")

	local target = t.World:NewPlayer(7)
	t.PvP.OnRaidCompleted:Fire(t.Player, target, 1234)
	assert(t.TotalXP() == c.XPPerRebirth + c.XPPerChaosHit + c.XPPerRaid, "рейд: XP атакующему")

	local cocoons = t.World:LoadModule("src/shared/Config/CocoonConfig")
	local cocoonId, cocoon = next(cocoons)
	t.Data.Currency.Essence = cocoon.Price
	t.World:Advance(5)
	t.Handlers.HatchCocoon(t.Player, cocoonId)
	assert(#t.Data.Pets == 1, "пет вылупился")
	local total = c.XPPerRebirth + c.XPPerChaosHit + c.XPPerRaid + c.XPPerHatch
	assert(t.TotalXP() == total, `вылупление: {t.TotalXP()}`)
end)

test("Отклонённые действия XP не дают; игрок без профиля — событие без прогресса", function()
	local t = setup()
	t.Handlers.PerformRebirth(t.Player) -- ниже порога
	t.World:Advance(5)
	t.Handlers.HatchCocoon(t.Player, "NoSuchCocoon")
	local _, xp, _, season = t.BP()
	assert(xp == 0 and season == nil)

	local stranger = t.World:NewPlayer(99)
	t.Chaos.OnBossHit:Fire(stranger, 10, 1)
	assert(not t.BattlePass.AddXP(stranger, 10))
end)

------------------------------------------------------------------------------------------
-- Премиум через ProcessReceipt
------------------------------------------------------------------------------------------

test("Премиум после пройденных тиров: ретроактивные премиум-награды 1..Tier, покупка durable", function()
	local t = setup()
	assert(t.BattlePass.AddXP(t.Player, t.XPTo(3) + 1))
	local essence = t.Data.Currency.Essence

	assert(t.Receipt("bp-1") == GRANTED)
	local tier, xp, premium = t.BP()
	assert(premium == true and tier == 3 and xp == 1, "прогресс не тронут, премиум включён")
	assert(t.Data.Currency.Essence == essence + t.PremiumEssence(1, 3), "премиум-награды тиров 1..3")
	assert(table.find(t.Data.Factory.Decor, t.Config.PremiumRewards[2].Decor))
	local stored = t.World.Records.Player_42.Data
	assert(stored.Monetization.BattlePassPremium == true and stored.Currency.Essence == t.Data.Currency.Essence, "в DataStore")
	assert(t.World.Records["Receipt_bp-1"].Product == "BattlePassPremium", "квитанция закрыта логом")

	-- Дальше тиры идут с обеими ветками.
	local before = t.Data.Currency.Essence
	assert(t.BattlePass.AddXP(t.Player, t.Config.TierThresholds[4]))
	assert(t.Data.Currency.Essence == before + t.Config.FreeRewards[4].Essence + t.Config.PremiumRewards[4].Essence)
end)

test("Повторная доставка той же квитанции премиума ничего не выдаёт повторно", function()
	local t = setup()
	assert(t.BattlePass.AddXP(t.Player, t.XPTo(t.Config.MaxTier)))
	assert(t.Receipt("bp-dup") == GRANTED)
	local essence = t.Data.Currency.Essence
	assert(#t.Data.Pets == 1, "пет сезона выдан ретроактивно")
	for _ = 1, 3 do
		assert(t.Receipt("bp-dup") == GRANTED)
	end
	assert(t.Data.Currency.Essence == essence and #t.Data.Pets == 1, "повтор не выдал ничего")
	assert(#t.Data.Monetization.ProcessedReceipts == 1)
	local purchases = t.Events("Custom", "DevProductPurchased")
	assert(#purchases == 1 and purchases[1].CustomFields.CustomField01 == "BattlePassPremium")
end)

test("Повторная доставка после сбоя лога: маркер в профиле не даёт выдать второй раз", function()
	local t = setup()
	assert(t.BattlePass.AddXP(t.Player, t.XPTo(2)))
	t.World.StoreError = function(op, key)
		return if op == "UpdateAsync" and key == "Receipt_bp-log" then "DataStore: 502 (тест)" else nil
	end
	assert(t.Receipt("bp-log") == NOT_YET)
	local essence = t.Data.Currency.Essence
	assert(t.Data.Monetization.BattlePassPremium == true)
	t.World.StoreError = nil
	assert(t.Receipt("bp-log") == GRANTED)
	assert(t.Data.Currency.Essence == essence, "премиум-награды выданы один раз")
end)

test("Новая покупка премиума при уже активном: ничего не выдаётся, квитанция закрывается с warn", function()
	local t = setup()
	assert(t.BattlePass.AddXP(t.Player, t.XPTo(t.Config.MaxTier)))
	assert(t.Receipt("bp-a") == GRANTED)
	local essence = t.Data.Currency.Essence
	assert(t.Receipt("bp-b") == GRANTED)
	assert(t.Data.Currency.Essence == essence and #t.Data.Pets == 1, "второй пет/награды не выданы")
	local warned = false
	for _, warning in t.World.Warnings do
		warned = warned or string.find(warning, "повторно купил премиум", 1, true) ~= nil
	end
	assert(warned)
	local duplicates = t.Events("Custom", "BattlePassPremiumDuplicate")
	assert(#duplicates == 1 and duplicates[1].CustomFields.CustomField01 == t.Config.SeasonId, "кандидат на возврат")
end)

test("Премиум до первого XP запускает сезон; премиум прошлого сезона сбрасывается ротацией", function()
	local t = setup(withPastS0)
	local m = t.Data.Monetization
	m.BattlePassSeasonId = "S0"
	m.BattlePassTier = 9
	m.BattlePassPremium = false
	local essence = t.Data.Currency.Essence
	assert(t.Receipt("bp-new") == GRANTED)
	local tier, xp, premium, season = t.BP()
	assert(season == t.Config.SeasonId and tier == 0 and xp == 0 and premium == true)
	assert(t.Data.Currency.Essence == essence, "тиров этого сезона ещё нет — ретро-наград нет")

	assert(t.BattlePass.AddXP(t.Player, t.Config.TierThresholds[1]))
	assert(t.Data.Currency.Essence == essence + t.Config.FreeRewards[1].Essence + t.Config.PremiumRewards[1].Essence)
end)

test("Битый прогресс пропуска: квитанция премиума — NotProcessedYet без маркера и выдачи", function()
	local t = setup()
	assert(t.BattlePass.AddXP(t.Player, 1))
	t.Data.Monetization.BattlePassXP = -1
	assert(t.Receipt("bp-bad") == NOT_YET)
	assert(#t.Data.Monetization.ProcessedReceipts == 0 and t.Data.Monetization.BattlePassPremium == false)
	assert(t.World.Records["Receipt_bp-bad"] == nil)
end)

------------------------------------------------------------------------------------------
-- Аналитика: воронка и rebirth
------------------------------------------------------------------------------------------

test("Воронка: первая переработка, первый апгрейд, первый пет — каждый шаг ровно один раз", function()
	local t = setup()
	t.Data.Factory.RawFragments = { Joyful = 0, Nostalgic = 30, Fearful = 0 }
	t.World:Advance(60)
	assert(type(t.Data.Meta.FirstProcessAt) == "number")

	local upgrades = t.World:LoadModule("src/shared/Config/UpgradeConfig")
	local upgradeId, track = next(upgrades)
	t.Data.Currency.Essence = 10_000_000
	t.Handlers.PurchaseUpgrade(t.Player, upgradeId, 99) -- отказ: не тот уровень
	assert(t.Data.Meta.FirstUpgradeAt == nil, "отказ — не шаг воронки")
	t.World:Advance(5)
	t.Handlers.PurchaseUpgrade(t.Player, upgradeId, 1)
	t.World:Advance(5)
	if track.MaxLevel >= 2 then
		t.Handlers.PurchaseUpgrade(t.Player, upgradeId, 2)
	end
	assert(type(t.Data.Meta.FirstUpgradeAt) == "number")

	local cocoonId = next(t.World:LoadModule("src/shared/Config/CocoonConfig"))
	for _ = 1, 2 do
		t.World:Advance(5)
		t.Handlers.HatchCocoon(t.Player, cocoonId)
	end
	assert(#t.Data.Pets == 2 and type(t.Data.Meta.FirstPetAt) == "number")

	local steps = {}
	for _, event in t.Events("Funnel") do
		assert(event.Player == t.Player)
		table.insert(steps, `{event.Step}:{event.StepName}`)
	end
	assert(
		table.concat(steps, ",") == "2:FirstProcess,3:FirstUpgrade,4:FirstPet",
		`шаги воронки: {table.concat(steps, ",")}`
	)
end)

test("Шаг воронки не логируется, если поле Meta уже заполнено (например, после реджойна)", function()
	local t = setup()
	t.Data.Meta.FirstPetAt = 123
	local cocoonId = next(t.World:LoadModule("src/shared/Config/CocoonConfig"))
	t.Data.Currency.Essence = 10_000_000
	t.Handlers.HatchCocoon(t.Player, cocoonId)
	assert(#t.Data.Pets == 1 and t.Data.Meta.FirstPetAt == 123, "поле не перезаписано")
	assert(#t.Events("Funnel") == 0)
end)

test("Сигнал апгрейда: OnUpgradePurchased(player, id, новый уровень) только на успешную покупку", function()
	local t = setup()
	local seen = {}
	t.Factory.OnUpgradePurchased:Connect(function(player, id, level)
		table.insert(seen, { Player = player, Id = id, Level = level })
	end)
	local upgradeId = next(t.World:LoadModule("src/shared/Config/UpgradeConfig"))
	t.Handlers.PurchaseUpgrade(t.Player, upgradeId, 1) -- Essence 0 — отказ
	assert(#seen == 0)
	t.Data.Currency.Essence = 10_000_000
	t.World:Advance(5)
	t.Handlers.PurchaseUpgrade(t.Player, upgradeId, 1)
	assert(#seen == 1 and seen[1].Player == t.Player and seen[1].Id == upgradeId and seen[1].Level == 1)
end)

test("Rebirth: события конца и начала цикла + OnRebirthPerformed; отказ — без событий", function()
	local t = setup()
	local seen = {}
	t.Rebirth.OnRebirthPerformed:Connect(function(player, count, essenceBefore)
		table.insert(seen, { Player = player, Count = count, Essence = essenceBefore })
	end)
	t.Handlers.PerformRebirth(t.Player) -- ниже порога
	assert(#seen == 0 and #t.Events("Custom") == 0)

	local essence = t.World:LoadModule("src/shared/Config/RebirthConfig").MinEssence + 77
	t.Data.Currency.Essence = essence
	t.World:Advance(5)
	t.Handlers.PerformRebirth(t.Player)
	assert(#seen == 1 and seen[1].Count == 1 and seen[1].Essence == essence)
	local ended = t.Events("Custom", "RebirthCycleEnded")
	local started = t.Events("Custom", "RebirthCycleStarted")
	assert(#ended == 1 and ended[1].Value == essence and ended[1].Player == t.Player)
	assert(#started == 1 and started[1].Value == 1)
end)

test("Сбой AnalyticsService не ломает игровую транзакцию и пишется в лог один раз на вид вызова", function()
	local t = setup()
	t.World.AnalyticsError = "AnalyticsService: throttled (тест)"
	local cocoonId = next(t.World:LoadModule("src/shared/Config/CocoonConfig"))
	t.Data.Currency.Essence = 10_000_000
	t.Handlers.HatchCocoon(t.Player, cocoonId)
	assert(#t.Data.Pets == 1, "вылупление прошло")
	assert(type(t.Data.Meta.FirstPetAt) == "number", "шаг отмечен — после сбоя не повторяется")
	t.World:Advance(5)
	t.Handlers.HatchCocoon(t.Player, cocoonId)

	local rebirthConfig = t.World:LoadModule("src/shared/Config/RebirthConfig")
	t.Data.Currency.Essence = rebirthConfig.MinEssence
	t.Handlers.PerformRebirth(t.Player)
	assert(t.Data.Rebirth.Count == 1, "rebirth прошёл")

	local failures = 0
	for _, warning in t.World.Warnings do
		if string.find(warning, "[AnalyticsSystem]", 1, true) then
			failures += 1
		end
	end
	assert(failures == 2, `предупреждений {failures}`)
	assert(#t.World.AnalyticsEvents == 0)
end)

return tests
