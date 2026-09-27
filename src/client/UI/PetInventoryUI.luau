--!strict

--[[
	PetInventoryUI (раздел 5.3/5.8 ТЗ): список петов, вылупление коконов, надеть/снять.

	- Единственное место на клиенте, подписанное на Remotes.PetSnapshot. Список петов и лимит
	  слотов — только из последнего снимка сервера; при отказе (Pets = nil) остаётся прежний список.
	- Essence для кнопок Hatch — из снимка экономики, который отдаёт HUD (GetSnapshot/SnapshotChanged).
	  Цена — из CocoonConfig. Серая кнопка — только UX-подсказка: сервер перепроверяет цену,
	  слоты, лимит инвентаря и владение петом сам.
	- Клики шлют только intent (id кокона / id пета). Пока запрос в полёте (нет ответа со
	  снимком-Ack), все кнопки неактивны — иначе нетерпеливый игрок упирается в rate limit сервера.
	  Ответ приходит всегда, кроме отброшенного rate limit'ом запроса — тогда кнопки
	  разблокирует таймаут.
	- Кнопка меню приходит от HUD (AddMenuButton), как у ShopUI.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.shared.Types)
local Remotes = require(ReplicatedStorage.shared.Remotes)
local CocoonConfig = require(ReplicatedStorage.shared.Config.CocoonConfig)
local PetConfig = require(ReplicatedStorage.shared.Config.PetConfig)
local PetSpeciesConfig = require(ReplicatedStorage.shared.Config.PetSpeciesConfig)
local ShopUI = require(script.Parent.ShopUI)

type PetRecord = Types.PetRecord
type CocoonDefinition = CocoonConfig.CocoonDefinition

export type SnapshotSource = ShopUI.SnapshotSource

-- Строки UI пока здесь; в таблицу локализации (раздел 10 ТЗ) переедут вместе с остальным UI.
local TEXT = {
	Title = "Питомцы",
	Close = "X",
	Menu = "Питомцы",
	Slots = "Слоты: %d / %d · Петов: %d",
	Hatch = "%s — %.0f",
	InventoryFull = "Инвентарь полон",
	Empty = "Петов пока нет — вылупите кокон",
	Equip = "Надеть",
	Unequip = "Снять",
	NoSlots = "Нет слотов",
	Waiting = "...",
	Mutation = "мутация: %s",
	Hatched = "Вылупился: %s (%s)",
	Denied = "Запрос отклонён сервером",
	Pet = "%s · %s · %s",
}

-- Сколько ждать ответа сервера, прежде чем разблокировать кнопки (запрос мог быть отброшен
-- rate limit'ом без ответа).
local PENDING_TIMEOUT = 3
local STATUS_SECONDS = 4

local ROW_HEIGHT = 44
local COLOR_PANEL = Color3.fromRGB(30, 25, 50)
local COLOR_ROW = Color3.fromRGB(45, 38, 78)
local COLOR_BUY = Color3.fromRGB(80, 170, 90)
local COLOR_UNEQUIP = Color3.fromRGB(150, 100, 60)
local COLOR_DISABLED = Color3.fromRGB(90, 90, 90)

type Row = {
	Pet: PetRecord,
	Button: TextButton,
}

local PetInventoryUI = {}

local source: SnapshotSource
local gui: ScreenGui
local slotsLabel: TextLabel
local statusLabel: TextLabel
local listFrame: ScrollingFrame
local emptyLabel: TextLabel
local hatchButtons: { { Cocoon: CocoonDefinition, Button: TextButton } } = {}
local rows: { Row } = {}

-- Последний полученный список петов и лимит слотов (только из снимков сервера).
local pets: { PetRecord } = {}
local equipSlots = PetConfig.BaseEquipSlots
local pendingSince: number? = nil
local statusToken = 0

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

local function setButton(button: TextButton, text: string, enabled: boolean, color: Color3?)
	button.Text = text
	button.Active = enabled
	button.AutoButtonColor = enabled
	button.BackgroundColor3 = if enabled then (color or COLOR_BUY) else COLOR_DISABLED
end

local function countEquipped(): number
	local count = 0
	for _, pet in pets do
		if pet.Equipped then
			count += 1
		end
	end
	return count
end

local function speciesInfo(pet: PetRecord): (string, string)
	local species = PetSpeciesConfig.Species[pet.SpeciesId]
	if species then
		return species.DisplayName, species.EmotionType
	end
	return pet.SpeciesId, "?"
end

local function showStatus(text: string)
	statusToken += 1
	local token = statusToken
	statusLabel.Text = text
	task.delay(STATUS_SECONDS, function()
		if statusToken == token then
			statusLabel.Text = ""
		end
	end)
end

-- Состояние кнопок: не зависит от пересборки списка, вызывается и по снимку экономики (Essence).
local function refreshButtons()
	local busy = pendingSince ~= nil
	local snapshot = source.GetSnapshot()
	local essence = if snapshot then snapshot.Essence else 0
	local full = #pets >= PetConfig.MaxInventory

	for _, entry in hatchButtons do
		local text = string.format(TEXT.Hatch, entry.Cocoon.DisplayName, entry.Cocoon.Price)
		if busy then
			setButton(entry.Button, TEXT.Waiting, false)
		elseif full then
			setButton(entry.Button, TEXT.InventoryFull, false)
		else
			setButton(entry.Button, text, snapshot ~= nil and essence >= entry.Cocoon.Price)
		end
	end

	local equipped = countEquipped()
	slotsLabel.Text = string.format(TEXT.Slots, equipped, equipSlots, #pets)

	for _, row in rows do
		if busy then
			setButton(row.Button, TEXT.Waiting, false)
		elseif row.Pet.Equipped then
			setButton(row.Button, TEXT.Unequip, true, COLOR_UNEQUIP)
		elseif equipped >= equipSlots then
			setButton(row.Button, TEXT.NoSlots, false)
		else
			setButton(row.Button, TEXT.Equip, true)
		end
	end
end

-- Отправка intent'а: только при свободном канале; кнопки блокируются до ответа или таймаута.
local function send(remote: RemoteEvent, argument: string?)
	if pendingSince then
		return
	end
	pendingSince = os.clock()
	refreshButtons()
	if argument then
		remote:FireServer(argument)
	else
		remote:FireServer()
	end

	local sentAt = pendingSince
	task.delay(PENDING_TIMEOUT, function()
		if pendingSince == sentAt then
			pendingSince = nil
			refreshButtons()
		end
	end)
end

local function clearRows()
	for _, child in listFrame:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	table.clear(rows)
end

-- Пересборка списка: надетые сверху, дальше порядок сервера (от него зависит, кому достанется слот).
local function rebuildList()
	clearRows()
	emptyLabel.Visible = #pets == 0

	local ordered: { PetRecord } = {}
	for _, pet in pets do
		if pet.Equipped then
			table.insert(ordered, pet)
		end
	end
	for _, pet in pets do
		if not pet.Equipped then
			table.insert(ordered, pet)
		end
	end

	for index, pet in ordered do
		local row = Instance.new("Frame")
		row.LayoutOrder = index
		row.Size = UDim2.new(1, -8, 0, ROW_HEIGHT - 4)
		row.BackgroundColor3 = COLOR_ROW
		row.Parent = listFrame

		local name, emotion = speciesInfo(pet)
		makeLabel(row, string.format(TEXT.Pet, name, pet.Rarity, emotion), UDim2.fromOffset(300, 20), UDim2.fromOffset(6, 2))
		local detail = if type(pet.Mutation) == "string" then string.format(TEXT.Mutation, pet.Mutation) else ""
		local detailLabel = makeLabel(row, detail, UDim2.fromOffset(300, 14), UDim2.fromOffset(6, 23))
		detailLabel.TextColor3 = Color3.fromRGB(255, 220, 130)

		local button = makeButton(row, UDim2.fromOffset(96, 32), UDim2.new(1, -102, 0, 4))
		local petId = pet.Id
		button.Activated:Connect(function()
			-- Состояние берём из актуального списка, а не из замыкания устаревшей строки.
			for _, current in pets do
				if current.Id == petId then
					send(if current.Equipped then Remotes.UnequipPet else Remotes.EquipPet, petId)
					return
				end
			end
		end)
		table.insert(rows, { Pet = pet, Button = button })
	end

	listFrame.CanvasSize = UDim2.fromOffset(0, #ordered * ROW_HEIGHT)
	refreshButtons()
end

local function findPet(petId: string): PetRecord?
	for _, pet in pets do
		if pet.Id == petId then
			return pet
		end
	end
	return nil
end

-- Снимок приходит от сервера, но форму проверяем: битый снимок не должен ронять UI.
local function isValidSnapshot(value: unknown): boolean
	if type(value) ~= "table" then
		return false
	end
	local candidate = value :: any
	if type(candidate.EquipSlots) ~= "number" then
		return false
	end
	if candidate.Pets ~= nil then
		if type(candidate.Pets) ~= "table" then
			return false
		end
		for _, pet in candidate.Pets do
			if type(pet) ~= "table" or type(pet.Id) ~= "string" or type(pet.SpeciesId) ~= "string" then
				return false
			end
		end
	end
	return true
end

local function onPetSnapshot(value: unknown)
	if not isValidSnapshot(value) then
		return
	end
	local snapshot = value :: Types.PetSnapshot

	equipSlots = snapshot.EquipSlots
	if snapshot.Pets then
		pets = snapshot.Pets
	end

	if snapshot.Ack ~= nil then
		pendingSince = nil
		if snapshot.Pets == nil then
			showStatus(TEXT.Denied)
		elseif snapshot.HatchedPetId then
			local hatched = findPet(snapshot.HatchedPetId)
			if hatched then
				local name = speciesInfo(hatched)
				showStatus(string.format(TEXT.Hatched, name, hatched.Rarity))
			end
		end
	end

	if snapshot.Pets or snapshot.Ack == nil then
		rebuildList()
	else
		refreshButtons()
	end
end

local function build(): ScreenGui
	local screen = Instance.new("ScreenGui")
	screen.Name = "Pets"
	screen.ResetOnSpawn = false
	screen.Enabled = false

	local panel = Instance.new("Frame")
	panel.Size = UDim2.fromOffset(460, 400)
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.BackgroundColor3 = COLOR_PANEL
	panel.BackgroundTransparency = 0.1
	panel.Parent = screen

	makeLabel(panel, TEXT.Title, UDim2.fromOffset(300, 32), UDim2.fromOffset(8, 6))
	local close = makeButton(panel, UDim2.fromOffset(36, 32), UDim2.fromOffset(416, 6))
	close.Text = TEXT.Close
	close.BackgroundColor3 = COLOR_DISABLED
	close.Activated:Connect(function()
		screen.Enabled = false
	end)

	slotsLabel = makeLabel(panel, "", UDim2.fromOffset(440, 22), UDim2.fromOffset(8, 42))

	-- По кнопке на кокон из CocoonConfig, в порядке SortOrder, поровну по ширине.
	local cocoons: { CocoonDefinition } = {}
	for _, cocoon in CocoonConfig do
		table.insert(cocoons, cocoon)
	end
	table.sort(cocoons, function(a, b)
		return a.SortOrder < b.SortOrder
	end)
	local gap = 8
	local buttonWidth = (444 - gap * (#cocoons - 1)) / math.max(#cocoons, 1)
	for index, cocoon in cocoons do
		local button = makeButton(
			panel,
			UDim2.fromOffset(buttonWidth, 40),
			UDim2.fromOffset(8 + (index - 1) * (buttonWidth + gap), 68)
		)
		local cocoonId = cocoon.Id
		button.Activated:Connect(function()
			send(Remotes.HatchCocoon, cocoonId)
		end)
		table.insert(hatchButtons, { Cocoon = cocoon, Button = button })
	end

	listFrame = Instance.new("ScrollingFrame")
	listFrame.Size = UDim2.fromOffset(444, 240)
	listFrame.Position = UDim2.fromOffset(8, 116)
	listFrame.BackgroundTransparency = 1
	listFrame.BorderSizePixel = 0
	listFrame.ScrollBarThickness = 6
	listFrame.CanvasSize = UDim2.fromOffset(0, 0)
	listFrame.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 4)
	layout.Parent = listFrame

	emptyLabel = makeLabel(panel, TEXT.Empty, UDim2.fromOffset(440, 28), UDim2.fromOffset(8, 130))
	emptyLabel.TextXAlignment = Enum.TextXAlignment.Center

	statusLabel = makeLabel(panel, "", UDim2.fromOffset(440, 24), UDim2.fromOffset(8, 366))
	statusLabel.TextXAlignment = Enum.TextXAlignment.Center

	return screen
end

function PetInventoryUI.Toggle()
	gui.Enabled = not gui.Enabled
	if gui.Enabled then
		refreshButtons()
	end
end

-- snapshotSource — HUD (снимок экономики для цен и кнопка меню).
function PetInventoryUI.Init(snapshotSource: SnapshotSource)
	source = snapshotSource
	gui = build()
	rebuildList()
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	-- Единственная подписка клиента на PetSnapshot; события, пришедшие до неё, Roblox держит в очереди.
	Remotes.PetSnapshot.OnClientEvent:Connect(onPetSnapshot)
	source.SnapshotChanged:Connect(refreshButtons)
	source.AddMenuButton(TEXT.Menu, PetInventoryUI.Toggle)
end

return PetInventoryUI
