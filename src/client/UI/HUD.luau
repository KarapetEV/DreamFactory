--!strict

--[[
	HUD (MVP, раздел 5.8 ТЗ): счётчик Essence и кнопки апгрейда для всех треков UpgradeConfig.

	- Всё, что показывается про игрока (Essence, сырые фрагменты, уровни), — из последнего
	  снимка сервера (Remotes.EconomySnapshot); ёмкость склада — из уровня через UpgradeEffects.
	  Цену и значение эффекта следующего уровня HUD берёт сам из UpgradeConfig/UpgradeEffects.
	- Клик шлёт intent PurchaseUpgrade(id, targetLevel), где targetLevel = подтверждённый
	  сервером уровень + 1. Локально уровень не поднимается: новое значение придёт снимком.
	- Кнопка блокируется до ответа сервера (снимок с PurchaseAck = id) или до таймаута —
	  это только против визуального рассинхрона. Неактивность на MaxLevel и при нехватке
	  Essence — тоже только UX: сервер перепроверяет всё сам.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.shared.Types)
local Remotes = require(ReplicatedStorage.shared.Remotes)
local UpgradeConfig = require(ReplicatedStorage.shared.Config.UpgradeConfig)
local UpgradeEffects = require(ReplicatedStorage.shared.UpgradeEffects)

type EconomySnapshot = Types.EconomySnapshot

-- Сколько ждать ответа на покупку, прежде чем разблокировать кнопку (ответ мог не прийти,
-- например запрос отброшен rate limit'ом сервера).
local PENDING_TIMEOUT = 3

-- Порядок строк и подписи значений эффектов. Строки UI пока здесь; в таблицу локализации
-- (раздел 10 ТЗ) переедут вместе с остальным UI.
local TRACK_ORDER = { "ConveyorSpeed", "StorageCapacity", "CollectionRadius", "CollectionSpeed" }
local VALUE_FORMATS: { [string]: string } = {
	ConveyorSpeed = "%.2f с/цикл",
	StorageCapacity = "%.0f фрагм.",
	CollectionRadius = "%.0f studs",
	CollectionSpeed = "%.2f с",
}
local TEXT = {
	EssenceLabel = "Essence: %s",
	FragmentsLabel = "Фрагменты: %s / %s",
	Waiting = "Загрузка...",
	Buy = "Купить: %.0f",
	Max = "МАКС",
	Pending = "...",
}

local BUTTON_ENABLED = Color3.fromRGB(80, 170, 90)
local BUTTON_DISABLED = Color3.fromRGB(90, 90, 90)

for _, id in TRACK_ORDER do
	assert(UpgradeConfig[id], `HUD: трек {id} отсутствует в UpgradeConfig`)
end

type Row = {
	Id: string,
	Info: TextLabel,
	Button: TextButton,
	PendingSince: number?, -- os.clock() отправки PurchaseUpgrade, пока ждём ответа
}

local HUD = {}

local snapshot: EconomySnapshot? = nil
local essenceLabel: TextLabel
local fragmentsLabel: TextLabel
local rows: { [string]: Row } = {}

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
end

local function onPurchaseClicked(row: Row)
	if row.PendingSince then
		return
	end
	local level = getConfirmedLevel(row.Id)
	local track = UpgradeConfig[row.Id]
	if level == nil or level >= track.MaxLevel or not snapshot or snapshot.Essence < track.Levels[level + 1].Price then
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

local function onSnapshot(value: unknown)
	if not isValidSnapshot(value) then
		return
	end
	local newSnapshot = value :: EconomySnapshot
	snapshot = newSnapshot

	local ack = newSnapshot.PurchaseAck
	if ack and rows[ack] then
		rows[ack].PendingSince = nil
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

	local panel = Instance.new("Frame")
	panel.Size = UDim2.fromOffset(460, 8 + #TRACK_ORDER * 48)
	panel.AnchorPoint = Vector2.new(1, 0)
	panel.Position = UDim2.new(1, -12, 0, 12)
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

	return gui
end

function HUD.Init()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local gui = build()
	refreshAll()
	gui.Parent = playerGui

	-- Сервер шлёт первый снимок сразу после загрузки профиля; события, пришедшие
	-- до подключения обработчика, Roblox держит в очереди и доставит сюда.
	Remotes.EconomySnapshot.OnClientEvent:Connect(onSnapshot)
end

return HUD
