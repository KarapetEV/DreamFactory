--!strict

--[[
	MonetizationSystem — геймпассы (S10), дев-продукты и публикуемые шансы коконов (S12).
	Раздел 5.7 ТЗ, разделы 7 и 12 GDD.

	ГЕЙМПАССЫ. Платёж проводит сам Roblox (PromptGamePassPurchase с клиента), сервер лишь
	перечитывает владение. Roblox — внешний источник данных, ему доверяем ровно в пределах этой роли:
	- каждый вызов UserOwnsGamePassAsync — в pcall, результат обязан быть boolean; ошибка или
	  мусор = «неизвестно»: закэшированное в профиле значение НЕ трогаем, пишем в лог один
	  раз за сессию игрока;
	- вызов сетевой и может висеть: на каждый геймпасс свой поток (task.spawn), сервер и
	  остальные игроки не ждут;
	- результат применяется только если игрок ещё на сервере, профиль жив и запрос не
	  устарел: у каждой проверки «талон» (Tickets), пишет только последняя запущенная —
	  медленный ответ, отправленный ДО покупки, не затрёт свежее «куплено»;
	- аргументы PromptGamePassPurchaseFinished не принимаются на веру: wasPurchased только
	  запускает перепроверку через Roblox, владение пишется по её результату.

	Изменение владения → PetSystem.RefreshBonuses (число слотов меняет, какие петы дают
	бонус) и FactorySystem.PushSnapshot (магазин видит GamePassesOwned).

	ДЕВ-ПРОДУКТЫ (ProcessReceipt). Roblox может вызвать callback повторно с тем же PurchaseId
	(сетевой сбой, повторная доставка, вход игрока на другой сервер) и повторяет его, пока не
	получит PurchaseGranted. Требование: ни двойной выдачи, ни потери. Два маркера:

	  1. Лог квитанций — отдельный DataStore RECEIPT_LOG_STORE, ключ Receipt_<PurchaseId>.
	     Долговременный источник правды «покупка закрыта»: пишется ПОСЛЕДНИМ, только когда
	     выдача уже durable. Отдельно от профиля: квитанция может прийти, когда профиля на
	     этом сервере нет (игрок ещё грузится / уже вышел).
	  2. Monetization.ProcessedReceipts в профиле — «выдача уже в данных». Добавляется в ТОМ ЖЕ
	     изменении профиля, что и награда, и сохраняется одной записью (DataSystem.SaveNow):
	     награда и маркер не расходятся — в DataStore либо оба, либо ни одного. Маркер
	     помечается Closed после записи лога; вытесняются (сверх ProfileReceiptHistory) только
	     закрытые — незакрытый маркер единственный держит защиту от повтора.

	Порядок: лог (есть запись → PurchaseGranted) → профиль загружен? (нет → NotProcessedYet) →
	маркера в профиле нет → выдать + маркер (без yield между проверкой и записью) → SaveNow →
	запись в лог → PurchaseGranted. Любой сбой → NotProcessedYet, Roblox повторит:
	  - сбой SaveNow: выдача и маркер живут в памяти; повтор видит маркер и не выдаёт снова,
	    только досохраняет. Упал сервер — откатились оба, повтор выдаст ровно один раз;
	  - сбой записи в лог после сохранения: повтор (здесь или на другом сервере после
	    переноса профиля) видит маркер в профиле, не выдаёт, дописывает лог;
	  - одновременная доставка одного PurchaseId на этом сервере — receiptsInFlight.
	ProductId, PurchaseId и PlayerId из квитанции — только ключи поиска; размер награды —
	из DevProductConfig. Неизвестный/заглушечный ProductId и битая квитанция → NotProcessedYet
	(покупка не теряется: продукт может знать более новая версия сервера) + лог.

	Reward.Kind "BattlePassPremium" (S18) — тот же путь и тот же порядок проверок; вместо
	начисления Currency награду применяет BattlePassSystem.ApplyPremium (премиум текущего сезона
	+ ретроактивные премиум-награды пройденных тиров) в той же без-yield секции, что и маркер.

	Reward.Kind "Buff" (Magnet Boost / Speed Boost) — тот же путь; награду применяет
	BuffSystem.Grant (пак зарядов Buffs.<Id>Charges, зажато потолком BuffConfig MaxCharges — избыток
	сгорает, покупка всё равно выдана) в той же без-yield секции, что и маркер: повтор квитанции
	видит маркер и не начисляет заряды второй раз. Включает бафф игрок сам (BuffSystem.Activate).

	Аналитика (раздел 9 ТЗ): выдача дев-продукта — после записи лога квитанций (один раз на
	покупку, повтор доставки её не повторяет); геймпасс — когда Roblox подтвердил владение
	после PromptGamePassPurchaseFinished.

	ШАНСЫ КОКОНОВ. GetCocoonOddsText строит текст из PetRarityConfig (той же таблицы, что и
	ролл) через чистую OddsText.Format. Подключение к UI кокон-паков — отдельная сессия.

	Новых RemoteEvent нет: покупку открывает клиент (Prompt*Purchase), о платеже Roblox
	сообщает серверу напрямую (ProcessReceipt).
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Types = require(ReplicatedStorage.shared.Types)
local OddsText = require(ReplicatedStorage.shared.OddsText)
local UpgradeEffects = require(ReplicatedStorage.shared.UpgradeEffects)
local DevProductConfig = require(ReplicatedStorage.shared.Config.DevProductConfig)
local MonetizationConfig = require(ReplicatedStorage.shared.Config.MonetizationConfig)
local PetConfig = require(ReplicatedStorage.shared.Config.PetConfig)
local PetSpeciesConfig = require(ReplicatedStorage.shared.Config.PetSpeciesConfig)
local PetRarityConfig = require(script.Parent.Parent.Config.PetRarityConfig)
local DataSystem = require(script.Parent.DataSystem)
local FactorySystem = require(script.Parent.FactorySystem)
local PetSystem = require(script.Parent.PetSystem)
local BattlePassSystem = require(script.Parent.BattlePassSystem)
local BuffSystem = require(script.Parent.BuffSystem)
local AnalyticsSystem = require(script.Parent.AnalyticsSystem)

type GamePassDefinition = MonetizationConfig.GamePassDefinition
type DevProductDefinition = DevProductConfig.DevProductDefinition
type PlayerProfile = Types.PlayerProfile
type ReceiptMarker = Types.ReceiptMarker

-- Минимальный интерфейс лога квитанций (DataStore или in-memory замена в Studio).
type ReceiptLogStore = {
	GetAsync: (self: any, key: string, options: any?) -> any,
	UpdateAsync: (self: any, key: string, transform: (any, any) -> (any, any)) -> any,
}

local RECEIPT_LOG_STORE = "PurchaseLog"
local RECEIPT_KEY_PREFIX = "Receipt_"
-- Ключ DataStore — не длиннее 50 символов.
local MAX_PURCHASE_ID_LENGTH = 50 - #RECEIPT_KEY_PREFIX

local isFinite = UpgradeEffects.IsFinite

type PlayerState = {
	Tickets: { [string]: number }, -- Id геймпасса -> номер последней запущенной проверки
	FailureReported: boolean, -- сбой Roblox API уже записан в лог
	CorruptionReported: boolean, -- битый раздел Monetization уже записан в лог
}

local passesById: { [string]: GamePassDefinition } = {}
local passesByGamePassId: { [number]: GamePassDefinition } = {}
for _, pass in MonetizationConfig.GamePasses do
	passesById[pass.Id] = pass
	if pass.GamePassId ~= 0 then
		passesByGamePassId[pass.GamePassId] = pass
	end
end
assert(
	passesById[PetConfig.ExtraSlotsGamePassId],
	`MonetizationSystem: геймпасс {PetConfig.ExtraSlotsGamePassId} из PetConfig отсутствует в MonetizationConfig`
)

local productsByProductId: { [number]: DevProductDefinition } = {}
for _, product in DevProductConfig.Products do
	if product.ProductId ~= 0 then
		productsByProductId[product.ProductId] = product
	end
end

local MonetizationSystem = {}

local playerStates: { [Player]: PlayerState } = {}

local receiptLog: ReceiptLogStore? = nil
-- PurchaseId, которые обрабатываются прямо сейчас (повторная доставка во время yield).
local receiptsInFlight: { [string]: true } = {}
-- ProductId без описания в DevProductConfig, о которых уже написали в лог.
local reportedUnknownProducts: { [number]: true } = {}

local function getPlayerState(player: Player): PlayerState
	local state = playerStates[player]
	if not state then
		state = { Tickets = {}, FailureReported = false, CorruptionReported = false }
		playerStates[player] = state
	end
	return state
end

local function reportFailure(player: Player, state: PlayerState, pass: GamePassDefinition, err: unknown)
	if state.FailureReported then
		return
	end
	state.FailureReported = true
	warn(
		`[MonetizationSystem] Не удалось проверить геймпасс {pass.Id} у {player.Name} ({player.UserId}), `
			.. `оставляем закэшированное владение: {err}`
	)
end

-- Запрос владения у Roblox. true/false — ответ; nil — «неизвестно» (сбой или мусор).
-- Yield'ит: вызывать только из отдельного потока.
local function fetchOwnership(player: Player, state: PlayerState, pass: GamePassDefinition): boolean?
	local ok, result = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, pass.GamePassId)
	end)
	if not ok then
		reportFailure(player, state, pass, result)
		return nil
	end
	if type(result) ~= "boolean" then
		reportFailure(player, state, pass, `неожиданный ответ {typeof(result)}`)
		return nil
	end
	return result
end

-- Записывает владение в профиль. true — список изменился. Чужие Id в списке не трогаем.
local function applyOwnership(player: Player, state: PlayerState, pass: GamePassDefinition, owns: boolean): boolean
	local data = DataSystem.GetData(player)
	if not data then
		return false -- профиль освобождён (игрок вышел) — писать некуда
	end

	local monetization = data.Monetization
	if type(monetization) ~= "table" then
		if not state.CorruptionReported then
			state.CorruptionReported = true
			warn(`[MonetizationSystem] Раздел Monetization повреждён: {player.Name} ({player.UserId})`)
		end
		return false
	end
	-- Список — производное от Roblox значение, его можно восстановить перечитыванием.
	if type(monetization.GamePassesOwned) ~= "table" then
		monetization.GamePassesOwned = {}
	end

	local owned = monetization.GamePassesOwned
	local changed = false
	local index = table.find(owned, pass.Id)
	if owns and not index then
		table.insert(owned, pass.Id)
		changed = true
	elseif not owns then
		while index do
			table.remove(owned, index)
			changed = true
			index = table.find(owned, pass.Id)
		end
	end
	return changed
end

-- Перечитывает владение одним геймпассом и применяет результат. Возвращает ответ Roblox
-- (nil — сбой). Yield'ит.
local function refreshPass(player: Player, pass: GamePassDefinition): boolean?
	if player.Parent == nil then
		return nil
	end
	local state = getPlayerState(player)
	local ticket = (state.Tickets[pass.Id] or 0) + 1
	state.Tickets[pass.Id] = ticket

	local owns = fetchOwnership(player, state, pass)

	-- После yield: игрок мог выйти, а после него — запуститься более свежая проверка.
	if owns == nil or playerStates[player] ~= state or player.Parent == nil then
		return owns
	end
	if state.Tickets[pass.Id] ~= ticket then
		return owns
	end

	if applyOwnership(player, state, pass, owns) then
		PetSystem.RefreshBonuses(player)
		FactorySystem.PushSnapshot(player)
	end
	return owns
end

local function checkAllPasses(player: Player)
	task.spawn(function()
		local data = DataSystem.WaitForData(player)
		if not data or player.Parent == nil then
			return
		end
		for _, pass in MonetizationConfig.GamePasses do
			if pass.GamePassId ~= 0 then
				task.spawn(refreshPass, player, pass)
			end
		end
	end)
end

local function onPurchaseFinished(player: Player, gamePassId: unknown, wasPurchased: unknown)
	if wasPurchased ~= true or type(gamePassId) ~= "number" or player.Parent == nil then
		return
	end
	local pass = passesByGamePassId[gamePassId]
	if not pass then
		return
	end

	task.spawn(function()
		for attempt = 1, MonetizationConfig.PurchaseRecheckAttempts do
			if player.Parent == nil then
				return
			end
			if refreshPass(player, pass) == true then
				AnalyticsSystem.LogEvent(player, AnalyticsSystem.Events.GamePassPurchased, 1, pass.Id)
				return
			end
			if attempt < MonetizationConfig.PurchaseRecheckAttempts then
				task.wait(MonetizationConfig.PurchaseRecheckDelay)
			end
		end
		warn(
			`[MonetizationSystem] Покупка {pass.Id} у {player.Name} ({player.UserId}) завершена, но Roblox `
				.. `не подтвердил владение за {MonetizationConfig.PurchaseRecheckAttempts} проверок; `
				.. "владение обновится при следующем входе"
		)
	end)
end

------------------------------------------------------------------------------------------
-- Дев-продукты: ProcessReceipt
------------------------------------------------------------------------------------------

-- In-memory лог для Studio без доступа к API (как mock-хранилище ProfileStoreService):
-- позволяет проверить тестовые покупки. Живёт до конца процесса сервера.
local function createMemoryReceiptLog(): ReceiptLogStore
	local records: { [string]: string } = {}
	local memory = {}
	function memory.GetAsync(_self: any, key: string, _options: any?): any
		local encoded = records[key]
		return if encoded then HttpService:JSONDecode(encoded) else nil
	end
	function memory.UpdateAsync(self: any, key: string, transform: (any, any) -> (any, any)): any
		local newValue = transform(memory.GetAsync(self, key), nil)
		if newValue ~= nil then
			records[key] = HttpService:JSONEncode(newValue)
		end
		return newValue
	end
	return memory :: any
end

-- Лог квитанций. nil — DataStore недоступен (квитанции ждут повтора). Сбой в проде не
-- кэшируется: следующая квитанция попробует снова.
local function getReceiptLog(): ReceiptLogStore?
	if receiptLog then
		return receiptLog
	end
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(RECEIPT_LOG_STORE)
	end)
	-- В Studio, как в ProfileStoreService: без публикации бросает GetDataStore, при выключенном
	-- доступе к API — первый запрос (пробный UpdateAsync с отменой записи).
	if ok and RunService:IsStudio() then
		ok = pcall(function()
			result:UpdateAsync("__AccessCheck", function()
				return nil
			end)
		end)
	end
	if ok then
		receiptLog = result
	elseif RunService:IsStudio() then
		warn("[MonetizationSystem] DataStore недоступен в Studio — лог квитанций в памяти процесса")
		receiptLog = createMemoryReceiptLog()
	else
		warn(`[MonetizationSystem] Лог квитанций недоступен, квитанции будут повторены: {result}`)
	end
	return receiptLog
end

-- ok = true и запись (nil — покупка в логе не закрыта); ok = false — сбой чтения.
-- Без кэша DataStore: квитанцию мог закрыть другой сервер секунды назад.
local function readReceiptLog(store: ReceiptLogStore, purchaseId: string): (boolean, any)
	return pcall(function()
		local options = Instance.new("DataStoreGetOptions")
		options.UseCache = false
		return store:GetAsync(RECEIPT_KEY_PREFIX .. purchaseId, options)
	end)
end

local function writeReceiptLog(
	store: ReceiptLogStore,
	purchaseId: string,
	playerId: number,
	product: DevProductDefinition
): boolean
	local ok, err = pcall(function()
		store:UpdateAsync(RECEIPT_KEY_PREFIX .. purchaseId, function(existing: any)
			if existing ~= nil then
				return nil -- уже закрыта (например, другим сервером) — не перезаписываем
			end
			return {
				PlayerId = playerId,
				ProductId = product.ProductId,
				Product = product.Id,
				GrantedAt = os.time(),
			},
				{ playerId }
		end)
	end)
	if not ok then
		warn(`[MonetizationSystem] Не удалось записать квитанцию {purchaseId} в лог, ждём повтора: {err}`)
	end
	return ok
end

-- Начисляет награду продукта в профиль (без yield). false — профиль повреждён, ничего не изменено.
local function applyReward(player: Player, data: PlayerProfile, product: DevProductDefinition): boolean
	local reward = product.Reward
	if reward.Kind == "BattlePassPremium" then
		if not BattlePassSystem.ApplyPremium(player, data) then
			warn(`[MonetizationSystem] Не выдан {product.Id} игроку {player.Name} ({player.UserId}): профиль повреждён`)
			return false
		end
		return true
	end
	if reward.Kind == "Buff" then
		if not BuffSystem.Grant(player, data, reward.BuffId :: any) then
			warn(
				`[MonetizationSystem] Не выдан {product.Id} игроку {player.Name} ({player.UserId}): `
					.. "повреждён раздел Buffs"
			)
			return false
		end
		return true
	end
	if reward.Kind == "Essence" then
		local currency: any = data.Currency
		local essence = if type(currency) == "table" then currency.Essence else nil
		local newEssence = if isFinite(essence) then essence + (reward.Amount :: number) else nil
		if newEssence == nil or not isFinite(newEssence) then
			warn(
				`[MonetizationSystem] Не выдан {product.Id} игроку {player.Name} ({player.UserId}): `
					.. `повреждена Currency.Essence = {tostring(essence)}`
			)
			return false
		end
		currency.Essence = newEssence
		return true
	end
	warn(`[MonetizationSystem] Неизвестный Reward.Kind {reward.Kind} у {product.Id}`)
	return false
end

-- Маркеры выдачи в профиле. nil — раздел повреждён: выдавать нельзя, иначе пропала бы
-- защита от повторной доставки.
local function getProcessedReceipts(player: Player, data: PlayerProfile): { ReceiptMarker }?
	local monetization: any = data.Monetization
	local receipts = if type(monetization) == "table" then monetization.ProcessedReceipts else nil
	if type(receipts) ~= "table" then
		warn(
			`[MonetizationSystem] Monetization.ProcessedReceipts повреждён у {player.Name} ({player.UserId}): `
				.. "квитанции не обрабатываются"
		)
		return nil
	end
	return receipts
end

local function findMarker(receipts: { ReceiptMarker }, purchaseId: string): ReceiptMarker?
	for _, marker in receipts do
		if type(marker) == "table" and marker.Id == purchaseId then
			return marker
		end
	end
	return nil
end

-- Вытесняет старейшие ЗАКРЫТЫЕ маркеры сверх ProfileReceiptHistory. Незакрытый маркер (выдача
-- сохранена, лог ещё не записан) — единственная защита от повторной выдачи, его не трогаем.
local function trimClosedMarkers(receipts: { ReceiptMarker })
	local excess = #receipts - DevProductConfig.ProfileReceiptHistory
	local index = 1
	while excess > 0 and index <= #receipts do
		local marker: any = receipts[index]
		if type(marker) ~= "table" or marker.Closed == true then
			table.remove(receipts, index)
			excess -= 1
		else
			index += 1
		end
	end
end

-- Обработка уже проверенной квитанции. Yield'ит.
local function grantReceipt(
	playerId: number,
	product: DevProductDefinition,
	purchaseId: string
): Enum.ProductPurchaseDecision
	local Decision = Enum.ProductPurchaseDecision

	local store = getReceiptLog()
	if not store then
		return Decision.NotProcessedYet
	end
	local readOk, record = readReceiptLog(store, purchaseId)
	if not readOk then
		warn(`[MonetizationSystem] Не удалось прочитать лог квитанции {purchaseId}, ждём повтора: {record}`)
		return Decision.NotProcessedYet
	end
	if record ~= nil then
		-- Уже выдано и закрыто (повторная доставка). Если флаг Closed в профиле не успел
		-- сохраниться — закрываем маркер сейчас, чтобы он мог вытесняться.
		local player = Players:GetPlayerByUserId(playerId)
		local data = if player then DataSystem.GetData(player) else nil
		local monetization: any = if data then data.Monetization else nil
		if type(monetization) == "table" and type(monetization.ProcessedReceipts) == "table" then
			local marker = findMarker(monetization.ProcessedReceipts, purchaseId)
			if marker then
				marker.Closed = true
			end
		end
		return Decision.PurchaseGranted
	end

	-- Профиль не загружен (игрок грузится, вышел или на другом сервере) — выдать некуда.
	-- Roblox повторит квитанцию, в том числе при следующем входе игрока.
	local player = Players:GetPlayerByUserId(playerId)
	if player == nil then
		return Decision.NotProcessedYet
	end
	local data = DataSystem.GetData(player)
	if data == nil then
		return Decision.NotProcessedYet
	end
	local receipts = getProcessedReceipts(player, data)
	if receipts == nil then
		return Decision.NotProcessedYet
	end

	-- Проверка маркера, выдача и маркер — без yield: повтор не вклинится между ними.
	local marker = findMarker(receipts, purchaseId)
	if marker == nil then
		if not applyReward(player, data, product) then
			return Decision.NotProcessedYet
		end
		local newMarker: ReceiptMarker = { Id = purchaseId, Closed = false }
		marker = newMarker
		table.insert(receipts, newMarker)
		trimClosedMarkers(receipts)
		FactorySystem.PushSnapshot(player)
	end

	-- Выдача + маркер должны лечь в DataStore до закрытия квитанции.
	if not DataSystem.SaveNow(player) then
		warn(`[MonetizationSystem] Квитанция {purchaseId}: профиль {playerId} не сохранён, ждём повтора`)
		return Decision.NotProcessedYet
	end
	if not writeReceiptLog(store, purchaseId, playerId, product) then
		return Decision.NotProcessedYet
	end
	AnalyticsSystem.LogEvent(player, AnalyticsSystem.Events.DevProductPurchased, 1, product.Id)
	-- Квитанция закрыта логом — маркер можно вытеснять. В DataStore флаг попадёт со следующим
	-- сохранением; не попадёт (краш) — маркер просто проживёт дольше, двойной выдачи это не даёт.
	marker.Closed = true
	return Decision.PurchaseGranted
end

-- Callback MarketplaceService.ProcessReceipt. Не бросает: любой сбой — NotProcessedYet.
function MonetizationSystem.ProcessReceipt(receiptInfo: unknown): Enum.ProductPurchaseDecision
	local Decision = Enum.ProductPurchaseDecision

	local info: any = receiptInfo
	if type(info) ~= "table" then
		warn(`[MonetizationSystem] Квитанция не таблица: {typeof(receiptInfo)}`)
		return Decision.NotProcessedYet
	end
	local playerId, productId, purchaseId = info.PlayerId, info.ProductId, info.PurchaseId
	if
		not isFinite(playerId)
		or playerId <= 0
		or playerId % 1 ~= 0
		or not isFinite(productId)
		or type(purchaseId) ~= "string"
		or purchaseId == ""
		or #purchaseId > MAX_PURCHASE_ID_LENGTH
	then
		warn(
			`[MonetizationSystem] Битая квитанция: PlayerId = {tostring(playerId)}, `
				.. `ProductId = {tostring(productId)}, PurchaseId = {tostring(purchaseId)}`
		)
		return Decision.NotProcessedYet
	end

	local product = productsByProductId[productId]
	if product == nil then
		if not reportedUnknownProducts[productId] then
			reportedUnknownProducts[productId] = true
			warn(`[MonetizationSystem] Квитанция на неизвестный ProductId {productId} (нет в DevProductConfig)`)
		end
		return Decision.NotProcessedYet
	end

	if receiptsInFlight[purchaseId] then
		return Decision.NotProcessedYet
	end
	receiptsInFlight[purchaseId] = true
	local ok, result = pcall(grantReceipt, playerId, product, purchaseId)
	receiptsInFlight[purchaseId] = nil
	if not ok then
		warn(`[MonetizationSystem] Ошибка обработки квитанции {purchaseId}: {result}`)
		return Decision.NotProcessedYet
	end
	return result
end

------------------------------------------------------------------------------------------
-- Шансы коконов
------------------------------------------------------------------------------------------

-- Публикуемый текст шансов кокона из той же таблицы, что и ролл. nil — нет такого кокона.
function MonetizationSystem.GetCocoonOddsText(cocoonId: string): string?
	local odds = PetRarityConfig.Cocoons[cocoonId]
	if odds == nil then
		return nil
	end
	return OddsText.Format(odds, PetSpeciesConfig.RarityDisplayNames)
end

function MonetizationSystem.Init()
	for _, pass in MonetizationConfig.GamePasses do
		if pass.GamePassId == 0 then
			warn(`[MonetizationSystem] У геймпасса {pass.Id} GamePassId = 0 (заглушка): проверка владения пропущена`)
		end
	end
	for _, product in DevProductConfig.Products do
		if product.ProductId == 0 then
			warn(`[MonetizationSystem] У дев-продукта {product.Id} ProductId = 0 (заглушка): выдача отключена`)
		end
	end

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(onPurchaseFinished)
	-- Единственный обработчик квитанций игры: ProcessReceipt назначается только здесь.
	MarketplaceService.ProcessReceipt = MonetizationSystem.ProcessReceipt

	Players.PlayerAdded:Connect(checkAllPasses)
	for _, player in Players:GetPlayers() do
		checkAllPasses(player)
	end

	Players.PlayerRemoving:Connect(function(player)
		playerStates[player] = nil
	end)
end

return MonetizationSystem
