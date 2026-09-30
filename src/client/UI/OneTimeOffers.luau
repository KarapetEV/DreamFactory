--!strict

--[[
	OneTimeOffers — чистая логика вкладки «Разовые покупки» ShopUI (без Instance — проверяется в lune).

	- Позиции — дев-продукты DevProductConfig с Reward.Kind "Essence" (паки Эссенции) и "Buff"
	  (Magnet Boost, Speed Boost) в порядке конфига. Премиум сезонного пропуска сюда не входит —
	  его место во вкладке «Сезонный пропуск».
	- Кнопка — только UX: сервер выдаёт покупку по квитанции Roblox (ProcessReceipt) и ничего от
	  клиента не принимает. Порядок условий:
	    ProductId = 0 (заглушка)                 → Unavailable;
	    Magnet Boost, снимка владения ещё нет     → Waiting;
	    Magnet Boost у владельца Авто-сборщика    → Included (бафф ничего не добавил бы);
	    цена не получена / не продаётся          → Unavailable (без явной цены не предлагаем);
	    окно покупки только что открыто          → Waiting;
	    иначе                                    → Buy.
	  Действующий бафф покупку не блокирует: повторная покупка продлевает его (стекинг).
	- Остаток баффа — из атрибута игрока (Attributes.<Id>ExpiresAt, пишет BuffSystem) против
	  серверного времени; целые секунды вверх, nil — бафф не действует или атрибут битый.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.shared.Attributes)
local DevProductConfig = require(ReplicatedStorage.shared.Config.DevProductConfig)
local AutoCollectorConfig = require(ReplicatedStorage.shared.Config.AutoCollectorConfig)

type DevProductDefinition = DevProductConfig.DevProductDefinition

export type PriceStatus = "Idle" | "Loading" | "Ready" | "NotForSale" | "Failed"
export type ButtonState = "Buy" | "Waiting" | "Unavailable" | "Included"

-- Атрибут игрока со сроком баффа по BuffId.
local BUFF_ATTRIBUTES: { [string]: string } = {
	MagnetBoost = Attributes.MagnetBoostExpiresAt,
	SpeedBoost = Attributes.SpeedBoostExpiresAt,
}

local OneTimeOffers = {}

function OneTimeOffers.List(): { DevProductDefinition }
	local list = {}
	for _, product in DevProductConfig.Products do
		local kind = product.Reward.Kind
		if kind == "Essence" or kind == "Buff" then
			table.insert(list, product)
		end
	end
	return list
end

-- Имя атрибута игрока со сроком баффа; nil — продукт не бафф.
function OneTimeOffers.BuffAttribute(product: DevProductDefinition): string?
	if product.Reward.Kind ~= "Buff" then
		return nil
	end
	return BUFF_ATTRIBUTES[product.Reward.BuffId :: string]
end

-- Сколько целых секунд (вверх) ещё действует бафф; nil — не действует или значение битое.
function OneTimeOffers.BuffSecondsLeft(expiresAt: unknown, serverNow: number): number?
	if type(expiresAt) ~= "number" or expiresAt ~= expiresAt or expiresAt == math.huge then
		return nil
	end
	local left = expiresAt - serverNow
	if not (left > 0) then
		return nil
	end
	return math.ceil(left)
end

-- ownedPasses — GamePassesOwned из последнего снимка сервера (nil — снимка ещё нет).
function OneTimeOffers.ButtonState(
	product: DevProductDefinition,
	priceStatus: PriceStatus,
	ownedPasses: { string }?,
	promptLocked: boolean
): ButtonState
	if product.ProductId == 0 then
		return "Unavailable"
	end
	if product.Reward.Kind == "Buff" and product.Reward.BuffId == "MagnetBoost" then
		if type(ownedPasses) ~= "table" then
			return "Waiting"
		end
		if table.find(ownedPasses, AutoCollectorConfig.GamePassId) ~= nil then
			return "Included"
		end
	end
	if priceStatus ~= "Ready" then
		return "Unavailable"
	end
	if promptLocked then
		return "Waiting"
	end
	return "Buy"
end

return OneTimeOffers
