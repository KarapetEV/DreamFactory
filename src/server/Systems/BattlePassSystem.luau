--!strict

--[[
	BattlePassSystem — сезонный пропуск (раздел 7.3 GDD). Пороги, XP и награды — BattlePassConfig.

	Прогресс в профиле (Monetization): BattlePassSeasonId, BattlePassTier, BattlePassXP,
	BattlePassPremium. Клиент в нём не участвует: XP начисляется только на серверных событиях,
	новых RemoteEvent нет.

	Ротация сезона — лениво, при первом начислении XP (или покупке премиума): SeasonId профиля
	nil или из BattlePassConfig.PastSeasonIds → Tier = 0, XP = 0, Premium = false, SeasonId =
	текущий. Равные строки — no-op, отдельного маркера нет. Только вперёд: сезон профиля,
	неизвестный конфигу, — более новый (поэтапный деплой, игрок уже был на новом сервере);
	такой прогресс не трогаем — XP не начисляется, премиум-квитанция остаётся NotProcessedYet и
	доставится на сервере новой версии.

	Начисление XP (AddXP) — одна функция без yield: ротация → XP += n → цикл по тирам
	(одно начисление может пройти несколько тиров) → FreeRewards[тир] и, при Premium,
	PremiumRewards[тир] за каждый пройденный тир. На MaxTier XP не копится (0). Все проверки
	(битый профиль, конечность Essence) — до первой записи: либо прогресс и награды целиком,
	либо ничего.

	Источники XP — подписки на сигналы систем (фиксированное число за событие, не за сумму):
	FactorySystem.OnEssenceProduced, RebirthSystem.OnRebirthPerformed, ChaosBossSystem.OnBossHit,
	PvPRaidSystem.OnRaidCompleted (атакующему, если украдено ≥ MinStolenForRaidXP),
	PetSystem.OnPetHatched.

	Премиум-ветка — дев-продукт DevProductConfig "BattlePassPremium". Выдачу проводит
	существующий идемпотентный MonetizationSystem.ProcessReceipt (лог квитанций + маркер в
	профиле); здесь — только сама «награда» (ApplyPremium, без yield): Premium = true в текущем
	сезоне + ретроактивно PremiumRewards тиров 1..BattlePassTier.

	После выдачи Essence — FactorySystem.PushSnapshot (HUD видит новый баланс); после выдачи
	пета — PetSystem.PushSnapshot. Начисление XP без перехода тира снимок не шлёт: данных
	пропуска в EconomySnapshot нет, а источники XP срабатывают каждый цикл конвейера.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.shared.Types)
local UpgradeEffects = require(ReplicatedStorage.shared.UpgradeEffects)
local BattlePassConfig = require(ReplicatedStorage.shared.Config.BattlePassConfig)
local DataSystem = require(script.Parent.DataSystem)
local FactorySystem = require(script.Parent.FactorySystem)
local PetSystem = require(script.Parent.PetSystem)
local AnalyticsSystem = require(script.Parent.AnalyticsSystem)

type PlayerProfile = Types.PlayerProfile

-- Прогресс сезона после (возможной) ротации — ещё не записанный в профиль.
type Progress = {
	Tier: number,
	XP: number,
	Premium: boolean,
}

-- Одна награда тира к выдаче (FreeReward или PremiumReward).
type Reward = {
	Essence: number,
	Decor: string?,
	PetSpeciesId: string?,
}

local isFinite = UpgradeEffects.IsFinite

local pastSeasons: { [string]: true } = {}
for _, seasonId in BattlePassConfig.PastSeasonIds do
	pastSeasons[seasonId] = true
end

local BattlePassSystem = {}

-- Игроки, о битом профиле которых уже написали в лог. Ключи слабые.
local corruptionReported: { [Player]: true } = setmetatable({}, { __mode = "k" }) :: any

local function reportCorruption(player: Player, reason: string)
	if corruptionReported[player] then
		return
	end
	corruptionReported[player] = true
	warn(`[BattlePassSystem] Некорректные данные профиля {player.Name} ({player.UserId}): {reason}`)
end

-- Раздел Monetization и прогресс с учётом ротации сезона. nil — трогать нельзя (профиль
-- повреждён или сезон профиля новее сервера); ничего не записано. Прогресс прошлого сезона
-- не проверяется: его всё равно сбросит ротация.
local function readProgress(player: Player, data: PlayerProfile): (any, Progress?)
	local monetization: any = data.Monetization
	if type(monetization) ~= "table" then
		reportCorruption(player, `Monetization = {monetization}`)
		return nil, nil
	end
	local seasonId = monetization.BattlePassSeasonId
	if seasonId == nil or (type(seasonId) == "string" and pastSeasons[seasonId]) then
		return monetization, { Tier = 0, XP = 0, Premium = false }
	end
	if seasonId ~= BattlePassConfig.SeasonId then
		reportCorruption(
			player,
			`сезон профиля {tostring(seasonId)} неизвестен (сервер: {BattlePassConfig.SeasonId}) — `
				.. "вероятно, более новый; прогресс не трогаем"
		)
		return nil, nil
	end

	local tier, xp, premium = monetization.BattlePassTier, monetization.BattlePassXP, monetization.BattlePassPremium
	if
		not isFinite(tier)
		or tier < 0
		or tier > BattlePassConfig.MaxTier
		or tier % 1 ~= 0
		or not isFinite(xp)
		or xp < 0
		or type(premium) ~= "boolean"
	then
		reportCorruption(
			player,
			`прогресс пропуска Tier = {tostring(tier)}, XP = {tostring(xp)}, Premium = {tostring(premium)}`
		)
		return nil, nil
	end
	return monetization, { Tier = tier, XP = xp, Premium = premium }
end

-- Награды тиров fromTier..toTier в порядке тиров.
local function collectRewards(fromTier: number, toTier: number, free: boolean, premium: boolean): { Reward }
	local rewards: { Reward } = {}
	for tier = fromTier, toTier do
		if free then
			table.insert(rewards, BattlePassConfig.FreeRewards[tier])
		end
		if premium then
			table.insert(rewards, BattlePassConfig.PremiumRewards[tier])
		end
	end
	return rewards
end

--[[
	Выдаёт награды одним блоком. Сначала — все проверки, затем петы (единственный шаг, который
	может не пройти: битый раздел Pets — откат уже выданных в этом вызове петов), затем Essence
	и декор. false — ничего не записано. Второе значение — выдан ли хотя бы один пет.
]]
local function grantRewards(player: Player, data: PlayerProfile, rewards: { Reward }): (boolean, boolean)
	if #rewards == 0 then
		return true, false
	end

	local currency: any = data.Currency
	local essence = if type(currency) == "table" then currency.Essence else nil
	if not isFinite(essence) or essence < 0 then
		reportCorruption(player, `Essence = {tostring(essence)}`)
		return false, false
	end
	local total = 0
	local needsDecor = false
	for _, reward in rewards do
		total += reward.Essence
		needsDecor = needsDecor or reward.Decor ~= nil
	end
	local newEssence = essence + total
	if not isFinite(newEssence) then
		reportCorruption(player, `Essence {essence} + награда {total}`)
		return false, false
	end
	local factory: any = data.Factory
	if needsDecor and (type(factory) ~= "table" or type(factory.Decor) ~= "table") then
		reportCorruption(player, "Factory.Decor повреждён")
		return false, false
	end

	local grantedPets: { string } = {}
	for _, reward in rewards do
		if reward.PetSpeciesId then
			local petId = PetSystem.GrantPet(player, data, reward.PetSpeciesId, BattlePassConfig.PremiumPetRarity)
			if petId == nil then
				-- Откат: награды выдаются либо целиком, либо никак.
				local pets: any = data.Pets
				for _, id in grantedPets do
					for index = #pets, 1, -1 do
						if type(pets[index]) == "table" and pets[index].Id == id then
							table.remove(pets, index)
						end
					end
				end
				reportCorruption(player, "не удалось выдать пета сезона (раздел Pets повреждён)")
				return false, false
			end
			table.insert(grantedPets, petId)
		end
	end

	currency.Essence = newEssence
	for _, reward in rewards do
		local decor = reward.Decor
		if decor and table.find(factory.Decor, decor) == nil then
			table.insert(factory.Decor, decor)
		end
	end
	return true, #grantedPets > 0
end

local function writeProgress(monetization: any, progress: Progress)
	monetization.BattlePassSeasonId = BattlePassConfig.SeasonId
	monetization.BattlePassTier = progress.Tier
	monetization.BattlePassXP = progress.XP
	monetization.BattlePassPremium = progress.Premium
end

-- Снимки после уже записанной выдачи: ошибка отправки не должна выглядеть как сбой выдачи
-- (ApplyPremium вызывается до вставки маркера квитанции).
local function pushSnapshots(player: Player, petGranted: boolean)
	local pushed, pushErr = pcall(FactorySystem.PushSnapshot, player)
	if not pushed then
		warn(`[BattlePassSystem] Снимок экономики игроку {player.UserId} не отправлен: {pushErr}`)
	end
	if petGranted then
		local ok, err = pcall(PetSystem.PushSnapshot, player)
		if not ok then
			warn(`[BattlePassSystem] Снимок петов игроку {player.UserId} не отправлен: {err}`)
		end
	end
end

-- Транзакция начисления XP (без yield). true — прогресс записан.
local function grantXP(player: Player, data: PlayerProfile, amount: number): boolean
	local monetization, progress = readProgress(player, data)
	if not progress then
		return false
	end

	local maxTier = BattlePassConfig.MaxTier
	local fromTier = progress.Tier
	local tier, xp = progress.Tier, progress.XP
	if tier < maxTier then
		xp += amount
		while tier < maxTier and xp >= BattlePassConfig.TierThresholds[tier + 1] do
			xp -= BattlePassConfig.TierThresholds[tier + 1]
			tier += 1
		end
	end
	if tier >= maxTier then
		xp = 0 -- после MaxTier XP не копится «про запас»
	end

	local ok, petGranted = grantRewards(player, data, collectRewards(fromTier + 1, tier, true, progress.Premium))
	if not ok then
		return false
	end
	writeProgress(monetization, { Tier = tier, XP = xp, Premium = progress.Premium })

	if tier > fromTier then
		pushSnapshots(player, petGranted)
	end
	return true
end

-- Начислить XP игроку (источник — серверное событие). Без yield. true — прогресс записан;
-- false — нет профиля, битый профиль или некорректное amount.
function BattlePassSystem.AddXP(player: Player, amount: number): boolean
	if not isFinite(amount) or amount <= 0 then
		return false
	end
	local data = DataSystem.GetData(player)
	if not data then
		return false -- профиль не загружен / игрок вышел: событие без прогресса
	end
	local ok, result = pcall(grantXP, player, data, amount)
	if not ok then
		reportCorruption(player, `ошибка начисления XP: {result}`)
		return false
	end
	return result
end

--[[
	«Награда» дев-продукта BattlePassPremium — вызывается только из MonetizationSystem при
	выдаче по квитанции (после проверки лога и маркера). Без yield. Premium = true в текущем
	(после ротации) сезоне + PremiumRewards тиров 1..BattlePassTier. false — профиль повреждён,
	ничего не записано (квитанция останется NotProcessedYet).

	Премиум этого сезона уже есть (новая покупка, не повторная доставка — её отсекает маркер):
	повторно ничего не выдаётся, покупка закрывается; warn + событие аналитики
	BattlePassPremiumDuplicate (для ручного возврата Robux). Не допускать такую покупку —
	задача будущего магазина пропуска (серверный гейт перед PromptProductPurchase).
]]
function BattlePassSystem.ApplyPremium(player: Player, data: PlayerProfile): boolean
	local monetization, progress = readProgress(player, data)
	if not progress then
		return false
	end
	if progress.Premium then
		warn(
			`[BattlePassSystem] {player.Name} ({player.UserId}) повторно купил премиум сезона `
				.. `{BattlePassConfig.SeasonId}: уже активен, награды не выдаются повторно`
		)
		AnalyticsSystem.LogEvent(
			player,
			AnalyticsSystem.Events.BattlePassPremiumDuplicate,
			1,
			BattlePassConfig.SeasonId
		)
		return true
	end

	local ok, petGranted = grantRewards(player, data, collectRewards(1, progress.Tier, false, true))
	if not ok then
		return false
	end
	writeProgress(monetization, { Tier = progress.Tier, XP = progress.XP, Premium = true })
	pushSnapshots(player, petGranted)
	return true
end

function BattlePassSystem.Init()
	-- Системы-источники подключаются здесь, а не на уровне модуля: MonetizationSystem требует
	-- BattlePassSystem ради ApplyPremium, и её загрузка не должна тянуть за собой все
	-- игровые системы с их Remotes. К моменту Init они уже загружены (init.server).
	local ChaosBossSystem = require(script.Parent.ChaosBossSystem)
	local PvPRaidSystem = require(script.Parent.PvPRaidSystem)
	local RebirthSystem = require(script.Parent.RebirthSystem)

	FactorySystem.OnEssenceProduced:Connect(function(player: Player)
		BattlePassSystem.AddXP(player, BattlePassConfig.XPPerFactoryCycle)
	end)
	RebirthSystem.OnRebirthPerformed:Connect(function(player: Player)
		BattlePassSystem.AddXP(player, BattlePassConfig.XPPerRebirth)
	end)
	ChaosBossSystem.OnBossHit:Connect(function(player: Player)
		BattlePassSystem.AddXP(player, BattlePassConfig.XPPerChaosHit)
	end)
	PvPRaidSystem.OnRaidCompleted:Connect(function(attacker: Player, _target: Player, stolen: number)
		if isFinite(stolen) and stolen >= BattlePassConfig.MinStolenForRaidXP then
			BattlePassSystem.AddXP(attacker, BattlePassConfig.XPPerRaid)
		end
	end)
	PetSystem.OnPetHatched:Connect(function(player: Player)
		BattlePassSystem.AddXP(player, BattlePassConfig.XPPerHatch)
	end)
end

return BattlePassSystem
