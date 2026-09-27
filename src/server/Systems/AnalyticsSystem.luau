--!strict

--[[
	AnalyticsSystem — тонкая обёртка над Roblox AnalyticsService (раздел 9 ТЗ). Единственное
	место, которое обращается к AnalyticsService: остальные системы зовут только эти функции
	(в lune-тестах сервис — стаб Harness, вызовы копятся в world.AnalyticsEvents).

	- LogEvent — кастомное событие (LogCustomEvent): rebirth, выдача покупок, участие в
	  Хаос-ивенте, PvP-атака. Имена событий — AnalyticsSystem.Events.
	- RecordFunnelStep — воронка первых 10 минут (LogOnboardingFunnelStepEvent): первый сбор →
	  первая переработка → первый апгрейд → первый пет. Шаг логируется ровно один раз на
	  игрока: момент шага пишется в Meta.First*At профиля, заполненное поле — шаг уже был.

	Аналитика никогда не ломает вызывающего: без yield, каждый вызов сервиса под pcall, сбой —
	одно предупреждение за процесс на вид вызова. Вызывать можно прямо из транзакций.
]]

local AnalyticsService = game:GetService("AnalyticsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.shared.Types)

type PlayerProfile = Types.PlayerProfile

export type FunnelStep = "FirstCollect" | "FirstProcess" | "FirstUpgrade" | "FirstPet"

type FunnelStepDefinition = {
	Step: number, -- номер шага воронки (порядок в дашборде Roblox)
	Name: string,
	MetaField: string, -- поле Meta профиля с моментом шага (os.time)
}

local AnalyticsSystem = {}

-- Имена кастомных событий (LogCustomEvent).
AnalyticsSystem.Events = {
	RebirthCycleEnded = "RebirthCycleEnded", -- value — Essence, потраченная (обнулённая) rebirth'ом
	RebirthCycleStarted = "RebirthCycleStarted", -- value — новый Rebirth.Count
	DevProductPurchased = "DevProductPurchased", -- поле 1 — Id продукта из DevProductConfig
	GamePassPurchased = "GamePassPurchased", -- поле 1 — Id геймпасса из MonetizationConfig
	ChaosEventJoined = "ChaosEventJoined", -- value — номер ивента; первый засчитанный удар игрока
	PvPRaid = "PvPRaid", -- value — украденная Essence; атакующий
	-- Оплачен премиум пропуска, который уже активен: квитанция закрыта без выдачи — кандидат
	-- на ручной возврат Robux. Поле 1 — SeasonId.
	BattlePassPremiumDuplicate = "BattlePassPremiumDuplicate",
}

local FUNNEL_STEPS: { [FunnelStep]: FunnelStepDefinition } = {
	FirstCollect = { Step = 1, Name = "FirstCollect", MetaField = "FirstCollectAt" },
	FirstProcess = { Step = 2, Name = "FirstProcess", MetaField = "FirstProcessAt" },
	FirstUpgrade = { Step = 3, Name = "FirstUpgrade", MetaField = "FirstUpgradeAt" },
	FirstPet = { Step = 4, Name = "FirstPet", MetaField = "FirstPetAt" },
}
AnalyticsSystem.FunnelSteps = FUNNEL_STEPS

local reportedFailures: { [string]: true } = {}

local function reportFailure(kind: string, err: unknown)
	if reportedFailures[kind] then
		return
	end
	reportedFailures[kind] = true
	warn(`[AnalyticsSystem] Сбой {kind}, дальнейшие сбои этого вида не логируются: {err}`)
end

-- Кастомное событие игрока. field01 — строковое измерение (CustomField01), например Id товара.
function AnalyticsSystem.LogEvent(player: Player, eventName: string, value: number?, field01: string?)
	local ok, err = pcall(function()
		local customFields = if field01
			then { [Enum.AnalyticsCustomFieldKeys.CustomField01.Name] = field01 }
			else nil
		AnalyticsService:LogCustomEvent(player, eventName, value or 1, customFields)
	end)
	if not ok then
		reportFailure("LogCustomEvent", err)
	end
end

--[[
	Шаг воронки онбординга — один раз на игрока. Вызывать в момент самого события (после
	успешной записи транзакции). Поле Meta уже заполнено (или Meta битая) — ничего не делает.
	Поле пишется до вызова сервиса: сбой аналитики не приведёт к повторному логу шага.
	true — шаг записан сейчас.
]]
function AnalyticsSystem.RecordFunnelStep(player: Player, data: PlayerProfile, step: FunnelStep): boolean
	local definition = FUNNEL_STEPS[step]
	local meta: any = data.Meta
	if definition == nil or type(meta) ~= "table" or meta[definition.MetaField] ~= nil then
		return false
	end
	meta[definition.MetaField] = os.time()

	local ok, err = pcall(function()
		AnalyticsService:LogOnboardingFunnelStepEvent(player, definition.Step, definition.Name)
	end)
	if not ok then
		reportFailure("LogOnboardingFunnelStepEvent", err)
	end
	return true
end

return AnalyticsSystem
