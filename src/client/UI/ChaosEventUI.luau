--!strict

--[[
	ChaosEventUI (раздел 5.5/5.8 ТЗ, S14): оверлей ивента «Вторжение Кошмара».

	- Всё показанное — из последнего снимка Хаоса сервера (Remotes.ChaosSnapshot), который
	  отдаёт HUD (GetChaosSnapshot/ChaosChanged): полоса HP босса, личный вклад игрока.
	  ChaosEventUI на ремоут сам не подписывается (см. HUD).
	- Оверлей виден только пока snapshot.Active. Он на весь экран, но прозрачный для ввода:
	  игроку нужно дойти до босса, камера и движение не должны блокироваться.
	- Кнопка «Атаковать» шлёт intent RequestAttackBoss() без аргументов. Кулдаун и проверка
	  дистанции на клиенте — только UX (не слать запросы, которые сервер заведомо отклонит):
	  урон, попадание, кулдаун и дистанцию считает сервер.
	- Снимок завершения (Ended) — короткое сообщение с исходом и полученной наградой
	  (0, если игрок не участвовал), как реакция на RebirthAck в HUD.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Types = require(ReplicatedStorage.shared.Types)
local Loc = require(ReplicatedStorage.shared.Loc)
local Remotes = require(ReplicatedStorage.shared.Remotes)
local Signal = require(ReplicatedStorage.shared.Signal)
local ChaosBossConfig = require(ReplicatedStorage.shared.Config.ChaosBossConfig)

type ChaosSnapshot = Types.ChaosSnapshot
type ChaosEventResult = Types.ChaosEventResult

export type ChaosSource = {
	GetChaosSnapshot: () -> ChaosSnapshot?,
	ChaosChanged: Signal.Signal,
}

local BOSS_NAME = "ChaosBoss"
-- Как часто обновлять доступность кнопки (дистанция до босса), пока идёт ивент.
local RANGE_CHECK_INTERVAL = 0.2
local RESULT_SECONDS = 5

-- Строки UI пока здесь; в таблицу локализации (раздел 10 ТЗ) переедут вместе с остальным UI.
local TEXT = {
	Title = Loc.Get("ChaosEventUI.Title"),
	Health = Loc.Get("ChaosEventUI.Health"),
	Contribution = Loc.Get("ChaosEventUI.Contribution"),
	Attack = Loc.Get("ChaosEventUI.Attack"),
	TooFar = Loc.Get("ChaosEventUI.TooFar"),
	Victory = Loc.Get("ChaosEventUI.Victory"),
	Timeout = Loc.Get("ChaosEventUI.Timeout"),
	Reward = Loc.Get("ChaosEventUI.Reward"),
	NoReward = Loc.Get("ChaosEventUI.NoReward"),
}

local BUTTON_ENABLED = Color3.fromRGB(200, 60, 80)
local BUTTON_DISABLED = Color3.fromRGB(90, 90, 90)

local ChaosEventUI = {}

local snapshot: ChaosSnapshot? = nil
local overlay: Frame
local healthFill: Frame
local healthLabel: TextLabel
local contributionLabel: TextLabel
local attackButton: TextButton
local hintLabel: TextLabel
local resultLabel: TextLabel
local cooldownUntil = 0 -- os.clock(), до которого кнопка отдыхает после клика
local rangeLoopToken = 0 -- останавливает цикл проверки дистанции прошлого ивента
local resultToken = 0 -- сбрасывает устаревший таймер скрытия сообщения
local lastEndedEventId = 0 -- итог одного ивента показываем один раз

local function formatNumber(value: number): string
	return string.format("%.0f", math.floor(value))
end

local function makeLabel(parent: Instance, size: UDim2, position: UDim2): TextLabel
	local label = Instance.new("TextLabel")
	label.Size = size
	label.Position = position
	label.AnchorPoint = Vector2.new(0.5, 0)
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.4
	label.TextScaled = true
	label.Text = ""
	label.Parent = parent
	return label
end

-- Позиция корня своего персонажа (для UX-подсказки о дистанции) или nil.
local function getRootPosition(): Vector3?
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root.Position
	end
	return nil
end

-- Близко ли к боссу — только чтобы не слать заведомо отклоняемые удары. Берём строго
-- AttackRange без серверного допуска на лаг: на границе лучше подойти на шаг ближе.
local function isInRange(): boolean
	local root = getRootPosition()
	if not root then
		return false
	end
	local boss = Workspace:FindFirstChild(BOSS_NAME)
	local bossPosition = if boss and boss:IsA("BasePart") then boss.Position else ChaosBossConfig.BossPosition
	return (root - bossPosition).Magnitude <= ChaosBossConfig.AttackRange
end

local function refreshButton()
	local active = snapshot ~= nil and snapshot.Active
	local inRange = active and isInRange()
	local cooling = os.clock() < cooldownUntil
	local enabled = active and inRange and not cooling

	attackButton.Active = enabled
	attackButton.AutoButtonColor = enabled
	attackButton.BackgroundColor3 = if enabled then BUTTON_ENABLED else BUTTON_DISABLED
	hintLabel.Text = if active and not inRange then TEXT.TooFar else ""
end

local function refreshOverlay()
	local snap = snapshot
	overlay.Visible = snap ~= nil and snap.Active
	if not snap or not snap.Active then
		return
	end
	local fraction = math.clamp(snap.BossHealth / snap.BossMaxHealth, 0, 1)
	healthFill.Size = UDim2.fromScale(fraction, 1)
	healthLabel.Text = string.format(TEXT.Health, formatNumber(snap.BossHealth), formatNumber(snap.BossMaxHealth))
	contributionLabel.Text = string.format(TEXT.Contribution, formatNumber(snap.Contribution))
	refreshButton()
end

-- Пока ивент идёт — периодически пересчитываем доступность кнопки (игрок ходит).
local function startRangeLoop()
	rangeLoopToken += 1
	local token = rangeLoopToken
	task.spawn(function()
		while rangeLoopToken == token and snapshot and snapshot.Active do
			refreshButton()
			task.wait(RANGE_CHECK_INTERVAL)
		end
	end)
end

local function showResult(ended: ChaosEventResult)
	resultToken += 1
	local token = resultToken
	local title = if ended.Outcome == "Victory" then TEXT.Victory else TEXT.Timeout
	local reward = if ended.Damage > 0
		then string.format(TEXT.Reward, formatNumber(ended.Reward))
		else TEXT.NoReward
	resultLabel.Text = `{title} {reward}`
	resultLabel.Visible = true
	task.delay(RESULT_SECONDS, function()
		if resultToken == token then
			resultLabel.Visible = false
		end
	end)
end

local function onChaosChanged(newSnapshot: ChaosSnapshot)
	local wasActive = snapshot ~= nil and snapshot.Active
	snapshot = newSnapshot
	refreshOverlay()
	if newSnapshot.Active and not wasActive then
		startRangeLoop()
	end

	local ended = newSnapshot.Ended
	if ended and ended.EventId ~= lastEndedEventId then
		lastEndedEventId = ended.EventId
		showResult(ended)
	end
end

-- Клик: только intent без аргументов. Кулдаун — UX, сервер проверяет свой.
local function onAttackClicked()
	if not snapshot or not snapshot.Active or os.clock() < cooldownUntil or not isInRange() then
		return
	end
	cooldownUntil = os.clock() + ChaosBossConfig.AttackCooldown
	refreshButton()
	Remotes.RequestAttackBoss:FireServer()

	local until_ = cooldownUntil
	task.delay(ChaosBossConfig.AttackCooldown, function()
		if cooldownUntil == until_ then
			refreshButton()
		end
	end)
end

local function build(): ScreenGui
	local gui = Instance.new("ScreenGui")
	gui.Name = "ChaosEventUI"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 5 -- поверх HUD

	-- Весь экран, но без фона и без перехвата ввода: камера и движение работают как обычно.
	overlay = Instance.new("Frame")
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.BackgroundTransparency = 1
	overlay.Active = false
	overlay.Visible = false
	overlay.Parent = gui

	-- Верх по центру: CoreGui занимает только углы (чат слева, список игроков справа).
	local title = makeLabel(overlay, UDim2.fromOffset(420, 34), UDim2.new(0.5, 0, 0, 8))
	title.Text = TEXT.Title
	title.TextColor3 = Color3.fromRGB(240, 120, 140)

	local bar = Instance.new("Frame")
	bar.Size = UDim2.fromOffset(520, 30)
	bar.AnchorPoint = Vector2.new(0.5, 0)
	bar.Position = UDim2.new(0.5, 0, 0, 46)
	bar.BackgroundColor3 = Color3.fromRGB(40, 20, 40)
	bar.BackgroundTransparency = 0.2
	bar.Parent = overlay
	healthFill = Instance.new("Frame")
	healthFill.Size = UDim2.fromScale(1, 1)
	healthFill.BackgroundColor3 = Color3.fromRGB(200, 50, 70)
	healthFill.BorderSizePixel = 0
	healthFill.Parent = bar
	healthLabel = makeLabel(bar, UDim2.fromScale(1, 1), UDim2.fromScale(0.5, 0))

	contributionLabel = makeLabel(overlay, UDim2.fromOffset(420, 26), UDim2.new(0.5, 0, 0, 82))

	-- Кнопка — низ по центру: нижние углы заняты HUD (Rebirth слева, апгрейды справа).
	attackButton = Instance.new("TextButton")
	attackButton.Size = UDim2.fromOffset(240, 60)
	attackButton.AnchorPoint = Vector2.new(0.5, 1)
	attackButton.Position = UDim2.new(0.5, 0, 1, -24)
	attackButton.TextColor3 = Color3.new(1, 1, 1)
	attackButton.TextScaled = true
	attackButton.Text = TEXT.Attack
	attackButton.Parent = overlay
	attackButton.Activated:Connect(onAttackClicked)

	hintLabel = makeLabel(overlay, UDim2.fromOffset(360, 24), UDim2.new(0.5, 0, 1, -114))

	-- Итог ивента — вне оверлея: после завершения оверлей скрыт, а сообщение ещё видно.
	resultLabel = makeLabel(gui, UDim2.fromOffset(560, 36), UDim2.new(0.5, 0, 0, 120))
	resultLabel.TextColor3 = Color3.fromRGB(255, 220, 140)
	resultLabel.Visible = false

	return gui
end

function ChaosEventUI.Init(source: ChaosSource)
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local gui = build()
	gui.Parent = playerGui

	source.ChaosChanged:Connect(onChaosChanged)
	-- Снимок мог прийти до подписки (HUD подписан раньше) — берём последний.
	local current = source.GetChaosSnapshot()
	if current then
		onChaosChanged(current)
	end
end

return ChaosEventUI
