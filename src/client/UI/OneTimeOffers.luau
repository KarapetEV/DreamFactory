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
	    пак зарядов не влезет под потолок        → Full (часть зарядов сгорела бы);
	    цена не получена / не продаётся          → Unavailable (без явной цены не предлагаем);
	    окно покупки только что открыто          → Waiting;
	    иначе                                    → Buy.
	  Действующий бафф покупку не блокирует: заряды копятся, тратятся по одному.
	- Строка баффа продаёт пак зарядов (BuffConfig PackSize). Рядом с ценой — сколько зарядов уже
	  есть (атрибут игрока Attributes.<Id>Charges, пишет BuffSystem) из потолка MaxCharges. Если
	  пак не влезет целиком (Charges + PackSize > MaxCharges) — кнопка неактивна (Full) с
	  подсказкой сначала потратить заряды. Только UX: покупку через обход UI сервер всё равно
	  выдаст, зажав заряды потолком (BuffSystem.Grant).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.shared.Attributes)
local DevProductConfig = require(ReplicatedStorage.shared.Config.DevProductConfig)
local AutoCollectorConfig = require(ReplicatedStorage.shared.Config.AutoCollectorConfig)
local BuffConfig = require(ReplicatedStorage.shared.Config.BuffConfig)

type DevProductDefinition = DevProductConfig.DevProductDefinition

export type PriceStatus = "Idle" | "Loading" | "Ready" | "NotForSale" | "Failed"
export type ButtonState = "Buy" | "Waiting" | "Unavailable" | "Included" | "Full"

export type ChargesInfo = {
	Charges: number, -- зарядов сейчас (мусор в атрибуте — 0)
	MaxCharges: number,
	Overflow: boolean, -- пак не влезет целиком под потолок: покупка недоступна (Full)
}

-- Атрибут игрока с зарядами баффа по BuffId.
local CHARGES_ATTRIBUTES: { [string]: string } = {
	MagnetBoost = Attributes.MagnetBoostCharges,
	SpeedBoost = Attributes.SpeedBoostCharges,
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

-- Имя атрибута игрока с зарядами баффа; nil — продукт не бафф.
function OneTimeOffers.ChargesAttribute(product: DevProductDefinition): string?
	if product.Reward.Kind ~= "Buff" then
		return nil
	end
	return CHARGES_ATTRIBUTES[product.Reward.BuffId :: string]
end

-- Заряды для строки пака: сколько есть, потолок и сгорит ли часть пака. nil — продукт не бафф.
function OneTimeOffers.ChargesInfo(product: DevProductDefinition, chargesValue: unknown): ChargesInfo?
	if product.Reward.Kind ~= "Buff" then
		return nil
	end
	local buff = BuffConfig.Buffs[product.Reward.BuffId :: any]
	local valid = type(chargesValue) == "number"
		and chargesValue == chargesValue
		and chargesValue >= 0
		and chargesValue < math.huge
	local charges = if valid then math.floor(chargesValue :: number) else 0
	return {
		Charges = charges,
		MaxCharges = buff.MaxCharges,
		Overflow = charges + buff.PackSize > buff.MaxCharges,
	}
end

-- ownedPasses — GamePassesOwned из последнего снимка сервера (nil — снимка ещё нет);
-- chargesValue — атрибут зарядов баффа (Attributes.<Id>Charges; для паков Эссенции не нужен).
function OneTimeOffers.ButtonState(
	product: DevProductDefinition,
	priceStatus: PriceStatus,
	ownedPasses: { string }?,
	promptLocked: boolean,
	chargesValue: unknown?
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
	local charges = OneTimeOffers.ChargesInfo(product, chargesValue)
	if charges and charges.Overflow then
		return "Full"
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
