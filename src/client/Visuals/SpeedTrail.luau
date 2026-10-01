--!strict

--[[
	SpeedTrail — светящийся шлейф за персонажем под баффом Speed Boost. Без новых ремоут: по
	атрибуту игрока Attributes.SpeedBoostExpiresAt (os.time() конца баффа, пишет BuffSystem;
	реплицируется всем клиентам), сравнение — с серверным временем (Workspace:GetServerTimeNow),
	как у ауры PvP-щита. Видно у всех игроков, не только у своего.

	- Trail между двумя Attachment на HumanoidRootPart (вертикальная лента ±HalfHeight): сам
	  Trail рисует только при движении, стоящий игрок шлейфа не оставляет.
	- Бафф истёк — Trail выключается (хвост догорает сам), при респавне шлейф пересоздаётся на
	  новом корне. Выход игрока — всё удаляется.
	- Только отображение: атрибут скорость не даёт — WalkSpeed ставит сервер.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.shared.Attributes)
local VisualConfig = require(ReplicatedStorage.shared.Config.VisualConfig)

type TrailRig = {
	Root: BasePart,
	Trail: Trail,
	Attachments: { Attachment },
}

local SpeedTrail = {}

local rigs: { [Player]: TrailRig } = {}

-- Бафф действует в момент serverNow. Мусор/NaN/inf в атрибуте — нет шлейфа.
function SpeedTrail.IsActive(expiresAt: unknown, serverNow: number): boolean
	return type(expiresAt) == "number" and expiresAt == expiresAt and expiresAt < math.huge and expiresAt > serverNow
end

local function destroyRig(player: Player)
	local rig = rigs[player]
	if not rig then
		return
	end
	rigs[player] = nil
	rig.Trail:Destroy()
	for _, attachment in rig.Attachments do
		attachment:Destroy()
	end
end

local function createRig(root: BasePart): TrailRig
	local cfg = VisualConfig.SpeedTrail
	local top = Instance.new("Attachment")
	top.Name = "SpeedTrailTop"
	top.Position = Vector3.new(0, cfg.HalfHeight, 0)
	top.Parent = root
	local bottom = Instance.new("Attachment")
	bottom.Name = "SpeedTrailBottom"
	bottom.Position = Vector3.new(0, -cfg.HalfHeight, 0)
	bottom.Parent = root

	local trail = Instance.new("Trail")
	trail.Name = "SpeedTrail"
	trail.Attachment0 = top
	trail.Attachment1 = bottom
	trail.Lifetime = cfg.Lifetime
	trail.Color = ColorSequence.new(cfg.Color)
	trail.Transparency = NumberSequence.new(cfg.StartTransparency, 1)
	trail.WidthScale = NumberSequence.new(1, cfg.EndWidthScale)
	trail.LightEmission = cfg.LightEmission
	trail.FaceCamera = true
	trail.Enabled = false
	trail.Parent = root

	return { Root = root, Trail = trail, Attachments = { top, bottom } }
end

local function update()
	local now = Workspace:GetServerTimeNow()
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
		local active = SpeedTrail.IsActive(player:GetAttribute(Attributes.SpeedBoostExpiresAt), now)
		local rig = rigs[player]
		if active and root and root:IsA("BasePart") then
			if rig == nil or rig.Root ~= root or rig.Trail.Parent == nil then
				destroyRig(player) -- респавн: старый корень ушёл вместе с персонажем
				rig = createRig(root)
				rigs[player] = rig
			end
			;(rig :: TrailRig).Trail.Enabled = true
		elseif rig then
			rig.Trail.Enabled = false
		end
	end
end

function SpeedTrail.Init()
	Players.PlayerRemoving:Connect(destroyRig)
	task.spawn(function()
		local reported = false
		while true do
			local ok, err = pcall(update)
			if not ok and not reported then
				reported = true -- цикл частый: в лог — один раз
				warn(`[SpeedTrail] Ошибка обновления шлейфа: {err}`)
			end
			task.wait(VisualConfig.SpeedTrail.CheckInterval)
		end
	end)
end

return SpeedTrail
