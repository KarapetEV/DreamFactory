--!strict

--[[
	BuffIcons — колонка иконок действующих временных баффов (Magnet Boost, Speed Boost) у правого
	края экрана, посередине по высоте (правый верх занят списком игроков CoreGui, правый низ —
	панелью апгрейдов; иконки только отображают, кликов нет).

	- Источник — атрибуты своего игрока Attributes.<Id>ExpiresAt (os.time() конца баффа, пишет
	  BuffSystem), «сейчас» — Workspace:GetServerTimeNow(). Модель — чистый BuffTimer.
	- Иконка цветная; по мере истечения серый слой заливает её сверху вниз (доля = прошедшее
	  время / полная шкала). Под иконкой — остаток в секундах. Истёк — иконка скрыта.
	- Символ — картинка VisualConfig.BuffIcons.Icons[id].Image (загружена в Creator Dashboard как
	  Image); не задана или не загрузилась (модерация, сбой) — запасной эмодзи Symbol. Серая часть —
	  серая подложка с тем же символом (картинка — с серым оттенком ImageColor3) под полупрозрачной
	  серой плёнкой: эмодзи цвет не меняет, а оттенок картинки лишь умножает её цвета.
	- Только отображение: баффы выдаёт и проверяет сервер.
]]

local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Loc = require(ReplicatedStorage.shared.Loc)
local Attributes = require(ReplicatedStorage.shared.Attributes)
local BuffConfig = require(ReplicatedStorage.shared.Config.BuffConfig)
local VisualConfig = require(ReplicatedStorage.shared.Config.VisualConfig)
local BuffTimer = require(script.Parent.BuffTimer)

local TEXT = {
	SecondsLeft = Loc.Get("BuffIcons.SecondsLeft"),
}

local LABEL_HEIGHT = 18
local ICON_CORNER = UDim.new(0, 10)
local IMAGE_SCALE = 0.8 -- доля квадрата иконки под картинку
local TINT_COLORED = Color3.new(1, 1, 1)
local TINT_GREY = Color3.fromRGB(170, 170, 175)

type Look = { Color: Color3, Symbol: string, Image: string? }

-- Атрибут игрока со сроком баффа по BuffId.
local ATTRIBUTES: { [string]: string } = {
	MagnetBoost = Attributes.MagnetBoostExpiresAt,
	SpeedBoost = Attributes.SpeedBoostExpiresAt,
}

type Icon = {
	Id: string,
	Attribute: string,
	Duration: number,
	Root: Frame,
	GreyClip: Frame,
	Label: TextLabel,
	Timer: BuffTimer.Timer,
}

local BuffIcons = {}

local icons: { Icon } = {}

local function corner(parent: Instance)
	local c = Instance.new("UICorner")
	c.CornerRadius = ICON_CORNER
	c.Parent = parent
end

local function makeSymbol(parent: Instance, symbol: string, size: number): TextLabel
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromOffset(size, size)
	label.BackgroundTransparency = 1
	label.Text = symbol
	label.TextScaled = true
	label.TextColor3 = Color3.new(1, 1, 1)
	label.Parent = parent
	return label
end

-- Символ иконки: картинка look.Image, при отсутствии или сбое загрузки — эмодзи look.Symbol.
-- tint — оттенок картинки (ImageColor3).
local function makeGlyph(parent: Instance, look: Look, size: number, tint: Color3)
	local symbol = makeSymbol(parent, look.Symbol, size)
	local imageId = look.Image
	if imageId == nil then
		return
	end
	local image = Instance.new("ImageLabel")
	image.AnchorPoint = Vector2.new(0.5, 0.5)
	image.Position = UDim2.fromScale(0.5, 0.5)
	image.Size = UDim2.fromScale(IMAGE_SCALE, IMAGE_SCALE)
	image.BackgroundTransparency = 1
	image.ScaleType = Enum.ScaleType.Fit
	image.Image = imageId
	image.ImageColor3 = tint
	image.Parent = parent
	symbol.Visible = false

	local function fallback()
		image.Visible = false
		symbol.Visible = true
	end
	task.spawn(function()
		local ok = pcall(function()
			ContentProvider:PreloadAsync({ image }, function(_contentId: string, status: Enum.AssetFetchStatus)
				if status ~= Enum.AssetFetchStatus.Success then
					fallback()
				end
			end)
		end)
		if not ok then
			fallback()
		end
	end)
end

-- Квадрат иконки: фон нужного цвета с символом. overlay — полупрозрачная плёнка поверх символа.
local function makeFace(
	parent: Instance,
	color: Color3,
	look: Look,
	size: number,
	tint: Color3,
	overlay: number?
): Frame
	local face = Instance.new("Frame")
	face.Size = UDim2.fromOffset(size, size)
	face.BackgroundColor3 = color
	face.BorderSizePixel = 0
	face.Parent = parent
	corner(face)
	makeGlyph(face, look, size, tint)
	if overlay then
		local film = Instance.new("Frame")
		film.Size = UDim2.fromScale(1, 1)
		film.BackgroundColor3 = color
		film.BackgroundTransparency = overlay
		film.BorderSizePixel = 0
		film.ZIndex = 2
		film.Parent = face
		corner(film)
	end
	return face
end

local function buildIcon(parent: Instance, id: string, order: number): Icon
	local cfg = VisualConfig.BuffIcons
	local look = cfg.Icons[id]
	local size = cfg.IconSize

	local root = Instance.new("Frame")
	root.Name = id
	root.Size = UDim2.fromOffset(size, size + LABEL_HEIGHT)
	root.BackgroundTransparency = 1
	root.LayoutOrder = order
	root.Visible = false
	root.Parent = parent

	local colored = makeFace(root, look.Color, look, size, TINT_COLORED)
	colored.ZIndex = 1
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.new(1, 1, 1)
	stroke.Thickness = 2
	stroke.Transparency = 0.3
	stroke.Parent = colored

	-- Серая часть: полноразмерная серая иконка в клипе, высота клипа растёт сверху вниз.
	local clip = Instance.new("Frame")
	clip.Size = UDim2.fromOffset(size, 0)
	clip.BackgroundTransparency = 1
	clip.ClipsDescendants = true
	clip.ZIndex = 2
	clip.Parent = root
	makeFace(clip, cfg.GreyColor, look, size, TINT_GREY, cfg.GreyOverlayTransparency)

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromOffset(size, LABEL_HEIGHT)
	label.Position = UDim2.fromOffset(0, size)
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.4
	label.TextScaled = true
	label.Parent = root

	return {
		Id = id,
		Attribute = ATTRIBUTES[id],
		Duration = BuffConfig.Buffs[id :: any].Duration,
		Root = root,
		GreyClip = clip,
		Label = label,
		Timer = BuffTimer.new(),
	}
end

local function update()
	local player = Players.LocalPlayer
	local now = Workspace:GetServerTimeNow()
	local size = VisualConfig.BuffIcons.IconSize
	for _, icon in icons do
		local state = BuffTimer.Update(icon.Timer, player:GetAttribute(icon.Attribute), now, icon.Duration)
		icon.Root.Visible = state.Visible
		if state.Visible then
			icon.GreyClip.Size = UDim2.fromOffset(size, math.floor(size * state.Grey + 0.5))
			icon.Label.Text = string.format(TEXT.SecondsLeft, state.SecondsLeft)
		end
	end
end

function BuffIcons.Init()
	local cfg = VisualConfig.BuffIcons
	local gui = Instance.new("ScreenGui")
	gui.Name = "BuffIcons"
	gui.ResetOnSpawn = false

	local column = Instance.new("Frame")
	column.AnchorPoint = Vector2.new(1, 0.5)
	column.Position = UDim2.new(1, -12, 0.5, 0)
	column.Size = UDim2.fromOffset(cfg.IconSize, (cfg.IconSize + LABEL_HEIGHT + cfg.Spacing) * #BuffConfig.BuffIds)
	column.BackgroundTransparency = 1
	column.Parent = gui
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, cfg.Spacing)
	layout.Parent = column

	for index, id in BuffConfig.BuffIds do
		table.insert(icons, buildIcon(column, id, index))
	end

	update()
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	RunService.Heartbeat:Connect(update)
end

return BuffIcons
