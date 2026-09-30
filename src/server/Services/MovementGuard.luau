--!strict

--[[
	MovementGuard — серверная проверка достоверности позиции игрока (анти-чит, раздел 7 ТЗ).

	Позиция HumanoidRootPart на сервере — это то, что прислал клиент через репликацию
	персонажа (у клиента network ownership): телепорт-эксплойт двигает её мгновенно. Поэтому
	системы с проверкой дистанции (сбор, Хаос-босс, рейд) читают не root.Position, а
	GetTrustedPosition(player) — последнюю ДОВЕРЕННУЮ точку.

	Проверка: смещение текущей позиции от доверенной точки должно быть правдоподобным за время,
	прошедшее с её установки (потолки скорости — server-only MovementGuardConfig, отдельно по
	горизонтали, вверх и вниз; превышение на джиттер/пачки репликации списывается из «ведра»
	допуска). Правдоподобно — доверенная точка сдвигается на текущую позицию и возвращается;
	скачок — возвращается прежняя точка (до скачка), в лог не больше одного предупреждения на
	игрока за окно.

	- Окно скользящее: скорость считается от последней принятой точки, а не от первой за сессию.
	  Фоновый замер всех игроков раз в SampleInterval держит точку свежей — иначе телепорт после
	  долгой паузы между запросами прятался бы в большом dt.
	- Допуск — ведро, а не прибавка на каждый замер: поток запросов клиента (RequestCollect с
	  отказом тоже вызывает замер) не складывает допуск в скорость выше потолка — длительно не
	  быстрее MaxHorizontalSpeed + BurstRefillRate при любой частоте вызовов.
	- После отклонённого скачка или периода без живого корня игрок «под подозрением»: точка
	  догоняет его только на RecoverySpeed (≈ честная ходьба). Телепорт + ожидание не быстрее
	  ходьбы, а честного игрока после редкого физического «флинга» отпускает без респавна.
	  Отката персонажа на сервере (PivotTo) нет — это отдельное решение по геймплею.
	- Респавн — не телепорт: подписка на Player.CharacterAdded сбрасывает базовую точку, новая
	  берётся с позиции спавна, когда движок поставил персонажа в Workspace (плюс кадр) — раньше,
	  чем клиент получит персонажа и сможет его сдвинуть. До этого доверенной позиции нет (nil,
	  а не «первая попавшаяся» позиция из запроса клиента). Сменить Player.Character может
	  только сервер (LoadCharacter/CharacterAutoLoads; клиентская запись не реплицируется),
	  поэтому новый персонаж до обработки CharacterAdded тоже просто ждёт базу. При появлении
	  нескольких SpawnLocation или короткого RespawnTime самоубийство станет бесплатным
	  телепортом на спавн — вернуться к этому пункту.
	- Без Init (юнит-тесты систем) базу ставит первый замер: подписки на CharacterAdded нет,
	  ждать её не от кого. После Init этот путь недостижим — базу ставит только спавн.
	- Неконечные координаты (NaN/inf) доверенной точкой не становятся никогда.
	- Нет живого персонажа (нет Humanoid/HumanoidRootPart, Health ≤ 0) — nil.
	- Игрок вышел — состояние и подписка удаляются (PlayerRemoving); запрос после выхода
	  состояние не воскрешает.
	- Легитимное ускорение (бафф Speed Boost, BuffSystem): SetSpeedMultiplier(player, k) —
	  горизонтальный потолок, потолок подъёма, RecoverySpeed и ведро допуска (ёмкость и
	  пополнение) умножаются на k: игрок под баффом проверяется так же, как обычный, только
	  «в k раз быстрее». Падение (MaxFallSpeed) от WalkSpeed не зависит и не масштабируется.
	  k задаёт только сервер (клиентского входа нет), зажат в [1, MaxSpeedMultiplier].
	  Рост k — сразу; снижение (бафф истёк) — прежний k держится ещё SpeedDropGrace секунд:
	  пока новый WalkSpeed реплицируется клиенту, персонаж ещё бежит быстро, и честного игрока
	  на стыке не должно флагать. Множитель — у игрока, а не у персонажа: респавн его не сбрасывает.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local MovementGuardConfig = require(script.Parent.Parent.Config.MovementGuardConfig)

type PlayerState = {
	-- Персонаж, к которому относится доверенная точка.
	Character: Model?,
	-- nil — базовая точка персонажа ещё не установлена.
	Trusted: Vector3?,
	TrustedAt: number,
	-- Остаток ведра допуска (studs) на момент TrustedAt.
	Burst: number,
	-- После отклонённого скачка / периода без корня: точка догоняет только на RecoverySpeed.
	Suspect: boolean,
	-- Init уже подписан на CharacterAdded этого игрока (повторный trackPlayer — no-op).
	Tracked: boolean,
	Connection: RBXScriptConnection?,
	LastWarnAt: number,
	-- Множитель потолков скорости от легитимного ускорения (SetSpeedMultiplier), ≥ 1.
	SpeedMultiplier: number,
	-- Множитель до последнего снижения — действует до GraceUntil (os.clock()).
	GraceMultiplier: number,
	GraceUntil: number,
}

local MovementGuard = {}

local states: { [Player]: PlayerState } = {}
-- Init вызван: базу ставит только обработчик спавна (путь «база с первого замера» закрыт).
local initialized = false

local function getState(player: Player): PlayerState
	local state = states[player]
	if not state then
		state = {
			Character = nil,
			Trusted = nil,
			TrustedAt = 0,
			Burst = 0,
			Suspect = false,
			Tracked = false,
			Connection = nil,
			LastWarnAt = -math.huge,
			SpeedMultiplier = 1,
			GraceMultiplier = 1,
			GraceUntil = -math.huge,
		}
		states[player] = state
	end
	return state
end

local function getAliveRoot(character: Model?): BasePart?
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
		return nil
	end
	return root
end

local function isFiniteVector(v: Vector3): boolean
	return math.abs(v.X) < math.huge and math.abs(v.Y) < math.huge and math.abs(v.Z) < math.huge
end

-- Действующий множитель потолков скорости: после снижения прежний держится до GraceUntil.
local function speedFactor(state: PlayerState, now: number): number
	if now < state.GraceUntil then
		return math.max(state.SpeedMultiplier, state.GraceMultiplier)
	end
	return state.SpeedMultiplier
end

-- Смещение from → to за dt секунд: сколько studs сверх потолков скорости (0 — в пределах).
-- factor — множитель легитимного ускорения (speedFactor); на падение не влияет.
local function excessMovement(from: Vector3, to: Vector3, dt: number, suspect: boolean, factor: number): number
	local c = MovementGuardConfig
	local horizontalSpeed = factor * (if suspect then c.RecoverySpeed else c.MaxHorizontalSpeed)
	local riseSpeed = factor * (if suspect then math.min(c.RecoverySpeed, c.MaxRiseSpeed) else c.MaxRiseSpeed)
	local dx, dy, dz = to.X - from.X, to.Y - from.Y, to.Z - from.Z
	local horizontal = math.sqrt(dx * dx + dz * dz)
	local vertical = if dy >= 0 then dy - riseSpeed * dt else -dy - c.MaxFallSpeed * dt
	return math.max(horizontal - horizontalSpeed * dt, 0) + math.max(vertical, 0)
end

local function setTrusted(state: PlayerState, position: Vector3, now: number, burst: number)
	state.Trusted = position
	state.TrustedAt = now
	state.Burst = burst
end

local function reportJump(player: Player, state: PlayerState, from: Vector3, to: Vector3, dt: number, now: number)
	if now - state.LastWarnAt < MovementGuardConfig.SuspiciousLogWindow then
		return
	end
	state.LastWarnAt = now
	local distance = (to - from).Magnitude
	warn(
		`[MovementGuard] Подозрительный скачок позиции: {player.Name} ({player.UserId}), `
			.. `{string.format("%.1f", distance)} studs за {string.format("%.2f", dt)} с — доверенная позиция не сдвинута`
	)
end

local function resetCharacter(state: PlayerState, character: Model?)
	state.Character = character
	state.Trusted = nil
	state.Suspect = false
end

-- Один замер: сверяет текущую позицию корня с доверенной и возвращает позицию, которой можно
-- верить (nil — нет живого персонажа или базовой точки).
local function sample(player: Player, state: PlayerState, now: number): Vector3?
	local character = player.Character
	if character ~= state.Character then
		resetCharacter(state, character)
	end

	local root = getAliveRoot(character)
	if not root then
		-- Время без замера не должно копить «запас» скорости на возвращение корня.
		if state.Trusted then
			state.Suspect = true
		end
		return nil
	end
	local position = root.Position

	local trusted = state.Trusted
	if trusted == nil then
		if initialized or not isFiniteVector(position) then
			return nil
		end
		setTrusted(state, position, now, MovementGuardConfig.BurstAllowance)
		return position
	end

	local dt = now - state.TrustedAt
	local factor = speedFactor(state, now)
	local burst = math.min(
		MovementGuardConfig.BurstAllowance * factor,
		state.Burst + MovementGuardConfig.BurstRefillRate * factor * dt
	)
	local excess = excessMovement(trusted, position, dt, state.Suspect, factor)
	if isFiniteVector(position) and excess <= burst then
		setTrusted(state, position, now, burst - excess)
		state.Suspect = false
		return position
	end

	state.Suspect = true
	reportJump(player, state, trusted, position, dt, now)
	return trusted
end

-- Базовая точка нового персонажа — с позиции спавна: ждём, пока движок поставит его в
-- Workspace с корнем, и ещё кадр на позиционирование.
local function captureSpawnBaseline(player: Player, state: PlayerState, character: Model)
	local function isCurrent(): boolean
		return states[player] == state and state.Character == character
	end

	-- Медленная загрузка не оставляет игрока без базы навсегда: после SpawnRootTimeout — одно
	-- предупреждение и ожидание дальше, реже. Цикл кончается с выходом игрока/новым персонажем.
	local deadline = os.clock() + MovementGuardConfig.SpawnRootTimeout
	local warned = false
	while isCurrent() and not (character:IsDescendantOf(Workspace) and getAliveRoot(character)) do
		if os.clock() > deadline then
			if not warned then
				warned = true
				warn(`[MovementGuard] Нет HumanoidRootPart у персонажа {player.Name} ({player.UserId}) — базовая точка ждёт корня`)
			end
			task.wait(MovementGuardConfig.SampleInterval)
		else
			task.wait()
		end
	end
	task.wait()

	local root = getAliveRoot(character)
	if isCurrent() and state.Trusted == nil and root and isFiniteVector(root.Position) then
		setTrusted(state, root.Position, os.clock(), MovementGuardConfig.BurstAllowance)
	end
end

local function onCharacterAdded(player: Player, character: Model)
	local state = states[player]
	if not state or player.Parent == nil then
		return
	end
	resetCharacter(state, character)
	task.spawn(captureSpawnBaseline, player, state, character)
end

local function trackPlayer(player: Player)
	if player.Parent == nil then
		return
	end
	local state = getState(player)
	if state.Tracked then
		return
	end
	state.Tracked = true
	state.Connection = player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)
	local character = player.Character
	if character then
		onCharacterAdded(player, character)
	end
end

-- Фоновый замер: каждый игрок в своём pcall — сломанный персонаж одного не останавливает остальных.
local function sampleAll()
	local now = os.clock()
	for _, player in Players:GetPlayers() do
		local state = states[player]
		if state and player.Parent ~= nil then
			local ok, err = pcall(sample, player, state, now)
			if not ok then
				warn(`[MovementGuard] Ошибка замера позиции {player.Name} ({player.UserId}): {err}`)
			end
		end
	end
end

-- Позиция игрока, которой можно верить в проверках дистанции: текущая, если перемещение
-- правдоподобно, иначе последняя доверенная. nil — нет живого персонажа/базовой точки или
-- игрок уже вышел.
function MovementGuard.GetTrustedPosition(player: Player): Vector3?
	if player.Parent == nil then
		return nil
	end
	return sample(player, getState(player), os.clock())
end

-- Множитель потолков скорости от легитимного серверного ускорения (бафф Speed Boost):
-- WalkSpeed под баффом / базовый WalkSpeed; 1 — ускорения нет. Вне [1, MaxSpeedMultiplier]
-- зажимается (NaN/inf — ошибка вызывающего, считается 1: проверку не ослабляем).
function MovementGuard.SetSpeedMultiplier(player: Player, multiplier: number)
	if player.Parent == nil then
		return
	end
	if not (multiplier >= 1 and multiplier < math.huge) then
		if multiplier ~= multiplier or multiplier == math.huge or multiplier == -math.huge then
			warn(`[MovementGuard] Некорректный множитель скорости {multiplier} для {player.Name} ({player.UserId}) — считаем 1`)
		end
		multiplier = 1
	end
	multiplier = math.min(multiplier, MovementGuardConfig.MaxSpeedMultiplier)

	local state = getState(player)
	if multiplier == state.SpeedMultiplier then
		return
	end
	if multiplier < state.SpeedMultiplier then
		local now = os.clock()
		state.GraceMultiplier = speedFactor(state, now)
		state.GraceUntil = now + MovementGuardConfig.SpeedDropGrace
	end
	state.SpeedMultiplier = multiplier
end

function MovementGuard.Init()
	initialized = true
	Players.PlayerAdded:Connect(trackPlayer)
	for _, player in Players:GetPlayers() do
		trackPlayer(player)
	end

	Players.PlayerRemoving:Connect(function(player)
		local state = states[player]
		states[player] = nil
		if state and state.Connection then
			state.Connection:Disconnect()
		end
	end)

	task.spawn(function()
		while true do
			task.wait(MovementGuardConfig.SampleInterval)
			sampleAll()
		end
	end)
end

return MovementGuard
