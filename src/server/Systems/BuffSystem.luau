--!strict

--[[
	BuffSystem — временные платные баффы Magnet Boost и Speed Boost (BuffConfig; дев-продукты
	DevProductConfig с Reward.Kind "Buff").

	- Выдача — только Grant, и только из MonetizationSystem.applyReward: внутри без-yield секции
	  ProcessReceipt, вместе с маркером квитанции. Повторная доставка квитанции маркером
	  отсекается там же — второй Grant на ту же покупку не вызывается.
	- Профиль: Buffs.<Id>ExpiresAt = os.time() конца баффа (по образцу PvP.ShieldExpiresAt —
	  переживает выход и смену сервера, время идёт и офлайн). Стекинг: ExpiresAt =
	  max(ExpiresAt, now) + Duration. Битое значение (не число, NaN, inf) — бафф не активен;
	  Grant на таком профиле отказывает без записи (квитанция ждёт повтора), как
	  MonetizationSystem при битой Currency.Essence.
	- IsActive(data, id) — чтение без побочных эффектов; магнит (CollectionSystem) спрашивает его.
	- Эффект Speed Boost применяет сервер: Humanoid.WalkSpeed и множитель потолков скорости
	  MovementGuard (SetSpeedMultiplier = WalkSpeed / BaseWalkSpeed; снижение MovementGuard
	  применяет с грейс-периодом). Сразу при Grant и на тике раз в BuffConfig.TickInterval:
	  истечение баффа, респавн (новый Humanoid) подхватываются тиком. WalkSpeed пишется, только
	  когда меняется нужное значение или Humanoid — чужие правки WalkSpeed тик не перетирает
	  без причины. Клиентского входа нет: локальная правка WalkSpeed на клиенте не поднимает
	  потолок MovementGuard, эксплойтер со спидхаком ловится как раньше.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.shared.Types)
local UpgradeEffects = require(ReplicatedStorage.shared.UpgradeEffects)
local BuffConfig = require(ReplicatedStorage.shared.Config.BuffConfig)
local MovementGuardConfig = require(script.Parent.Parent.Config.MovementGuardConfig)
local MovementGuard = require(script.Parent.Parent.Services.MovementGuard)
local DataSystem = require(script.Parent.DataSystem)

type PlayerProfile = Types.PlayerProfile
type BuffId = BuffConfig.BuffId

type PlayerState = {
	AppliedHumanoid: Humanoid?, -- Humanoid, которому последним выставлен WalkSpeed
	AppliedWalkSpeed: number?,
	ErrorReported: boolean, -- ошибка применения эффектов уже записана в лог
}

local isFinite = UpgradeEffects.IsFinite

-- Поле профиля (раздел Buffs) с os.time() конца баффа.
local EXPIRES_FIELD: { [BuffId]: string } = {
	MagnetBoost = "MagnetBoostExpiresAt",
	SpeedBoost = "SpeedBoostExpiresAt",
}

for _, id in BuffConfig.BuffIds do
	assert(EXPIRES_FIELD[id], `BuffSystem: нет поля профиля для баффа {id}`)
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
		state = { AppliedHumanoid = nil, AppliedWalkSpeed = nil, ErrorReported = false }
		playerStates[player] = state
	end
	return state
end

-- os.time() конца баффа из профиля. nil — баффа не было; false — раздел/значение повреждены.
local function readExpiresAt(data: PlayerProfile, buffId: BuffId): (number | false)?
	local buffs: any = (data :: any).Buffs
	if type(buffs) ~= "table" then
		return false
	end
	local value = buffs[EXPIRES_FIELD[buffId]]
	if value == nil then
		return nil
	end
	return if isFinite(value) then value else false
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

-- Применяет эффекты баффов игрока к миру (WalkSpeed, потолок MovementGuard). Без yield.
local function applyEffects(player: Player, data: PlayerProfile)
	local walkSpeed = if BuffSystem.IsActive(data, "SpeedBoost")
		then BuffConfig.Buffs.SpeedBoost.WalkSpeed :: number
		else BuffConfig.BaseWalkSpeed
	-- Сначала потолок, потом скорость: рост потолка — сразу, снижение MovementGuard сам
	-- растягивает на SpeedDropGrace, пока клиент получает новый WalkSpeed.
	MovementGuard.SetSpeedMultiplier(player, walkSpeed / BuffConfig.BaseWalkSpeed)

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

-- Выдаёт (или продлевает) бафф: ExpiresAt = max(ExpiresAt, now) + Duration. Без yield — вызывать
-- из без-yield секции ProcessReceipt. false — бафф неизвестен или профиль повреждён, ничего
-- не изменено. Эффекты применяются сразу, не дожидаясь тика.
function BuffSystem.Grant(player: Player, data: PlayerProfile, buffId: BuffId): boolean
	local definition = BuffConfig.Buffs[buffId]
	local field = EXPIRES_FIELD[buffId]
	if definition == nil or field == nil then
		return false
	end
	local current = readExpiresAt(data, buffId)
	if current == false then
		return false
	end
	local now = os.time()
	local from = if current ~= nil and current > now then current else now
	local expiresAt = from + definition.Duration
	if not isFinite(expiresAt) then
		return false
	end
	;(data :: any).Buffs[field] = expiresAt
	if player.Parent ~= nil then
		applyEffectsSafe(player, data)
	end
	return true
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
