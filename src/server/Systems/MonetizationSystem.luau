--!strict

--[[
	MonetizationSystem — владение геймпассами (раздел 5.7 ТЗ; S10). Только геймпассы: платёж
	проводит сам Roblox (PromptGamePassPurchase с клиента), у сервера нет ProcessReceipt и
	идемпотентности — он лишь перечитывает владение. Дев-продукты и сезонный пропуск — S12.

	Roblox — внешний источник данных, ему доверяем ровно в пределах этой роли:
	- каждый вызов UserOwnsGamePassAsync — в pcall, результат обязан быть boolean; ошибка или
	  мусор = «неизвестно»: закэшированное в профиле значение НЕ трогаем, пишем в лог один
	  раз за сессию игрока;
	- вызов сетевой и может висеть: на каждый геймпасс свой поток (task.spawn), сервер и
	  остальные игроки не ждут;
	- результат применяется только если игрок ещё на сервере, профиль жив и запрос не
	  устарел: у каждой проверки «талон» (Tickets), пишет только последняя запущенная —
	  медленный ответ, отправленный ДО покупки, не затрёт свежее «куплено»;
	- аргументы PromptGamePassPurchaseFinished не принимаются на веру: wasPurchased только
	  запускает перепроверку через Roblox, владение пишется по её результату.

	Изменение владения → PetSystem.RefreshBonuses (число слотов меняет, какие петы дают
	бонус) и FactorySystem.PushSnapshot (магазин видит GamePassesOwned). Новых ремоут нет.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MonetizationConfig = require(ReplicatedStorage.shared.Config.MonetizationConfig)
local PetConfig = require(ReplicatedStorage.shared.Config.PetConfig)
local DataSystem = require(script.Parent.DataSystem)
local FactorySystem = require(script.Parent.FactorySystem)
local PetSystem = require(script.Parent.PetSystem)

type GamePassDefinition = MonetizationConfig.GamePassDefinition

type PlayerState = {
	Tickets: { [string]: number }, -- Id геймпасса -> номер последней запущенной проверки
	FailureReported: boolean, -- сбой Roblox API уже записан в лог
	CorruptionReported: boolean, -- битый раздел Monetization уже записан в лог
}

local passesById: { [string]: GamePassDefinition } = {}
local passesByGamePassId: { [number]: GamePassDefinition } = {}
for _, pass in MonetizationConfig.GamePasses do
	passesById[pass.Id] = pass
	if pass.GamePassId ~= 0 then
		passesByGamePassId[pass.GamePassId] = pass
	end
end
assert(
	passesById[PetConfig.ExtraSlotsGamePassId],
	`MonetizationSystem: геймпасс {PetConfig.ExtraSlotsGamePassId} из PetConfig отсутствует в MonetizationConfig`
)

local MonetizationSystem = {}

local playerStates: { [Player]: PlayerState } = {}

local function getPlayerState(player: Player): PlayerState
	local state = playerStates[player]
	if not state then
		state = { Tickets = {}, FailureReported = false, CorruptionReported = false }
		playerStates[player] = state
	end
	return state
end

local function reportFailure(player: Player, state: PlayerState, pass: GamePassDefinition, err: unknown)
	if state.FailureReported then
		return
	end
	state.FailureReported = true
	warn(
		`[MonetizationSystem] Не удалось проверить геймпасс {pass.Id} у {player.Name} ({player.UserId}), `
			.. `оставляем закэшированное владение: {err}`
	)
end

-- Запрос владения у Roblox. true/false — ответ; nil — «неизвестно» (сбой или мусор).
-- Yield'ит: вызывать только из отдельного потока.
local function fetchOwnership(player: Player, state: PlayerState, pass: GamePassDefinition): boolean?
	local ok, result = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, pass.GamePassId)
	end)
	if not ok then
		reportFailure(player, state, pass, result)
		return nil
	end
	if type(result) ~= "boolean" then
		reportFailure(player, state, pass, `неожиданный ответ {typeof(result)}`)
		return nil
	end
	return result
end

-- Записывает владение в профиль. true — список изменился. Чужие Id в списке не трогаем.
local function applyOwnership(player: Player, state: PlayerState, pass: GamePassDefinition, owns: boolean): boolean
	local data = DataSystem.GetData(player)
	if not data then
		return false -- профиль освобождён (игрок вышел) — писать некуда
	end

	local monetization = data.Monetization
	if type(monetization) ~= "table" then
		if not state.CorruptionReported then
			state.CorruptionReported = true
			warn(`[MonetizationSystem] Раздел Monetization повреждён: {player.Name} ({player.UserId})`)
		end
		return false
	end
	-- Список — производное от Roblox значение, его можно восстановить перечитыванием.
	if type(monetization.GamePassesOwned) ~= "table" then
		monetization.GamePassesOwned = {}
	end

	local owned = monetization.GamePassesOwned
	local changed = false
	local index = table.find(owned, pass.Id)
	if owns and not index then
		table.insert(owned, pass.Id)
		changed = true
	elseif not owns then
		while index do
			table.remove(owned, index)
			changed = true
			index = table.find(owned, pass.Id)
		end
	end
	return changed
end

-- Перечитывает владение одним геймпассом и применяет результат. Возвращает ответ Roblox
-- (nil — сбой). Yield'ит.
local function refreshPass(player: Player, pass: GamePassDefinition): boolean?
	if player.Parent == nil then
		return nil
	end
	local state = getPlayerState(player)
	local ticket = (state.Tickets[pass.Id] or 0) + 1
	state.Tickets[pass.Id] = ticket

	local owns = fetchOwnership(player, state, pass)

	-- После yield: игрок мог выйти, а после него — запуститься более свежая проверка.
	if owns == nil or playerStates[player] ~= state or player.Parent == nil then
		return owns
	end
	if state.Tickets[pass.Id] ~= ticket then
		return owns
	end

	if applyOwnership(player, state, pass, owns) then
		PetSystem.RefreshBonuses(player)
		FactorySystem.PushSnapshot(player)
	end
	return owns
end

local function checkAllPasses(player: Player)
	task.spawn(function()
		local data = DataSystem.WaitForData(player)
		if not data or player.Parent == nil then
			return
		end
		for _, pass in MonetizationConfig.GamePasses do
			if pass.GamePassId ~= 0 then
				task.spawn(refreshPass, player, pass)
			end
		end
	end)
end

local function onPurchaseFinished(player: Player, gamePassId: unknown, wasPurchased: unknown)
	if wasPurchased ~= true or type(gamePassId) ~= "number" or player.Parent == nil then
		return
	end
	local pass = passesByGamePassId[gamePassId]
	if not pass then
		return
	end

	task.spawn(function()
		for attempt = 1, MonetizationConfig.PurchaseRecheckAttempts do
			if player.Parent == nil then
				return
			end
			if refreshPass(player, pass) == true then
				return
			end
			if attempt < MonetizationConfig.PurchaseRecheckAttempts then
				task.wait(MonetizationConfig.PurchaseRecheckDelay)
			end
		end
		warn(
			`[MonetizationSystem] Покупка {pass.Id} у {player.Name} ({player.UserId}) завершена, но Roblox `
				.. `не подтвердил владение за {MonetizationConfig.PurchaseRecheckAttempts} проверок; `
				.. "владение обновится при следующем входе"
		)
	end)
end

function MonetizationSystem.Init()
	for _, pass in MonetizationConfig.GamePasses do
		if pass.GamePassId == 0 then
			warn(`[MonetizationSystem] У геймпасса {pass.Id} GamePassId = 0 (заглушка): проверка владения пропущена`)
		end
	end

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(onPurchaseFinished)

	Players.PlayerAdded:Connect(checkAllPasses)
	for _, player in Players:GetPlayers() do
		checkAllPasses(player)
	end

	Players.PlayerRemoving:Connect(function(player)
		playerStates[player] = nil
	end)
end

return MonetizationSystem
