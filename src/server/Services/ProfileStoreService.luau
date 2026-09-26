--!strict

--[[
	ProfileStoreService — обёртка над DataStoreService с session-locking
	(паттерн ProfileService / ProfileStore). Раздел 6 ТЗ.

	Публичный API:
		Init(options)              — один раз при старте сервера
		LoadProfile(player)        -> Profile?  (yield; nil = загрузить не удалось, игрока надо кикнуть)
		SaveProfile(player)        -> boolean   (yield; промежуточное сохранение с продлением лока)
		ReleaseProfile(player)                  (yield; финальное сохранение + снятие лока)
		GetProfile(player)         -> Profile?  (без yield)
		ReleaseAll()                            (yield; для game:BindToClose)

	Формат записи в DataStore (ключ "Player_<UserId>"):
		{
			Data = PlayerProfile,
			Meta = {
				ActiveSession = { SessionId, PlaceId, JobId } | nil, -- лок: какой сервер владеет профилем
				LastUpdate = os.time() последней записи владельцем,    -- «пульс» лока
				SessionLoadCount = сколько раз профиль загружался,
			},
		}

	=====================================================================
	КАК ПРЕДОТВРАЩАЕТСЯ ДЮП И ПОТЕРЯ ДАННЫХ (ключевая часть для ревью)
	=====================================================================

	Классический дюп без лока: игрок на сервере A тратит/передаёт ресурс, быстро
	переходит на сервер B (телепорт, реджойн, рестарт сервера), B читает ключ ДО
	того, как A успел записать финальное состояние, → на B старые данные, потом A
	дописывает свои → одна из версий перезаписывает другую (дюп или откат).

	1. Все операции — только через UpdateAsync, никогда GetAsync + SetAsync.
	   UpdateAsync — атомарный compare-and-swap на уровне ключа: если между чтением
	   и записью ключ изменил другой сервер, Roblox перезапускает transform-функцию
	   на свежем значении. Поэтому «проверить лок» и «захватить лок» — одна
	   неразрывная операция: два сервера не могут одновременно увидеть ключ
	   свободным и оба его захватить.

	2. Захват при загрузке (LoadProfile). Если Meta.ActiveSession принадлежит
	   другому серверу — мы НЕ читаем данные в работу, а ждём и повторяем
	   (LOAD_RETRY_DELAY × MAX_LOAD_ATTEMPTS). Старый сервер тем временем в
	   PlayerRemoving делает ReleaseProfile, и мы получаем его ФИНАЛЬНОЕ состояние.

	3. Финальное сохранение и снятие лока — одна запись (ReleaseProfile):
	   Data и ActiveSession = nil пишутся одним UpdateAsync. Не существует момента,
	   когда лок уже снят, а финальные данные ещё не записаны (или наоборот).

	4. Каждая запись проверяет, что лок всё ещё наш. Если нет — запись ОТМЕНЯЕТСЯ
	   (transform возвращает nil), профиль помечается неактивным, игрок кикается
	   через OnSessionLost. Сервер, потерявший лок, физически не может перезаписать
	   данные нового владельца.

	5. Перехват «мёртвого» лока. Если сервер-владелец упал без BindToClose (краш),
	   лок остаётся навсегда. Поэтому лок забирается принудительно:
	     - сразу, если «пульс» (Meta.LastUpdate) старше STALE_LOCK_SECONDS
	       (владелец пропустил ≥2 автосейва — он мёртв);
	     - иначе на последней попытке загрузки (~35 с ожидания).
	   Перехват безопасен благодаря п.4: если старый сервер всё же жив, его
	   следующая запись увидит чужой лок и будет отменена — двух писателей не
	   бывает. Цена — потеря изменений старого сервера с момента его последнего
	   сохранения (не больше интервала автосейва). Это осознанный компромисс:
	   лучше откатить несколько минут, чем получить дюп или вечно заблокированный
	   профиль.

	6. Рестарт/выключение сервера (game:BindToClose → ReleaseAll):
	     - ставится флаг shuttingDown: новые загрузки запрещены, а загрузки, уже
	       завершившиеся во время выключения, тут же освобождаются;
	     - все активные профили освобождаются параллельно (финальная запись + снятие
	       лока);
	     - ReleaseAll ждёт и те релизы, что уже запущены из PlayerRemoving (при
	       выключении Roblox кикает всех — их записи в полёте), иначе процесс
	       сервера умрёт посреди записи. Лимит BindToClose — 30 с, поэтому ретраи
	       релиза ограничены по времени.
	     - если запись всё же не прошла — лок остаётся, данные откатываются к
	       последнему автосейву, п.5 разблокирует профиль. Дюпа нет.

	7. Лок принадлежит конкретной ЗАГРУЗКЕ, а не серверу: каждый вызов LoadProfile
	   генерирует свой LoadId (GUID), и все проверки владения сравнивают именно его.
	   Два профиля одного UserId на одном сервере (реджойн, двойной PlayerAdded)
	   для DataStore различимы: релиз старого профиля не может снять лок нового,
	   а новая загрузка не примет лок старого за свой.

	   Плюс на одном сервере операции над одним UserId строго последовательны:
	     - loadingUserIds — реестр загрузок «в полёте»: вторая загрузка того же
	       UserId ждёт, пока первая завершится или отменится;
	     - releasingUserIds — релизы в полёте: загрузка ждёт финальной записи,
	       иначе прочитала бы данные до неё;
	     - если игрок ушёл во время загрузки, релиз регистрируется в
	       releasingUserIds синхронно, ДО task.spawn и до снятия отметки о загрузке,
	       поэтому между «загрузка закончилась» и «релиз начался» нет окна, в
	       которое успела бы проскочить следующая загрузка.

	8. Сериализация операций над одним профилем внутри сервера (busy-мьютекс):
	   автосейв и релиз не перекрываются. Иначе автосейв, стартовавший до релиза,
	   мог бы увидеть уже снятый лок и ложно решить, что сессия потеряна.

	Дополнительно: UpdateAsync получает { UserId } — ключ привязан к игроку для
	GDPR-запросов на удаление; DataStore автоматически хранит версии записей
	(ListVersionsAsync) — резерв для отката при массовом баге (раздел 6 ТЗ).
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Types = require(ReplicatedStorage.shared.Types)

type PlayerProfile = Types.PlayerProfile

export type Profile = {
	Player: Player,
	UserId: number,
	Key: string,
	-- Живые данные игрока. Системы меняют их на месте, запись в DataStore делает этот сервис.
	Data: PlayerProfile,
	SessionLoadCount: number,
	-- GUID этой загрузки = Meta.ActiveSession.LoadId в DataStore (п.7).
	LoadId: string,
	-- false после ReleaseProfile или потери лока: профиль больше нельзя ни менять, ни писать.
	Active: boolean,
}

export type InitOptions = {
	StoreName: string,
	-- Данные для игрока, у которого ещё нет записи в DataStore.
	CreateDefaultData: () -> PlayerProfile,
	-- Вызывается, если лок профиля перехватил другой сервер (игрока надо кикнуть).
	OnSessionLost: ((player: Player) -> ())?,
}

type SessionTag = {
	-- Уникален для каждого вызова LoadProfile — по нему проверяется владение локом.
	LoadId: string,
	-- Процесс сервера — только для диагностики (какой сервер держит лок).
	ServerId: string,
	PlaceId: number,
	JobId: string,
}

type WriteResult = "Saved" | "SessionLost" | "Failed"

-- Минимальный интерфейс хранилища: используем только UpdateAsync (см. п.1 выше).
type StoreLike = {
	UpdateAsync: (self: any, key: string, transform: (any, any) -> (any, any)) -> any,
}

local KEY_PREFIX = "Player_"

local LOAD_RETRY_DELAY = 5
-- ≈ (MAX_LOAD_ATTEMPTS - 1) × LOAD_RETRY_DELAY = 35 с ожидания чужого релиза, затем перехват.
local MAX_LOAD_ATTEMPTS = 8
-- Должно быть заметно больше интервала автосейва DataSystem (3–5 мин): лок без
-- «пульса» дольше этого времени считается брошенным упавшим сервером.
local STALE_LOCK_SECONDS = 10 * 60

-- Ретраи финальной записи. Суммарно должны укладываться в лимит BindToClose (30 с).
local RELEASE_ATTEMPTS = 3
local RELEASE_RETRY_DELAY = 2

local SHUTDOWN_TIMEOUT = 25

-- Id процесса сервера для диагностики. game.JobId в Studio пустой, поэтому свой GUID.
local SERVER_ID = HttpService:GenerateGUID(false)

local ProfileStoreService = {}

local store: StoreLike? = nil
local isMockStore = false
local createDefaultData: (() -> PlayerProfile)? = nil
local onSessionLost: ((player: Player) -> ())? = nil

local profiles: { [Player]: Profile } = {}
local busyProfiles: { [Profile]: boolean } = {}
-- Операции «в полёте» по UserId на этом сервере (п.7).
local loadingUserIds: { [number]: boolean } = {}
local releasingUserIds: { [number]: number } = {}
local pendingReleases = 0
local shuttingDown = false

-- In-memory хранилище для Studio без доступа к API: позволяет плейтестить без
-- DataStore. JSON-круговорот имитирует сериализацию (ловит несериализуемые данные).
local function createMockStore(): StoreLike
	local records: { [string]: string } = {}
	local mock = {}

	function mock.UpdateAsync(_self: any, key: string, transform: (any, any) -> (any, any)): any
		local encoded = records[key]
		local current = if encoded then HttpService:JSONDecode(encoded) else nil
		local newValue = transform(current, nil)
		if newValue ~= nil then
			records[key] = HttpService:JSONEncode(newValue)
		end
		return newValue
	end

	return mock :: any
end

local function getStore(): StoreLike
	assert(store, "ProfileStoreService.Init не был вызван")
	return store
end

local function waitForBudget()
	if isMockStore then
		return
	end

	local deadline = os.clock() + 10
	while
		DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.UpdateAsync) <= 0
		and os.clock() < deadline
	do
		task.wait(0.5)
	end
end

local function isOwnedByLoad(meta: any, loadId: string): boolean
	local lock = meta.ActiveSession
	return type(lock) == "table" and lock.LoadId == loadId
end

local function isValidRecord(record: any): boolean
	return type(record) == "table" and type(record.Meta) == "table"
end

local function acquireBusy(profile: Profile)
	while busyProfiles[profile] do
		task.wait(0.1)
	end
	busyProfiles[profile] = true
end

local function releaseBusy(profile: Profile)
	busyProfiles[profile] = nil
end

local function handleSessionLost(profile: Profile)
	profile.Active = false
	if profiles[profile.Player] == profile then
		profiles[profile.Player] = nil
	end

	warn(`[ProfileStoreService] Лок профиля {profile.Key} перехвачен другим сервером — запись отменена`)

	local callback = onSessionLost
	if callback then
		task.spawn(callback, profile.Player)
	end
end

-- Запись профиля в DataStore. Пишет ТОЛЬКО если лок всё ещё наш (п.4).
-- release = true: та же атомарная запись дополнительно снимает лок (п.3).
local function writeProfile(profile: Profile, release: boolean): WriteResult
	local attempts = if release then RELEASE_ATTEMPTS else 1

	for attempt = 1, attempts do
		waitForBudget()

		local outcome: WriteResult = "Failed"
		local ok, err = pcall(function()
			getStore():UpdateAsync(profile.Key, function(record: any)
				if not isValidRecord(record) or not isOwnedByLoad(record.Meta, profile.LoadId) then
					outcome = "SessionLost"
					return nil -- отмена записи: ключ принадлежит другой загрузке (другой сервер или новый профиль)
				end

				record.Data = profile.Data
				record.Meta.LastUpdate = os.time()
				if release then
					record.Meta.ActiveSession = nil
				end

				outcome = "Saved"
				return record, { profile.UserId }
			end)
		end)

		if ok then
			return outcome
		end

		warn(`[ProfileStoreService] Ошибка записи {profile.Key} (попытка {attempt}/{attempts}): {err}`)
		if attempt < attempts then
			task.wait(RELEASE_RETRY_DELAY)
		end
	end

	-- Лок (если это релиз) остаётся висеть: данные откатятся к последнему успешному
	-- сохранению, следующий сервер перехватит лок по п.5. Дюпа нет.
	return "Failed"
end

-- Синхронная (без yield) регистрация релиза. Вызывается до любого task.spawn/yield,
-- чтобы следующая загрузка того же UserId гарантированно увидела релиз в полёте (п.7).
local function beginRelease(profile: Profile)
	pendingReleases += 1
	releasingUserIds[profile.UserId] = (releasingUserIds[profile.UserId] or 0) + 1
end

local function finishRelease(profile: Profile)
	acquireBusy(profile) -- дожидаемся автосейва в полёте (п.8)

	if profile.Active then
		profile.Active = false
		local result = writeProfile(profile, true)
		if result == "SessionLost" then
			warn(`[ProfileStoreService] {profile.Key}: при релизе лок уже чужой — финальная запись отменена`)
		elseif result == "Failed" then
			warn(`[ProfileStoreService] {profile.Key}: финальная запись не удалась, лок остаётся до перехвата`)
		end
	end

	releaseBusy(profile)

	local remaining = (releasingUserIds[profile.UserId] or 1) - 1
	releasingUserIds[profile.UserId] = if remaining > 0 then remaining else nil
	pendingReleases -= 1
end

local function releaseInternal(profile: Profile)
	beginRelease(profile)
	finishRelease(profile)
end

function ProfileStoreService.Init(options: InitOptions)
	assert(store == nil, "ProfileStoreService.Init вызван повторно")

	createDefaultData = options.CreateDefaultData
	onSessionLost = options.OnSessionLost

	local isStudio = RunService:IsStudio()

	-- В Studio DataStore недоступен двумя способами, и оба ведут в один fallback:
	-- GetDataStore бросает ошибку (плейс не опубликован: «You must publish this place to the web»)
	-- либо пробная запись отклоняется (выключен доступ к API). Вне Studio ошибка не глотается:
	-- молчаливое in-memory хранилище на живом сервере означало бы потерю прогресса.
	local gotStore, realStore = pcall(function()
		return DataStoreService:GetDataStore(options.StoreName) :: any
	end)
	if not gotStore then
		if not isStudio then
			error(realStore, 0)
		end
		warn(`[ProfileStoreService] DataStore недоступен в Studio ({realStore}) — используется in-memory хранилище, прогресс НЕ сохраняется`)
		store = createMockStore()
		isMockStore = true
		return
	end

	if isStudio then
		-- Пробный UpdateAsync с отменой записи: падает, если в Studio выключен доступ к API.
		local ok = pcall(function()
			realStore:UpdateAsync("__AccessCheck", function()
				return nil
			end)
		end)
		if not ok then
			warn("[ProfileStoreService] DataStore недоступен в Studio — используется in-memory хранилище, прогресс НЕ сохраняется")
			store = createMockStore()
			isMockStore = true
			return
		end
	end

	store = realStore
end

-- Цикл попыток захвата лока. Вызывается только из LoadProfile, когда UserId уже
-- отмечен в loadingUserIds.
local function loadInternal(player: Player, makeDefault: () -> PlayerProfile): Profile?
	local userId = player.UserId
	local key = KEY_PREFIX .. tostring(userId)
	local loadId = HttpService:GenerateGUID(false)
	local sessionTag: SessionTag = {
		LoadId = loadId,
		ServerId = SERVER_ID,
		PlaceId = game.PlaceId,
		JobId = game.JobId,
	}

	for attempt = 1, MAX_LOAD_ATTEMPTS do
		if shuttingDown or player.Parent == nil then
			return nil
		end

		local forceSteal = attempt == MAX_LOAD_ATTEMPTS
		local now = os.time()

		local outcome: "Loaded" | "Locked" | nil = nil
		local loadedRecord: any = nil

		waitForBudget()

		local ok, err = pcall(function()
			getStore():UpdateAsync(key, function(record: any)
				-- Transform может вызываться несколько раз (п.1) — результат берём из последнего вызова.
				outcome = nil
				loadedRecord = nil

				if record == nil then
					record = {
						Data = makeDefault(),
						Meta = { ActiveSession = nil, LastUpdate = 0, SessionLoadCount = 0 },
					}
				elseif not isValidRecord(record) then
					-- Запись без метаданных (не должно встречаться): считаем её голыми данными.
					record = {
						Data = record,
						Meta = { ActiveSession = nil, LastUpdate = 0, SessionLoadCount = 0 },
					}
				end

				local meta = record.Meta
				-- Лок чужой, даже если его поставил этот же сервер другой загрузкой (п.7).
				if meta.ActiveSession ~= nil and not isOwnedByLoad(meta, loadId) then
					local lockAge = now - (tonumber(meta.LastUpdate) or 0)
					if lockAge < STALE_LOCK_SECONDS and not forceSteal then
						outcome = "Locked"
						return nil -- п.2: профиль занят живым сервером — ничего не пишем, ждём
					end
					-- п.5: лок брошен или ждать больше нельзя — перехватываем.
				end

				meta.ActiveSession = sessionTag
				meta.LastUpdate = now
				meta.SessionLoadCount = (tonumber(meta.SessionLoadCount) or 0) + 1

				outcome = "Loaded"
				loadedRecord = record
				return record, { userId }
			end)
		end)

		if ok and outcome == "Loaded" then
			local profile: Profile = {
				Player = player,
				UserId = userId,
				Key = key,
				Data = loadedRecord.Data,
				SessionLoadCount = loadedRecord.Meta.SessionLoadCount,
				LoadId = loadId,
				Active = true,
			}

			if player.Parent == nil or shuttingDown then
				-- Игрок ушёл / сервер выключается, пока шла загрузка: лок уже наш — сразу отдаём.
				-- beginRelease синхронно, ДО task.spawn и до снятия loadingUserIds (п.7).
				beginRelease(profile)
				task.spawn(finishRelease, profile)
				return nil
			end

			profiles[player] = profile
			return profile
		end

		if ok then
			warn(`[ProfileStoreService] {key} занят другим сервером, попытка {attempt}/{MAX_LOAD_ATTEMPTS}`)
		else
			warn(`[ProfileStoreService] Ошибка загрузки {key} (попытка {attempt}/{MAX_LOAD_ATTEMPTS}): {err}`)
		end

		if attempt < MAX_LOAD_ATTEMPTS then
			task.wait(LOAD_RETRY_DELAY)
		end
	end

	return nil
end

function ProfileStoreService.LoadProfile(player: Player): Profile?
	local existing = profiles[player]
	if existing then
		return existing
	end

	local makeDefault = createDefaultData
	assert(makeDefault, "ProfileStoreService.Init не был вызван")

	local userId = player.UserId

	-- п.7: дожидаемся и загрузки, и релиза этого же UserId на этом же сервере.
	while (loadingUserIds[userId] or releasingUserIds[userId]) and player.Parent ~= nil do
		task.wait(0.1)
	end

	if player.Parent == nil then
		return nil
	end

	-- Повторный вызов для того же Player (например, двойной PlayerAdded): пока ждали,
	-- первая загрузка уже могла завершиться — отдаём её профиль, второй лок не берём.
	existing = profiles[player]
	if existing then
		return existing
	end

	-- Между выходом из цикла ожидания и этой строкой нет yield — отметка атомарна.
	loadingUserIds[userId] = true
	local ok, result = pcall(loadInternal, player, makeDefault)
	loadingUserIds[userId] = nil

	if not ok then
		warn(`[ProfileStoreService] Ошибка загрузки профиля {userId}: {result}`)
		return nil
	end

	return result
end

function ProfileStoreService.GetProfile(player: Player): Profile?
	return profiles[player]
end

function ProfileStoreService.SaveProfile(player: Player): boolean
	local profile = profiles[player]
	if profile == nil or not profile.Active then
		return false
	end

	acquireBusy(profile)

	if not profile.Active then
		-- Пока ждали мьютекс, профиль освободили — писать больше нельзя.
		releaseBusy(profile)
		return false
	end

	local result = writeProfile(profile, false)
	releaseBusy(profile)

	if result == "SessionLost" then
		handleSessionLost(profile)
	end

	return result == "Saved"
end

function ProfileStoreService.ReleaseProfile(player: Player)
	local profile = profiles[player]
	if profile == nil then
		return
	end

	profiles[player] = nil
	releaseInternal(profile)
end

function ProfileStoreService.ReleaseAll()
	shuttingDown = true

	for player in profiles do
		task.spawn(ProfileStoreService.ReleaseProfile, player)
	end

	-- Ждём и свои релизы, и уже запущенные из PlayerRemoving (п.6).
	local deadline = os.clock() + SHUTDOWN_TIMEOUT
	while pendingReleases > 0 and os.clock() < deadline do
		task.wait(0.1)
	end

	if pendingReleases > 0 then
		warn(`[ProfileStoreService] Выключение: {pendingReleases} профилей не успели освободиться`)
	end
end

return ProfileStoreService
