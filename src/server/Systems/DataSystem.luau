--!strict

--[[
	DataSystem — жизненный цикл профиля игрока (раздел 6 ТЗ).

	- PlayerAdded: загрузка через ProfileStoreService (session-lock), миграция по
	  SchemaVersion, выдача данных остальным системам через GetData / WaitForData.
	- Автосохранение каждые AUTOSAVE_INTERVAL секунд (у каждого игрока свой таймер
	  от момента входа — запросы к DataStore естественно размазаны во времени).
	- PlayerRemoving: финальная запись + снятие лока (ReleaseProfile).
	- game:BindToClose: финальная запись всех профилей до смерти процесса сервера.

	Почему при рестарте сервера нет дюпа/потери данных — подробно в шапке
	ProfileStoreService (п.1–8). Кратко с точки зрения DataSystem:
	  * автосейв продлевает «пульс» лока и ограничивает максимальный откат при краше
	    сервера одним интервалом автосейва;
	  * финальная запись и снятие лока — одна атомарная операция, поэтому следующий
	    сервер либо ждёт её, либо получает уже записанные финальные данные;
	  * BindToClose ждёт все релизы, включая запущенные из PlayerRemoving;
	  * если лок перехвачен другим сервером, игрок кикается, и этот сервер больше
	    не пишет его данные.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.shared.Types)
local BiomeConfig = require(ReplicatedStorage.shared.Config.BiomeConfig)
local StartingProfileConfig = require(ReplicatedStorage.shared.Config.StartingProfileConfig)
local RebirthProgress = require(ReplicatedStorage.shared.RebirthProgress)
local FragmentBuffer = require(ReplicatedStorage.shared.FragmentBuffer)
local ProfileStoreService = require(script.Parent.Parent.Services.ProfileStoreService)

type PlayerProfile = Types.PlayerProfile
type Profile = ProfileStoreService.Profile

local STORE_NAME = "PlayerProfiles"
local AUTOSAVE_INTERVAL = 4 * 60

-- Поднимать на 1 при любом изменении структуры PlayerProfile + добавлять миграцию ниже.
local CURRENT_SCHEMA_VERSION = 10

--[[
	MIGRATIONS[n] переводит данные со SchemaVersion n на n + 1, мутируя таблицу на месте.
	Миграция отвечает только за переименования/преобразования/удаления полей —
	новые поля с дефолтными значениями добавляет reconcile() после цепочки миграций.

	0 → 1: запись без SchemaVersion (до введения версионирования). Структура совпадает
	с v1, всё недостающее дозаполнит reconcile().
	1 → 2: добавлено Factory.RawFragments (буфер сырых фрагментов) — дозаполнит reconcile().
	2 → 3: Factory.StorageCapacity (готовое число) заменено на Factory.StorageCapacityLevel —
	ёмкость вычисляется из уровня и UpgradeConfig (M-4). До S4 покупки апгрейдов не было,
	поэтому сохранённая ёмкость всегда равна стартовой = BaseValue уровня 0: старое поле
	удаляем, StorageCapacityLevel = 0 дозаполнит reconcile().
	3 → 4: удалено Collection.AutoCollectorOwned — единственный источник владения геймпассами
	теперь Monetization.GamePassesOwned (перечитывается у Roblox). Поле нигде не выставлялось
	в true (покупки авто-коллектора до этого не существовало), поэтому просто удаляем его.
	4 → 5: добавлено Monetization.ProcessedReceipts (маркеры выданных дев-продуктов, S12) —
	дозаполнит reconcile() пустым списком: до S12 дев-продуктов не было.
	5 → 6: Factory.RawFragments — число → буфер по эмоциям { Joyful, Nostalgic, Fearful }.
	Старое число целиком уходит в Nostalgic: его модификатор выхода 1.0, поэтому уже собранные
	фрагменты дают столько же Essence, сколько до миграции (у живых игроков буфер почти всегда
	пуст). Битое число (NaN, отрицательное) не трогаем — о порче сообщит конвейер, как и до
	миграции. Ключи зашиты здесь, а не взяты из конфига: миграция не должна меняться вместе с
	конфигом; новые эмоции дозаполнит reconcile().
	6 → 7: сезонный пропуск и воронка аналитики (S18). Monetization.BattlePassXP = 0 и
	BattlePassPremium = false дозаполнит reconcile(); BattlePassSeasonId остаётся nil («сезона не
	было» — BattlePassSystem сбросит прогресс при первом начислении XP). Meta.First*At остаются nil:
	у старых игроков шаги воронки, пройденные до S18, разово залогируются позже (некритично).
	7 → 8: кумулятивный лимит потерь PvP-цели (S19). PvP.StolenInWindow = 0 дозаполнит
	reconcile(); StolenWindowStartsAt остаётся nil (окно начнётся первым рейдом на игрока).
	8 → 9: относительный лимит потерь (S19). PvP.EssenceAtWindowStart = 0 дозаполнит reconcile();
	следующая ротация окна перезапишет его реальным балансом. Окно, открытое ещё на v8, до
	своего истечения (≤ StolenWindowDuration) даёт относительный лимит 0 — цель в нём
	неуязвима; ошибка в пользу цели, по-другому базу окна задним числом не восстановить.
	9 → 10: временные платные баффы. Раздел Buffs (пустой: баффов ещё не покупали) дозаполнит
	reconcile(); Collection.RadiusLevel остаётся как есть — апгрейд снят с продажи и не читается.

	Пример на будущее:
	[1] = function(data)
		data.Currency.Dreams = data.Currency.Essence -- переименование
		data.Currency.Essence = nil
	end,
]]
local MIGRATIONS: { [number]: (data: any) -> () } = {
	[0] = function(_data: any) end,
	[1] = function(_data: any) end,
	[2] = function(data: any)
		if type(data.Factory) == "table" then
			data.Factory.StorageCapacity = nil
		end
	end,
	[3] = function(data: any)
		if type(data.Collection) == "table" then
			data.Collection.AutoCollectorOwned = nil
		end
	end,
	[4] = function(_data: any) end,
	[5] = function(data: any)
		local factory = data.Factory
		if type(factory) ~= "table" then
			return
		end
		local old = factory.RawFragments
		if type(old) == "number" and old == old and old >= 0 and old ~= math.huge then
			factory.RawFragments = { Joyful = 0, Nostalgic = old, Fearful = 0 }
		end
	end,
	[6] = function(_data: any) end,
	[7] = function(_data: any) end,
	[8] = function(_data: any) end,
	[9] = function(_data: any) end,
}

for version = 0, CURRENT_SCHEMA_VERSION - 1 do
	assert(MIGRATIONS[version], `DataSystem: нет миграции {version} → {version + 1}`)
end
assert(
	BiomeConfig[StartingProfileConfig.StartingBiomeId],
	`DataSystem: стартовый биом {StartingProfileConfig.StartingBiomeId} отсутствует в BiomeConfig`
)

local DataSystem = {}

DataSystem.CURRENT_SCHEMA_VERSION = CURRENT_SCHEMA_VERSION

-- Готовые (загруженные и смигрированные) профили. Только отсюда системы получают данные.
local readyProfiles: { [Player]: Profile } = {}

local function deepCopy<T>(value: T): T
	if type(value) ~= "table" then
		return value
	end

	local copy = {}
	for k, v in value :: any do
		copy[k] = deepCopy(v)
	end
	return copy :: any
end

-- Дозаполняет отсутствующие поля значениями из шаблона. Рекурсия только в непустые
-- таблицы шаблона (словари): массивы вроде Pets/Decor в шаблоне пустые и не трогаются.
-- Лишние поля в data не удаляются — это задача явной миграции.
local function reconcile(data: any, template: any)
	for key, templateValue in template do
		local current = data[key]
		if current == nil then
			data[key] = deepCopy(templateValue)
		elseif type(templateValue) == "table" and type(current) == "table" and next(templateValue) ~= nil then
			reconcile(current, templateValue)
		end
	end
end

-- Профиль «нового игрока». Значения — из StartingProfileConfig, структура — PlayerProfile.
function DataSystem.BuildDefaultProfile(): PlayerProfile
	local now = os.time()
	local start = StartingProfileConfig

	return {
		Currency = {
			Essence = start.Essence,
		},
		Factory = {
			Level = start.FactoryLevel,
			StorageCapacityLevel = start.StorageCapacityLevel,
			RawFragments = FragmentBuffer.Empty(),
			ConveyorSpeedLevel = start.ConveyorSpeedLevel,
			Decor = {},
		},
		Collection = {
			RadiusLevel = start.CollectionRadiusLevel,
			SpeedLevel = start.CollectionSpeedLevel,
		},
		Pets = {},
		Rebirth = {
			Count = 0,
			ClarityMultiplier = start.ClarityMultiplier,
			CurrentBiome = start.StartingBiomeId,
		},
		Chaos = {
			PersonalContributionToday = 0,
		},
		PvP = {
			ShieldExpiresAt = nil,
			LastRaidedAt = nil,
			GuardsPlaced = {},
			StolenInWindow = 0,
			StolenWindowStartsAt = nil,
			EssenceAtWindowStart = 0,
		},
		Monetization = {
			GamePassesOwned = {},
			ProcessedReceipts = {},
			BattlePassSeasonId = nil,
			BattlePassTier = start.BattlePassTier,
			BattlePassXP = 0,
			BattlePassPremium = false,
		},
		Buffs = {
			MagnetBoostExpiresAt = nil,
			SpeedBoostExpiresAt = nil,
		},
		Meta = {
			FirstJoinAt = now,
			LastLoginAt = now,
			SchemaVersion = CURRENT_SCHEMA_VERSION,
			FirstCollectAt = nil,
			FirstProcessAt = nil,
			FirstUpgradeAt = nil,
			FirstPetAt = nil,
		},
	}
end

--[[
	Приводит сохранённые данные к текущей схеме (мутирует на месте). Чистая функция
	без обращений к Instance — пригодна для юнит-тестов.

	Версия схемы: Meta = nil или Meta.SchemaVersion = nil — легаси-запись до введения
	версионирования, версия 0 (отработает вся цепочка миграций + reconcile()).

	Возвращает nil + причину + вид ошибки, если данные трогать нельзя. Все проверки идут
	ДО любой мутации data — релиз профиля запишет его обратно как есть:
	- "corrupt": профиль повреждён — data не таблица; Meta есть, но не таблица;
	  SchemaVersion задан, но не целое неотрицательное конечное число (код всегда писал
	  число, поэтому строки, включая "2", — тоже порча). Молча считать такую запись
	  версией 0 нельзя: миграции прогнались бы по ней заново;
	- "newer-schema": SchemaVersion новее текущей — запись сделана более новой версией
	  сервера (например, во время поэтапного деплоя). Старый код не знает новых полей
	  и мог бы их испортить — такой профиль не загружаем.
]]
export type MigrationError = "corrupt" | "newer-schema"

function DataSystem.MigrateProfileData(data: any): (PlayerProfile?, string?, MigrationError?)
	if type(data) ~= "table" then
		return nil, "данные профиля не являются таблицей", "corrupt"
	end

	local meta = data.Meta
	local version = 0
	if meta ~= nil then
		if type(meta) ~= "table" then
			return nil, `Meta не является таблицей ({typeof(meta)})`, "corrupt"
		end
		local rawVersion = meta.SchemaVersion
		if rawVersion ~= nil then
			-- rawVersion ~= rawVersion — NaN; math.huge — бесконечности.
			if
				type(rawVersion) ~= "number"
				or rawVersion ~= rawVersion
				or math.abs(rawVersion) == math.huge
				or rawVersion % 1 ~= 0
				or rawVersion < 0
			then
				return nil, `некорректный SchemaVersion: {tostring(rawVersion)} ({typeof(rawVersion)})`, "corrupt"
			end
			version = rawVersion
		end
	end

	if version > CURRENT_SCHEMA_VERSION then
		return nil, `SchemaVersion {version} новее поддерживаемой {CURRENT_SCHEMA_VERSION}`, "newer-schema"
	end

	for fromVersion = version, CURRENT_SCHEMA_VERSION - 1 do
		MIGRATIONS[fromVersion](data)
	end

	reconcile(data, DataSystem.BuildDefaultProfile())
	data.Meta.SchemaVersion = CURRENT_SCHEMA_VERSION

	-- ClarityMultiplier и CurrentBiome — производные от Rebirth.Count и BiomeConfig, а пишутся
	-- только при rebirth. Перезаписываем на каждой загрузке: сохранённое значение не
	-- доверяется (сменился баланс, старый или испорченный профиль). Count не трогаем; если он
	-- сам битый — пересчёта нет, об этом сообщит RebirthSystem при попытке rebirth.
	local rebirth = data.Rebirth
	if type(rebirth) == "table" then
		local count = rebirth.Count
		if
			type(count) == "number"
			and count == count
			and count ~= math.huge
			and count >= 0
			and count % 1 == 0
		then
			local progress = RebirthProgress.Compute(count)
			rebirth.ClarityMultiplier = progress.ClarityMultiplier
			rebirth.CurrentBiome = progress.CurrentBiome
		end
	end

	return data :: PlayerProfile, nil
end

-- Данные игрока или nil, если профиль ещё не загружен / уже освобождён.
function DataSystem.GetData(player: Player): PlayerProfile?
	local profile = readyProfiles[player]
	return if profile and profile.Active then profile.Data else nil
end

-- Ждёт загрузки профиля. nil — игрок вышел, загрузка не удалась или истёк timeout.
function DataSystem.WaitForData(player: Player, timeout: number?): PlayerProfile?
	local deadline = os.clock() + (timeout or 60)
	while player.Parent ~= nil and os.clock() < deadline do
		local data = DataSystem.GetData(player)
		if data then
			return data
		end
		task.wait(0.1)
	end
	return DataSystem.GetData(player)
end

-- Внеочередная запись профиля в DataStore (с продлением лока). true — записано. Для операций,
-- которые обязаны стать durable до ответа внешней стороне (ProcessReceipt). Yield'ит.
function DataSystem.SaveNow(player: Player): boolean
	local profile = readyProfiles[player]
	if profile == nil or not profile.Active then
		return false
	end
	return ProfileStoreService.SaveProfile(player)
end

local function startAutosave(player: Player, profile: Profile)
	task.spawn(function()
		while true do
			task.wait(AUTOSAVE_INTERVAL)
			if readyProfiles[player] ~= profile or not profile.Active then
				return
			end
			ProfileStoreService.SaveProfile(player)
		end
	end)
end

local function onPlayerAdded(player: Player)
	local profile = ProfileStoreService.LoadProfile(player)
	if profile == nil then
		if player.Parent ~= nil then
			player:Kick("Не удалось загрузить прогресс. Попробуйте зайти через минуту.")
		end
		return
	end

	local data, reason, errorKind = DataSystem.MigrateProfileData(profile.Data)
	if data == nil then
		warn(`[DataSystem] Профиль {player.Name} ({player.UserId}) не загружен ({errorKind}): {reason}`)
		-- Данные не менялись (проверка до мутаций) — релиз запишет их как есть и снимет лок.
		ProfileStoreService.ReleaseProfile(player)
		if errorKind == "newer-schema" then
			player:Kick("Сервер обновляется. Перезайдите, чтобы попасть на актуальную версию.")
		else
			player:Kick("Не удалось прочитать сохранение. Мы уже разбираемся — попробуйте зайти позже.")
		end
		return
	end

	profile.Data = data
	data.Meta.LastLoginAt = os.time()

	-- Между LoadProfile и этой строкой нет yield, но проверяем явно: профиль мог быть
	-- освобождён (игрок вышел) или перехвачен.
	if ProfileStoreService.GetProfile(player) ~= profile then
		return
	end

	readyProfiles[player] = profile
	startAutosave(player, profile)
end

local function onPlayerRemoving(player: Player)
	readyProfiles[player] = nil
	ProfileStoreService.ReleaseProfile(player)
end

local function onSessionLost(player: Player)
	readyProfiles[player] = nil
	if player.Parent ~= nil then
		player:Kick("Ваш прогресс открыт на другом сервере. Перезайдите в игру.")
	end
end

function DataSystem.Init()
	ProfileStoreService.Init({
		StoreName = STORE_NAME,
		CreateDefaultData = DataSystem.BuildDefaultProfile,
		OnSessionLost = onSessionLost,
	})

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	-- Игроки, вошедшие до Init (актуально для Studio).
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end

	game:BindToClose(function()
		ProfileStoreService.ReleaseAll()
	end)
end

return DataSystem
