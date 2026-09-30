--!strict

--[[
	HUD (MVP, раздел 5.8 ТЗ): счётчик Essence и кнопки апгрейда для треков UpgradeConfig, кроме снятых с продажи (Retired).

	- Всё, что показывается про игрока (Essence, сырые фрагменты, уровни), — из последнего
	  снимка сервера (Remotes.EconomySnapshot); ёмкость склада — из уровня через UpgradeEffects.
	  Цену и значение эффекта следующего уровня HUD берёт сам из UpgradeConfig/UpgradeEffects.
	- Клик шлёт intent PurchaseUpgrade(id, targetLevel), где targetLevel = подтверждённый
	  сервером уровень + 1. Локально уровень не поднимается: новое значение придёт снимком.
	- Кнопка блокируется до ответа сервера (снимок с PurchaseAck = id) или до таймаута —
	  это только против визуального рассинхрона. Неактивность на MaxLevel и при нехватке
	  Essence — тоже только UX: сервер перепроверяет всё сам.
	- Для других экранов (ShopUI) HUD отдаёт последний снимок (GetSnapshot/SnapshotChanged) и
	  место под кнопку меню (AddMenuButton): экран не подписывается на ремоут сам — события,
	  пришедшие до подписки, доставляются только первому подписчику, а он — HUD.
	- Индикатор Хаоса сервера (раздел 5.8) виден всегда: шкала ChaosLevel/ActivationThreshold
	  из Remotes.ChaosSnapshot (во время ивента — надпись о вторжении). Тот же снимок HUD
	  отдаёт ChaosEventUI (GetChaosSnapshot/ChaosChanged) по той же причине, что и выше.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.shared.Types)
local Loc = require(ReplicatedStorage.shared.Loc)
local Remotes = require(ReplicatedStorage.shared.Remotes)
local Signal = require(ReplicatedStorage.shared.Signal)
local UpgradeConfig = require(ReplicatedStorage.shared.Config.UpgradeConfig)
local UpgradeEffects = require(ReplicatedStorage.shared.UpgradeEffects)
local BiomeConfig = require(ReplicatedStorage.shared.Config.BiomeConfig)
local RebirthConfig = require(ReplicatedStorage.shared.Config.RebirthConfig)

type EconomySnapshot = Types.EconomySnapshot
type ChaosSnapshot = Types.ChaosSnapshot

-- Сколько ждать ответа на покупку, прежде чем разблокировать кнопку (ответ мог не прийти,
-- например запрос отброшен rate limit'ом сервера).
local PENDING_TIMEOUT = 3
-- То же для PerformRebirth и время показа реакции на RebirthAck.
local REBIRTH_PENDING_TIMEOUT = 3
local REBIRTH_RESULT_SECONDS = 2.5

-- Порядок строк и подписи значений эффектов. Строки UI пока здесь; в таблицу локализации
-- (раздел 10 ТЗ) переедут вместе с остальным UI.
-- CollectionRadius снят с продажи (UpgradeConfig.Retired) — строки нет.
local TRACK_ORDER = { "ConveyorSpeed", "StorageCapacity", "CollectionSpeed" }
local VALUE_FORMATS: { [string]: string } = {
	ConveyorSpeed = "%.2f с/цикл",
	StorageCapacity = "%.0f фрагм.",
	CollectionSpeed = "%.2f с",
}
local TEXT = {
	EssenceLabel = Loc.Get("HUD.EssenceLabel"),
	BiomeLabel = Loc.Get("HUD.BiomeLabel"),
	ClarityLabel = Loc.Get("HUD.ClarityLabel"),
	RebirthProgress = Loc.Get("HUD.RebirthProgress"),
	RebirthButton = Loc.Get("HUD.RebirthButton"),
	RebirthDone = Loc.Get("HUD.RebirthDone"),
	RebirthDenied = Loc.Get("HUD.RebirthDenied"),
	FragmentsLabel = Loc.Get("HUD.FragmentsLabel"),
	Waiting = Loc.Get("HUD.Waiting"),
	Buy = Loc.Get("HUD.Buy"),
	Max = Loc.Get("HUD.Max"),
	Pending = Loc.Get("HUD.Pending"),
	ChaosLabel = Loc.Get("HUD.ChaosLabel"),
	ChaosActive = Loc.Get("HUD.ChaosActive"),
	ChaosIncoming = Loc.Get("HUD.ChaosIncoming"),
}

local BUTTON_ENABLED = Color3.fromRGB(80, 170, 90)
local BUTTON_DISABLED = Color3.fromRGB(90, 90, 90)

for _, id in TRACK_ORDER do
	assert(UpgradeConfig[id], `HUD: трек {id} отсутствует в UpgradeConfig`)
	assert(not UpgradeConfig[id].Retired, `HUD: трек {id} снят с продажи`)
end

type Row = {
	Id: string,
	Info: TextLabel,
	Button: TextButton,
	PendingSince: number?, -- os.clock() отправки PurchaseUpgrade, пока ждём ответа
}

local HUD = {}

-- (snapshot: EconomySnapshot) — после каждого валидного снимка сервера.
HUD.SnapshotChanged = Signal.new()
-- (snapshot: ChaosSnapshot) — после каждого валидного снимка Хаоса.
HUD.ChaosChanged = Signal.new()

local snapshot: EconomySnapshot? = nil
local menuFrame: Frame
local menuButtonCount = 0
local essenceLabel: TextLabel
local fragmentsLabel: TextLabel
local rows: { [string]: Row } = {}

-- Индикатор Хаоса (под счётчиком Essence; только отображение, кликов нет).
local chaosSnapshot: ChaosSnapshot? = nil
local chaosBarFill: Frame
local chaosLabel: TextLabel

-- Блок Rebirth (левый нижний угол): биом/множитель из снимка, прогресс Essence → MinEssence.
local biomeLabel: TextLabel
local clarityLabel: TextLabel
local rebirthBarFill: Frame
local rebirthBarLabel: TextLabel
local rebirthButton: TextButton
local rebirthResultLabel: TextLabel
local rebirthPendingSince: number? = nil -- os.clock() отправки PerformRebirth, пока ждём ответа
local rebirthResultToken = 0 -- сбрасывает устаревший таймер скрытия реакции

local function formatValue(id: string, value: number): string
	return string.format(VALUE_FORMATS[id] or "%.2f", value)
end

local function makeLabel(parent: Instance, text: string, size: UDim2, position: UDim2): TextLabel
	local label = Instance.new("TextLabel")
	label.Size = size
	label.Position = position
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.5
	label.TextScaled = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Text = text
	label.Parent = parent
	return label
end

-- Уровень трека из подтверждённого снимка или nil, если снимка ещё нет / значение битое.
local function getConfirmedLevel(id: string): number?
	if not snapshot then
		return nil
	end
	local level = snapshot.Levels[id]
	if not UpgradeEffects.IsValidLevel(id, level) then
		return nil
	end
	return level
end

local function refreshRow(row: Row)
	local track = UpgradeConfig[row.Id]
	local level = getConfirmedLevel(row.Id)
	local essence = if snapshot then snapshot.Essence else 0

	local enabled = false
	if level == nil then
		row.Info.Text = `{track.DisplayName}: {TEXT.Waiting}`
		row.Button.Text = "-"
	else
		local current = formatValue(row.Id, UpgradeEffects.GetEffectValue(row.Id, level))
		if level >= track.MaxLevel then
			row.Info.Text = `{track.DisplayName} [{level}/{track.MaxLevel}]: {current}`
			row.Button.Text = TEXT.Max
		else
			local nextStep = track.Levels[level + 1]
			row.Info.Text = `{track.DisplayName} [{level}/{track.MaxLevel}]: {current} → {formatValue(row.Id, nextStep.Value)}`
			if row.PendingSince then
				row.Button.Text = TEXT.Pending
			else
				row.Button.Text = string.format(TEXT.Buy, nextStep.Price)
				enabled = essence >= nextStep.Price
			end
		end
	end

	row.Button.Active = enabled
	row.Button.AutoButtonColor = enabled
	row.Button.BackgroundColor3 = if enabled then BUTTON_ENABLED else BUTTON_DISABLED
end

-- Всё в блоке — из подтверждённого снимка и RebirthConfig. Неактивность кнопки ниже порога и
-- во время запроса — не только UX: закрывает M-4 (отказы below-threshold копились бы в
-- счётчике подозрительной активности сервера). Сервер всё равно перепроверяет порог сам.
local function refreshRebirth()
	local essence = if snapshot and UpgradeEffects.IsFinite(snapshot.Essence) then snapshot.Essence else nil
	local minEssence = RebirthConfig.MinEssence

	if snapshot then
		local biomeId = snapshot.CurrentBiome
		local biome = BiomeConfig[biomeId]
		biomeLabel.Text = string.format(TEXT.BiomeLabel, if biome then biome.DisplayName else biomeId)
		clarityLabel.Text = string.format(
			TEXT.ClarityLabel,
			if UpgradeEffects.IsFinite(snapshot.ClarityMultiplier) then snapshot.ClarityMultiplier else 1,
			if UpgradeEffects.IsFinite(snapshot.RebirthCount) then snapshot.RebirthCount else 0
		)
	else
		biomeLabel.Text = string.format(TEXT.BiomeLabel, "-")
		clarityLabel.Text = TEXT.Waiting
	end

	local fraction = if essence then math.clamp(essence / minEssence, 0, 1) else 0
	rebirthBarFill.Size = UDim2.fromScale(fraction, 1)
	rebirthBarLabel.Text = string.format(
		TEXT.RebirthProgress,
		if essence then string.format("%.0f", math.floor(essence)) else "?",
		string.format("%.0f", minEssence)
	)

	local enabled = essence ~= nil and essence >= minEssence and rebirthPendingSince == nil
	rebirthButton.Text = if rebirthPendingSince then TEXT.Pending else TEXT.RebirthButton
	rebirthButton.Active = enabled
	rebirthButton.AutoButtonColor = enabled
	rebirthButton.BackgroundColor3 = if enabled then BUTTON_ENABLED else BUTTON_DISABLED
end

local function refreshAll()
	local essence = if snapshot and UpgradeEffects.IsFinite(snapshot.Essence)
		then string.format("%.0f", math.floor(snapshot.Essence))
		else TEXT.Waiting
	essenceLabel.Text = string.format(TEXT.EssenceLabel, essence)

	-- Ёмкость — из подтверждённого уровня склада и конфига, как и остальные значения эффектов.
	local raw = if snapshot and UpgradeEffects.IsFinite(snapshot.RawFragments)
		then string.format("%.0f", math.floor(snapshot.RawFragments))
		else TEXT.Waiting
	local capacityLevel = getConfirmedLevel("StorageCapacity")
	local capacity = if capacityLevel
		then string.format("%.0f", UpgradeEffects.GetEffectValue("StorageCapacity", capacityLevel))
		else "?"
	fragmentsLabel.Text = string.format(TEXT.FragmentsLabel, raw, capacity)
	for _, row in rows do
		refreshRow(row)
	end
	refreshRebirth()
end

local function onPurchaseClicked(row: Row)
	if row.PendingSince then
		return
	end
	local level = getConfirmedLevel(row.Id)
	local track = UpgradeConfig[row.Id]
	if
		level == nil
		or level >= track.MaxLevel
		or not snapshot
		or not UpgradeEffects.IsFinite(snapshot.Essence)
		or snapshot.Essence < track.Levels[level + 1].Price
	then
		return
	end

	row.PendingSince = os.clock()
	refreshRow(row)
	Remotes.PurchaseUpgrade:FireServer(row.Id, level + 1)

	-- Страховка на случай, если ответ не придёт.
	local sentAt = row.PendingSince
	task.delay(PENDING_TIMEOUT, function()
		if row.PendingSince == sentAt then
			row.PendingSince = nil
			refreshRow(row)
		end
	end)
end

-- Клик по Rebirth: только intent без аргументов. Порог и всё остальное решает сервер.
local function onRebirthClicked()
	if
		rebirthPendingSince
		or not snapshot
		or not UpgradeEffects.IsFinite(snapshot.Essence)
		or snapshot.Essence < RebirthConfig.MinEssence
	then
		return
	end

	rebirthPendingSince = os.clock()
	refreshRebirth()
	Remotes.PerformRebirth:FireServer()

	-- Страховка на случай, если ответ не придёт (запрос отброшен rate limit'ом сервера).
	local sentAt = rebirthPendingSince
	task.delay(REBIRTH_PENDING_TIMEOUT, function()
		if rebirthPendingSince == sentAt then
			rebirthPendingSince = nil
			refreshRebirth()
		end
	end)
end

-- Краткая реакция на RebirthAck; состояния поверх присланного нет — только таймер скрытия.
local function showRebirthResult(success: boolean)
	rebirthResultToken += 1
	local token = rebirthResultToken
	rebirthResultLabel.Text = if success then TEXT.RebirthDone else TEXT.RebirthDenied
	rebirthResultLabel.TextColor3 = if success then Color3.fromRGB(140, 230, 150) else Color3.fromRGB(240, 130, 130)
	task.delay(REBIRTH_RESULT_SECONDS, function()
		if rebirthResultToken == token then
			rebirthResultLabel.Text = ""
		end
	end)
end

-- Снимок приходит от сервера, но форму всё равно проверяем: битый снимок не должен ронять UI.
local function isValidSnapshot(value: unknown): boolean
	if type(value) ~= "table" then
		return false
	end
	local candidate = value :: any
	return type(candidate.Essence) == "number"
		and type(candidate.RawFragments) == "number"
		and type(candidate.Levels) == "table"
end

-- Шкала — из последнего снимка Хаоса; до первого снимка — «Загрузка...».
local function refreshChaos()
	local snap = chaosSnapshot
	if not snap then
		chaosBarFill.Size = UDim2.fromScale(0, 1)
		chaosLabel.Text = TEXT.Waiting
		return
	end
	local threshold = snap.ActivationThreshold
	local alarm = snap.Active or snap.Incoming == true
	local fraction = if alarm then 1 else math.clamp(snap.ChaosLevel / threshold, 0, 1)
	chaosBarFill.Size = UDim2.fromScale(fraction, 1)
	chaosBarFill.BackgroundColor3 = if alarm then Color3.fromRGB(220, 60, 80) else Color3.fromRGB(170, 70, 190)
	chaosLabel.Text = if snap.Active
		then TEXT.ChaosActive
		elseif snap.Incoming == true then TEXT.ChaosIncoming
		else string.format(
			TEXT.ChaosLabel,
			string.format("%.0f", math.floor(snap.ChaosLevel)),
			string.format("%.0f", threshold)
		)
end

-- Снимок Хаоса тоже проверяем по форме: битые числа не должны ронять UI.
local function isValidChaosSnapshot(value: unknown): boolean
	if type(value) ~= "table" then
		return false
	end
	local candidate = value :: any
	local isFinite = UpgradeEffects.IsFinite
	if candidate.Ended ~= nil then
		local ended = candidate.Ended
		if
			type(ended) ~= "table"
			or not isFinite(ended.Reward)
			or not isFinite(ended.Damage)
			or not isFinite(ended.EventId)
			or (ended.Outcome ~= "Victory" and ended.Outcome ~= "Timeout")
		then
			return false
		end
	end
	return isFinite(candidate.ChaosLevel)
		and isFinite(candidate.ActivationThreshold)
		and candidate.ActivationThreshold > 0
		and type(candidate.Active) == "boolean"
		and (candidate.Incoming == nil or type(candidate.Incoming) == "boolean")
		and isFinite(candidate.BossHealth)
		and isFinite(candidate.BossMaxHealth)
		and candidate.BossMaxHealth > 0
		and isFinite(candidate.EventId)
		and isFinite(candidate.Contribution)
end

local function onChaosSnapshot(value: unknown)
	if not isValidChaosSnapshot(value) then
		return
	end
	local newSnapshot = value :: ChaosSnapshot
	chaosSnapshot = newSnapshot
	refreshChaos()
	HUD.ChaosChanged:Fire(newSnapshot)
end

local function onSnapshot(value: unknown)
	if not isValidSnapshot(value) then
		return
	end
	local newSnapshot = value :: EconomySnapshot
	snapshot = newSnapshot
	HUD.SnapshotChanged:Fire(newSnapshot)

	local ack = newSnapshot.PurchaseAck
	if ack and rows[ack] then
		rows[ack].PendingSince = nil
	end
	local rebirthAck = newSnapshot.RebirthAck
	if type(rebirthAck) == "boolean" then
		rebirthPendingSince = nil
		showRebirthResult(rebirthAck)
	end
	refreshAll()
end

local function build(): ScreenGui
	local gui = Instance.new("ScreenGui")
	gui.Name = "HUD"
	gui.ResetOnSpawn = false

	local essenceFrame = Instance.new("Frame")
	essenceFrame.Size = UDim2.fromOffset(260, 80)
	essenceFrame.Position = UDim2.fromOffset(12, 12)
	essenceFrame.BackgroundColor3 = Color3.fromRGB(30, 25, 50)
	essenceFrame.BackgroundTransparency = 0.25
	essenceFrame.Parent = gui
	essenceLabel = makeLabel(essenceFrame, "", UDim2.new(1, -16, 0, 36), UDim2.fromOffset(8, 4))
	fragmentsLabel = makeLabel(essenceFrame, "", UDim2.new(1, -16, 0, 32), UDim2.fromOffset(8, 44))

	-- Индикатор Хаоса — под счётчиком Essence: левый верх занят чатом CoreGui, но индикатор
	-- только отображает, кликов в нём нет.
	local chaosFrame = Instance.new("Frame")
	chaosFrame.Size = UDim2.fromOffset(260, 34)
	chaosFrame.Position = UDim2.fromOffset(12, 98)
	chaosFrame.BackgroundColor3 = Color3.fromRGB(45, 20, 45)
	chaosFrame.BackgroundTransparency = 0.25
	chaosFrame.Parent = gui
	chaosBarFill = Instance.new("Frame")
	chaosBarFill.Size = UDim2.fromScale(0, 1)
	chaosBarFill.BackgroundColor3 = Color3.fromRGB(170, 70, 190)
	chaosBarFill.BorderSizePixel = 0
	chaosBarFill.Parent = chaosFrame
	chaosLabel = makeLabel(chaosFrame, "", UDim2.new(1, -16, 1, -6), UDim2.fromOffset(8, 3))
	chaosLabel.TextXAlignment = Enum.TextXAlignment.Center

	-- Кнопки меню (магазин и т.п.) — столбиком у левого края по центру, добавляются через
	-- AddMenuButton. Не под счётчиком Essence: левый верхний угол занят окном чата CoreGui,
	-- которое перехватывает клики (как список игроков справа сверху).
	menuFrame = Instance.new("Frame")
	menuFrame.Size = UDim2.fromOffset(160, 44)
	menuFrame.AnchorPoint = Vector2.new(0, 0.5)
	menuFrame.Position = UDim2.new(0, 12, 0.5, 0)
	menuFrame.BackgroundTransparency = 1
	menuFrame.Parent = gui

	local panel = Instance.new("Frame")
	panel.Size = UDim2.fromOffset(460, 8 + #TRACK_ORDER * 48)
	-- Правый нижний угол: верхний правый занят CoreGui (список игроков), который перехватывает
	-- клики и растёт с числом игроков на сервере; нижний угол CoreGui не использует.
	panel.AnchorPoint = Vector2.new(1, 1)
	panel.Position = UDim2.new(1, -12, 1, -12)
	panel.BackgroundColor3 = Color3.fromRGB(30, 25, 50)
	panel.BackgroundTransparency = 0.25
	panel.Parent = gui

	for index, id in TRACK_ORDER do
		local y = 8 + (index - 1) * 48

		local info = makeLabel(panel, "", UDim2.fromOffset(310, 36), UDim2.fromOffset(8, y))

		local button = Instance.new("TextButton")
		button.Size = UDim2.fromOffset(130, 36)
		button.Position = UDim2.fromOffset(322, y)
		button.TextColor3 = Color3.new(1, 1, 1)
		button.TextScaled = true
		button.Parent = panel

		local row: Row = { Id = id, Info = info, Button = button, PendingSince = nil }
		rows[id] = row
		button.Activated:Connect(function()
			onPurchaseClicked(row)
		end)
	end

	-- Блок Rebirth — левый нижний угол: CoreGui его не занимает (как и правый нижний).
	local rebirthPanel = Instance.new("Frame")
	rebirthPanel.Size = UDim2.fromOffset(260, 158)
	rebirthPanel.AnchorPoint = Vector2.new(0, 1)
	rebirthPanel.Position = UDim2.new(0, 12, 1, -12)
	rebirthPanel.BackgroundColor3 = Color3.fromRGB(30, 25, 50)
	rebirthPanel.BackgroundTransparency = 0.25
	rebirthPanel.Parent = gui

	biomeLabel = makeLabel(rebirthPanel, "", UDim2.new(1, -16, 0, 24), UDim2.fromOffset(8, 6))
	clarityLabel = makeLabel(rebirthPanel, "", UDim2.new(1, -16, 0, 22), UDim2.fromOffset(8, 32))

	local bar = Instance.new("Frame")
	bar.Size = UDim2.new(1, -16, 0, 22)
	bar.Position = UDim2.fromOffset(8, 60)
	bar.BackgroundColor3 = Color3.fromRGB(60, 50, 90)
	bar.Parent = rebirthPanel
	rebirthBarFill = Instance.new("Frame")
	rebirthBarFill.Size = UDim2.fromScale(0, 1)
	rebirthBarFill.BackgroundColor3 = Color3.fromRGB(150, 110, 230)
	rebirthBarFill.BorderSizePixel = 0
	rebirthBarFill.Parent = bar
	rebirthBarLabel = makeLabel(bar, "", UDim2.fromScale(1, 1), UDim2.fromOffset(0, 0))
	rebirthBarLabel.TextXAlignment = Enum.TextXAlignment.Center

	rebirthButton = Instance.new("TextButton")
	rebirthButton.Size = UDim2.new(1, -16, 0, 36)
	rebirthButton.Position = UDim2.fromOffset(8, 90)
	rebirthButton.TextColor3 = Color3.new(1, 1, 1)
	rebirthButton.TextScaled = true
	rebirthButton.Parent = rebirthPanel
	rebirthButton.Activated:Connect(onRebirthClicked)

	rebirthResultLabel = makeLabel(rebirthPanel, "", UDim2.new(1, -16, 0, 22), UDim2.fromOffset(8, 130))
	rebirthResultLabel.TextXAlignment = Enum.TextXAlignment.Center

	return gui
end

-- Последний валидный снимок сервера или nil, пока он не пришёл.
function HUD.GetSnapshot(): EconomySnapshot?
	return snapshot
end

-- Последний валидный снимок Хаоса или nil, пока он не пришёл.
function HUD.GetChaosSnapshot(): ChaosSnapshot?
	return chaosSnapshot
end

-- Добавляет кнопку в меню HUD (вызывать после Init). onClick — только открытие/закрытие
-- интерфейса, игровых действий по клику нет.
function HUD.AddMenuButton(text: string, onClick: () -> ()): TextButton
	assert(menuFrame, "HUD.AddMenuButton вызван до HUD.Init")
	local button = Instance.new("TextButton")
	button.Size = UDim2.fromOffset(160, 36)
	button.Position = UDim2.fromOffset(0, menuButtonCount * 44)
	button.BackgroundColor3 = Color3.fromRGB(60, 50, 110)
	button.TextColor3 = Color3.new(1, 1, 1)
	button.TextScaled = true
	button.Text = text
	button.Parent = menuFrame
	menuButtonCount += 1
	menuFrame.Size = UDim2.fromOffset(160, menuButtonCount * 44)
	button.Activated:Connect(onClick)
	return button
end

function HUD.Init()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local gui = build()
	refreshAll()
	refreshChaos()
	gui.Parent = playerGui

	-- Сервер шлёт первый снимок сразу после загрузки профиля; события, пришедшие
	-- до подключения обработчика, Roblox держит в очереди и доставит сюда.
	Remotes.EconomySnapshot.OnClientEvent:Connect(onSnapshot)
	Remotes.ChaosSnapshot.OnClientEvent:Connect(onChaosSnapshot)
end

return HUD
