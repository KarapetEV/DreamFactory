--!strict

--[[
	BuffSystem — временные платные баффы Magnet Boost и Speed Boost (BuffConfig; дев-продукты
	DevProductConfig с Reward.Kind "Buff"). Модель зарядов: покупка даёт заряды, игрок сам
	тратит заряд на активацию из HUD.

	- Grant — начисление пака: Charges += PackSize, зажато в [0, MaxCharges] (избыток сгорает,
	  покупка всё равно считается выданной). Вызывается только из MonetizationSystem.applyReward —
	  внутри без-yield секции ProcessReceipt, вместе с маркером квитанции: повторная доставка
	  квитанции отсекается маркером, второй Grant на ту же покупку не вызывается. Время баффа
	  Grant не трогает.
	- Activate — трата заряда: если Charges > 0 и бафф сейчас не действует — Charges − 1 и
	  ExpiresAt = now + Duration, эффект сразу. Иначе ничего (повторный клик во время действия
	  заряд не тратит). Одна функция без yield: проверка и запись не разрываются.
	- Remotes.ActivateBuff(buffId) — единственный клиентский вход: rate limit (RateLimiter, как у
	  RequestCollect), buffId только из BuffConfig.BuffIds, дальше Activate. Клиенту ничего не
	  возвращаем — новое состояние он видит по атрибутам.
	- Профиль: Buffs.<Id>Charges (целое ≥ 0) и Buffs.<Id>ExpiresAt = os.time() конца действия (по
	  образцу PvP.ShieldExpiresAt — переживает выход и смену сервера, время идёт и офлайн). Битое
	  значение — бафф не действует; Grant/Activate на таком профиле отказывают без записи
	  (квитанция ждёт повтора), как MonetizationSystem при битой Currency.Essence.
	- IsActive(data, id) — чтение без побочных эффектов; магнит (CollectionSystem) спрашивает его.
	- Эффект Speed Boost применяет сервер: Humanoid.WalkSpeed и множитель потолков скорости
	  MovementGuard (SetSpeedMultiplier = WalkSpeed / BaseWalkSpeed; снижение MovementGuard
	  применяет с грейс-периодом). Сразу при Activate и на тике раз в BuffConfig.TickInterval:
	  истечение баффа, респавн (новый Humanoid) подхватываются тиком. WalkSpeed пишется, только
	  когда меняется нужное значение или Humanoid — чужие правки WalkSpeed тик не перетирает
	  без причины. Локальная правка WalkSpeed на клиенте не поднимает потолок MovementGuard.
	- Для HUD и магазина — атрибуты игрока Attributes.<Id>ExpiresAt (nil — не действует) и
	  Attributes.<Id>Charges (nil — данные битые). Только отображение: сервер их не читает.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.shared.Types)
local Attributes = require(ReplicatedStorage.shared.Attributes)
local UpgradeEffects = require(ReplicatedStorage.shared.UpgradeEffects)
local BuffConfig = require(ReplicatedStorage.shared.Config.BuffConfig)
local MovementGuardConfig = require(script.Parent.Parent.Config.MovementGuardConfig)
local MovementGuard = require(script.Parent.Parent.Services.MovementGuard)
local RateLimiter = require(script.Parent.Parent.Services.RateLimiter)
local DataSystem = require(script.Parent.DataSystem)

type PlayerProfile = Types.PlayerProfile
type BuffId = BuffConfig.BuffId

type PlayerState = {
	AppliedHumanoid: Humanoid?, -- Humanoid, которому последним выставлен WalkSpeed
	AppliedWalkSpeed: number?,
	ErrorReported: boolean, -- ошибка применения эффектов уже записана в лог
	RequestTimes: { number }, -- метки вызовов ActivateBuff в текущем окне rate limit
}

local isFinite = UpgradeEffects.IsFinite

-- Поля профиля (раздел Buffs) и одноимённые атрибуты игрока.
local EXPIRES_FIELD: { [BuffId]: string } = {
	MagnetBoost = "MagnetBoostExpiresAt",
	SpeedBoost = "SpeedBoostExpiresAt",
}
local CHARGES_FIELD: { [BuffId]: string } = {
	MagnetBoost = "MagnetBoostCharges",
	SpeedBoost = "SpeedBoostCharges",
}

for _, id in BuffConfig.BuffIds do
	for _, fields in { EXPIRES_FIELD, CHARGES_FIELD } do
		assert(fields[id], `BuffSystem: нет поля профиля для баффа {id}`)
		assert((Attributes :: any)[fields[id]], `BuffSystem: нет атрибута {fields[id]} в Attributes`)
	end
end
-- Потолок MovementGuard зажимает множитель: бафф быстрее него флагал бы честных игроков.
assert(
	(BuffConfig.Buffs.SpeedBoost.WalkSpeed :: number) / BuffConfig.BaseWalkSpeed
		<= MovementGuardConfig.MaxSpeedMultiplier,
	"BuffSystem: WalkSpeed Speed Boost превышает MovementGuardConfig.MaxSpeedMultiplier"
)

local BuffSystem = {}

local playerStates: { [Player]: PlayerState } = {}

local function getPlayerState(player: Player): PlayerState
	local state = playerStates[player]
	if not state then
		state = { AppliedHumanoid = nil, AppliedWalkSpeed = nil, ErrorReported = false, RequestTimes = {} }
		playerStates[player] = state
	end
	return state
end

local function getBuffs(data: PlayerProfile): any
	local buffs: any = (data :: any).Buffs
	return if type(buffs) == "table" then buffs else nil
end

-- os.time() конца баффа из профиля. nil — баффа не было; false — раздел/значение повреждены.
local function readExpiresAt(data: PlayerProfile, buffId: BuffId): (number | false)?
	local buffs = getBuffs(data)
	if buffs == nil then
		return false
	end
	local value = buffs[EXPIRES_FIELD[buffId]]
	if value == nil then
		return nil
	end
	return if isFinite(value) then value else false
end

-- Заряды из профиля: целое ≥ 0 (нет поля — 0); false — раздел/значение повреждены.
local function readCharges(data: PlayerProfile, buffId: BuffId): number | false
	local buffs = getBuffs(data)
	if buffs == nil then
		return false
	end
	local value = buffs[CHARGES_FIELD[buffId]]
	if value == nil then
		return 0
	end
	if isFinite(value) and value >= 0 and value % 1 == 0 then
		return value
	end
	return false
end

-- Бафф действует в момент now (os.time(); по умолчанию — сейчас). Битые данные — не действует.
function BuffSystem.IsActive(data: PlayerProfile, buffId: BuffId, now: number?): boolean
	local expiresAt = readExpiresAt(data, buffId)
	return type(expiresAt) == "number" and expiresAt > (now or os.time())
end

-- os.time() конца действующего баффа; nil — не действует.
function BuffSystem.GetExpiresAt(data: PlayerProfile, buffId: BuffId): number?
	local expiresAt = readExpiresAt(data, buffId)
	if type(expiresAt) == "number" and expiresAt > os.time() then
		return expiresAt
	end
	return nil
end

-- Сколько зарядов у игрока; nil — данные повреждены.
function BuffSystem.GetCharges(data: PlayerProfile, buffId: BuffId): number?
	local charges = readCharges(data, buffId)
	return if charges == false then nil else charges
end

local function setAttributeIfChanged(player: Player, name: string, value: any)
	if player:GetAttribute(name) ~= value then
		player:SetAttribute(name, value)
	end
end

-- Применяет эффекты баффов игрока к миру (WalkSpeed, потолок MovementGuard) и обновляет
-- атрибуты для HUD. Без yield.
local function applyEffects(player: Player, data: PlayerProfile)
	local walkSpeed = if BuffSystem.IsActive(data, "SpeedBoost")
		then BuffConfig.Buffs.SpeedBoost.WalkSpeed :: number
		else BuffConfig.BaseWalkSpeed
	-- Сначала потолок, потом скорость: рост потолка — сразу, снижение MovementGuard сам
	-- растягивает на SpeedDropGrace, пока клиент получает новый WalkSpeed.
	MovementGuard.SetSpeedMultiplier(player, walkSpeed / BuffConfig.BaseWalkSpeed)

	-- Атрибуты только при изменении (репликация — лишь по факту смены).
	for _, id in BuffConfig.BuffIds do
		setAttributeIfChanged(player, (Attributes :: any)[EXPIRES_FIELD[id]], BuffSystem.GetExpiresAt(data, id))
		setAttributeIfChanged(player, (Attributes :: any)[CHARGES_FIELD[id]], BuffSystem.GetCharges(data, id))
	end

	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	if humanoid == nil then
		return
	end
	local state = getPlayerState(player)
	if state.AppliedHumanoid ~= humanoid or state.AppliedWalkSpeed ~= walkSpeed then
		humanoid.WalkSpeed = walkSpeed
		state.AppliedHumanoid = humanoid
		state.AppliedWalkSpeed = walkSpeed
	end
end

local function applyEffectsSafe(player: Player, data: PlayerProfile)
	local ok, err = pcall(applyEffects, player, data)
	if not ok then
		-- Состояние вышедшего игрока не воскрешаем.
		local state = if player.Parent then getPlayerState(player) else nil
		if state and not state.ErrorReported then
			state.ErrorReported = true
			warn(`[BuffSystem] Ошибка применения баффов у {player.Name} ({player.UserId}): {err}`)
		end
	end
end

-- Начисляет пак зарядов: Charges = min(Charges + PackSize, MaxCharges), но не меньше, чем было.
-- Без yield — вызывать из
-- без-yield секции ProcessReceipt. true — покупка выдана (в том числе если весь пак сгорел на
-- потолке); false — бафф неизвестен или профиль повреждён, ничего не изменено.
function BuffSystem.Grant(player: Player, data: PlayerProfile, buffId: BuffId): boolean
	local definition = BuffConfig.Buffs[buffId]
	local field = CHARGES_FIELD[buffId]
	if definition == nil or field == nil then
		return false
	end
	local current = readCharges(data, buffId)
	if current == false then
		return false
	end
	-- Потолок режет только новый пак: если MaxCharges снизили в конфиге, уже оплаченные заряды
	-- сверх него покупка не отнимает.
	getBuffs(data)[field] = math.max(current, math.min(current + definition.PackSize, definition.MaxCharges))
	if player.Parent ~= nil then
		applyEffectsSafe(player, data) -- атрибут зарядов — сразу
	end
	return true
end

-- Тратит заряд на активацию баффа. nil — бафф запущен (ExpiresAt = now + Duration, эффект сразу);
-- иначе причина отказа, ничего не изменено. Проверки и запись — без yield.
function BuffSystem.Activate(player: Player, buffId: BuffId): string?
	local definition = BuffConfig.Buffs[buffId]
	if definition == nil or CHARGES_FIELD[buffId] == nil then
		return "unknown-buff"
	end
	local data = DataSystem.GetData(player)
	if data == nil then
		return "no-profile"
	end
	local charges = readCharges(data, buffId)
	local expiresAt = readExpiresAt(data, buffId)
	if charges == false or expiresAt == false then
		return "corrupt-buffs"
	end
	local now = os.time()
	if expiresAt ~= nil and expiresAt > now then
		return "already-active" -- повторный клик во время действия заряд не тратит
	end
	if charges <= 0 then
		return "no-charges"
	end

	local buffs = getBuffs(data)
	buffs[CHARGES_FIELD[buffId]] = charges - 1
	buffs[EXPIRES_FIELD[buffId]] = now + definition.Duration
	if player.Parent ~= nil then
		applyEffectsSafe(player, data)
	end
	return nil
end

-- Клиентский вход: только buffId; всё остальное (заряды, срок) — из профиля.
local function onActivateBuff(player: Player, buffId: unknown)
	-- Запрос после PlayerRemoving не должен воскрешать состояние (утечка в playerStates).
	if player.Parent == nil then
		return
	end
	local state = getPlayerState(player)
	if
		not RateLimiter.Allow(
			state.RequestTimes,
			os.clock(),
			BuffConfig.ActivateRequestWindow,
			BuffConfig.MaxActivateRequestsPerWindow
		)
	then
		return
	end
	if type(buffId) ~= "string" or BuffConfig.Buffs[buffId :: any] == nil then
		return
	end
	BuffSystem.Activate(player, buffId :: BuffId)
end

local function tick()
	for _, player in Players:GetPlayers() do
		local data = DataSystem.GetData(player)
		if data and player.Parent ~= nil then
			applyEffectsSafe(player, data)
		end
	end
end

function BuffSystem.Init()
	-- Remotes — только здесь: BuffSystem грузят транзитивно (MonetizationSystem → Grant) системы и
	-- тесты, которым реестр RemoteEvent не нужен; создаётся он при первом require.
	local Remotes = require(ReplicatedStorage.shared.Remotes)
	Remotes.ActivateBuff.OnServerEvent:Connect(onActivateBuff)

	Players.PlayerRemoving:Connect(function(player)
		playerStates[player] = nil
	end)

	task.spawn(function()
		while true do
			task.wait(BuffConfig.TickInterval)
			local ok, err = pcall(tick)
			if not ok then
				warn(`[BuffSystem] Ошибка тика баффов: {err}`)
			end
		end
	end)
end

return BuffSystem
