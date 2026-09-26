--!strict

--[[
	ShopUI (раздел 5.8 ТЗ, S10): магазин с тремя вкладками.

	- «Геймпассы»: список из MonetizationConfig. Цена в Robux — живая, MarketplaceService:GetProductInfo
	  (в pcall; в конфиге и в коде цены нет). Кнопка «Купить» доступна только когда цена известна
	  и владение подтверждено снимком сервера — предлагать покупку без явной цены или уже
	  купленного нельзя. Покупка — прямой MarketplaceService:PromptGamePassPurchase, без
	  RemoteEvent: платёж проводит Roblox, владение потом перечитывает сервер и присылает
	  в EconomySnapshot.GamePassesOwned (по нему кнопка становится «Куплено»).
	- «Разовые покупки» и «Сезонный пропуск»: статичные позиции-заглушки с неактивными
	  кнопками «Скоро» (реальные покупки — S12).

	Клиент ничего не решает о владении: «Куплено» = Id есть в последнем снимке сервера.
	Снимок и кнопка меню приходят от HUD (см. SnapshotSource) — ShopUI не подписывается
	на ремоут сам.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.shared.Types)
local Signal = require(ReplicatedStorage.shared.Signal)
local MonetizationConfig = require(ReplicatedStorage.shared.Config.MonetizationConfig)

type EconomySnapshot = Types.EconomySnapshot
type GamePassDefinition = MonetizationConfig.GamePassDefinition

export type SnapshotSource = {
	GetSnapshot: () -> EconomySnapshot?,
	SnapshotChanged: Signal.Signal,
	AddMenuButton: (text: string, onClick: () -> ()) -> TextButton,
}

-- Строки UI пока здесь; в таблицу локализации (раздел 10 ТЗ) переедут вместе с остальным UI.
local TEXT = {
	Title = "Магазин",
	Close = "X",
	Menu = "Магазин",
	TabGamePasses = "Геймпассы",
	TabOneTime = "Разовые покупки",
	TabSeason = "Сезонный пропуск",
	PriceLoading = "Цена: загрузка...",
	Price = "%d R$",
	PriceFailed = "Цена недоступна",
	NotForSale = "Не продаётся",
	NotConfigured = "Геймпасс не настроен",
	Buy = "Купить",
	Owned = "Куплено",
	Waiting = "...",
	Unavailable = "Недоступно",
	SoonButton = "Скоро",
	SoonPrice = "Цена появится позже",
}

-- Позиции-заглушки вкладок, которые появятся в S12. Реальных Id/цен нет намеренно.
local PLACEHOLDERS: { [string]: { string } } = {
	OneTime = { "Пачка Essence", "Ускоритель на 15 минут", "Набор декора фабрики" },
	Season = { "Сезонный пропуск: бесплатная ветка", "Сезонный пропуск: платная ветка" },
}

-- После клика «Купить» кнопка заблокирована на это время (окно покупки открывает Roblox).
local PROMPT_DEBOUNCE = 2

local ROW_HEIGHT = 56
local COLOR_PANEL = Color3.fromRGB(30, 25, 50)
local COLOR_TAB = Color3.fromRGB(60, 50, 110)
local COLOR_TAB_ACTIVE = Color3.fromRGB(110, 90, 200)
local COLOR_BUY = Color3.fromRGB(80, 170, 90)
local COLOR_DISABLED = Color3.fromRGB(90, 90, 90)

type PriceState = {
	Status: "Idle" | "Loading" | "Ready" | "NotForSale" | "Failed",
	Robux: number?,
}

type PassRow = {
	Pass: GamePassDefinition,
	Price: PriceState,
	PromptLockedUntil: number,
	Name: TextLabel,
	PriceLabel: TextLabel,
	Button: TextButton,
}

local ShopUI = {}

local source: SnapshotSource
local gui: ScreenGui
local tabFrames: { [string]: Frame } = {}
local tabButtons: { [string]: TextButton } = {}
local passRows: { PassRow } = {}
local currentTab = "GamePasses"

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

local function makeButton(parent: Instance, size: UDim2, position: UDim2): TextButton
	local button = Instance.new("TextButton")
	button.Size = size
	button.Position = position
	button.TextColor3 = Color3.new(1, 1, 1)
	button.TextScaled = true
	button.Parent = parent
	return button
end

local function setButton(button: TextButton, text: string, enabled: boolean)
	button.Text = text
	button.Active = enabled
	button.AutoButtonColor = enabled
	button.BackgroundColor3 = if enabled then COLOR_BUY else COLOR_DISABLED
end

-- Владение — только из подтверждённого снимка сервера. nil — снимка ещё нет.
local function isOwned(passId: string): boolean?
	local snapshot = source.GetSnapshot()
	if not snapshot or type(snapshot.GamePassesOwned) ~= "table" then
		return nil
	end
	return table.find(snapshot.GamePassesOwned, passId) ~= nil
end

local function refreshPassRow(row: PassRow)
	local pass = row.Pass

	if pass.GamePassId == 0 then
		row.PriceLabel.Text = TEXT.NotConfigured
		setButton(row.Button, TEXT.Unavailable, false)
		return
	end

	local price = row.Price
	if price.Status == "Ready" and price.Robux then
		row.PriceLabel.Text = string.format(TEXT.Price, price.Robux)
	elseif price.Status == "NotForSale" then
		row.PriceLabel.Text = TEXT.NotForSale
	elseif price.Status == "Failed" then
		row.PriceLabel.Text = TEXT.PriceFailed
	else
		row.PriceLabel.Text = TEXT.PriceLoading
	end

	local owned = isOwned(pass.Id)
	if owned == true then
		setButton(row.Button, TEXT.Owned, false)
	elseif owned == nil then
		setButton(row.Button, TEXT.Waiting, false)
	elseif price.Status ~= "Ready" then
		setButton(row.Button, TEXT.Unavailable, false) -- без явной цены покупку не предлагаем
	elseif os.clock() < row.PromptLockedUntil then
		setButton(row.Button, TEXT.Waiting, false)
	else
		setButton(row.Button, TEXT.Buy, true)
	end
end

local function refreshAll()
	for _, row in passRows do
		refreshPassRow(row)
	end
end

-- Живая цена геймпасса. Успех/«не продаётся» запоминаем на сессию; сбой — повторим при
-- следующем открытии магазина.
local function fetchPrice(row: PassRow)
	local price = row.Price
	if row.Pass.GamePassId == 0 or price.Status == "Loading" or price.Status == "Ready" or price.Status == "NotForSale" then
		return
	end
	price.Status = "Loading"
	refreshPassRow(row)

	task.spawn(function()
		local ok, info = pcall(function()
			return MarketplaceService:GetProductInfo(row.Pass.GamePassId, Enum.InfoType.GamePass)
		end)
		if not ok or type(info) ~= "table" then
			price.Status = "Failed"
		else
			local robux = (info :: any).PriceInRobux
			if (info :: any).IsForSale == false or type(robux) ~= "number" then
				price.Status = "NotForSale"
			else
				price.Status = "Ready"
				price.Robux = robux
			end
		end
		refreshPassRow(row)
	end)
end

local function onBuyClicked(row: PassRow)
	if row.Pass.GamePassId == 0 or row.Price.Status ~= "Ready" or isOwned(row.Pass.Id) ~= false then
		return
	end
	if os.clock() < row.PromptLockedUntil then
		return
	end

	row.PromptLockedUntil = os.clock() + PROMPT_DEBOUNCE
	refreshPassRow(row)
	task.delay(PROMPT_DEBOUNCE, function()
		refreshPassRow(row)
	end)

	-- Платёж проводит Roblox; результат сервер перечитает сам (PromptGamePassPurchaseFinished).
	pcall(function()
		MarketplaceService:PromptGamePassPurchase(Players.LocalPlayer, row.Pass.GamePassId)
	end)
end

local function setTab(name: string)
	currentTab = name
	for id, frame in tabFrames do
		frame.Visible = id == name
	end
	for id, button in tabButtons do
		button.BackgroundColor3 = if id == name then COLOR_TAB_ACTIVE else COLOR_TAB
	end
end

local function buildPlaceholderTab(parent: Frame, names: { string })
	for index, name in names do
		local y = 8 + (index - 1) * ROW_HEIGHT
		makeLabel(parent, name, UDim2.fromOffset(250, 24), UDim2.fromOffset(8, y))
		makeLabel(parent, TEXT.SoonPrice, UDim2.fromOffset(250, 18), UDim2.fromOffset(8, y + 26))
		local button = makeButton(parent, UDim2.fromOffset(120, 36), UDim2.fromOffset(268, y + 4))
		setButton(button, TEXT.SoonButton, false)
	end
end

local function build(): ScreenGui
	local screen = Instance.new("ScreenGui")
	screen.Name = "Shop"
	screen.ResetOnSpawn = false
	screen.Enabled = false

	local panel = Instance.new("Frame")
	panel.Size = UDim2.fromOffset(410, 320)
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.BackgroundColor3 = COLOR_PANEL
	panel.BackgroundTransparency = 0.1
	panel.Parent = screen

	makeLabel(panel, TEXT.Title, UDim2.fromOffset(300, 32), UDim2.fromOffset(8, 6))
	local close = makeButton(panel, UDim2.fromOffset(36, 32), UDim2.fromOffset(366, 6))
	close.Text = TEXT.Close
	close.BackgroundColor3 = COLOR_DISABLED
	close.Activated:Connect(function()
		screen.Enabled = false
	end)

	local tabs = {
		{ Id = "GamePasses", Text = TEXT.TabGamePasses },
		{ Id = "OneTime", Text = TEXT.TabOneTime },
		{ Id = "Season", Text = TEXT.TabSeason },
	}
	for index, tab in tabs do
		local button = makeButton(panel, UDim2.fromOffset(126, 32), UDim2.fromOffset(8 + (index - 1) * 132, 44))
		button.Text = tab.Text
		button.Activated:Connect(function()
			setTab(tab.Id)
		end)
		tabButtons[tab.Id] = button

		local frame = Instance.new("Frame")
		frame.Size = UDim2.fromOffset(394, 230)
		frame.Position = UDim2.fromOffset(8, 82)
		frame.BackgroundTransparency = 1
		frame.Visible = false
		frame.Parent = panel
		tabFrames[tab.Id] = frame
	end

	-- Вкладка геймпассов: по строке на запись MonetizationConfig.
	local passesFrame = tabFrames.GamePasses
	for index, pass in MonetizationConfig.GamePasses do
		local y = 8 + (index - 1) * ROW_HEIGHT
		local row: PassRow = {
			Pass = pass,
			Price = { Status = "Idle", Robux = nil },
			PromptLockedUntil = 0,
			Name = makeLabel(passesFrame, pass.DisplayName, UDim2.fromOffset(250, 24), UDim2.fromOffset(8, y)),
			PriceLabel = makeLabel(passesFrame, "", UDim2.fromOffset(250, 18), UDim2.fromOffset(8, y + 26)),
			Button = makeButton(passesFrame, UDim2.fromOffset(120, 36), UDim2.fromOffset(268, y + 4)),
		}
		row.Button.Activated:Connect(function()
			onBuyClicked(row)
		end)
		table.insert(passRows, row)
	end

	buildPlaceholderTab(tabFrames.OneTime, PLACEHOLDERS.OneTime)
	buildPlaceholderTab(tabFrames.Season, PLACEHOLDERS.Season)

	setTab(currentTab)
	return screen
end

function ShopUI.Toggle()
	gui.Enabled = not gui.Enabled
	if gui.Enabled then
		for _, row in passRows do
			fetchPrice(row)
		end
		refreshAll()
	end
end

-- snapshotSource — HUD (снимок сервера и кнопка меню).
function ShopUI.Init(snapshotSource: SnapshotSource)
	source = snapshotSource
	gui = build()
	refreshAll()
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	source.SnapshotChanged:Connect(refreshAll)
	source.AddMenuButton(TEXT.Menu, ShopUI.Toggle)
end

return ShopUI
