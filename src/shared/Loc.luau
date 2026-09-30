--!strict

--[[
	Таблица локализации UI (раздел 10 ТЗ): все строки интерфейса живут здесь, а не в UI-модулях.
	Ключ — "Модуль.Поле" (например "HUD.RebirthButton"), значение — текст на каждом языке.

	Русский — основной (целевой рынок по GDD), английский — вторичный, черновой перевод.
	Формат-строки (%s, %d, %.2f) переносятся как есть: string.format делает место вызова, поэтому
	набор и порядок плейсхолдеров в ru и en обязан совпадать (проверяет Loc.spec).

	UI-модули читают строки один раз при загрузке (local TEXT = { Поле = Loc.Get(...) }).
	Loc.Get никогда не бросает: нет ключа или языка — warn один раз на ключ и сам ключ как
	видимый fallback (пустая строка спрятала бы ошибку).
]]

export type LocaleId = "ru" | "en"

export type LocalizedString = {
	ru: string,
	en: string,
}

local Loc = {}

Loc.DefaultLocale = "ru" :: LocaleId

Loc.Strings = {
	-- HUD
	["HUD.EssenceLabel"] = { ru = "Essence: %s", en = "Essence: %s" },
	["HUD.BiomeLabel"] = { ru = "Биом: %s", en = "Biome: %s" },
	["HUD.ClarityLabel"] = { ru = "Ясность: ×%.2f · Перерождений: %d", en = "Clarity: ×%.2f · Rebirths: %d" },
	["HUD.RebirthProgress"] = { ru = "%s / %s", en = "%s / %s" },
	["HUD.RebirthButton"] = { ru = "Перерождение", en = "Rebirth" },
	["HUD.RebirthDone"] = { ru = "Перерождение выполнено!", en = "Rebirth complete!" },
	["HUD.RebirthDenied"] = { ru = "Перерождение отклонено", en = "Rebirth denied" },
	["HUD.FragmentsLabel"] = { ru = "Фрагменты: %s / %s", en = "Fragments: %s / %s" },
	["HUD.Waiting"] = { ru = "Загрузка...", en = "Loading..." },
	["HUD.Buy"] = { ru = "Купить: %.0f", en = "Buy: %.0f" },
	["HUD.Max"] = { ru = "МАКС", en = "MAX" },
	["HUD.Pending"] = { ru = "...", en = "..." },
	["HUD.ChaosLabel"] = { ru = "Хаос: %s / %s", en = "Chaos: %s / %s" },
	["HUD.ChaosActive"] = { ru = "Вторжение Кошмара!", en = "Nightmare Invasion!" },
	["HUD.ChaosIncoming"] = { ru = "Кошмар приближается...", en = "A Nightmare approaches..." },

	-- ShopUI
	["ShopUI.Title"] = { ru = "Магазин", en = "Shop" },
	["ShopUI.Close"] = { ru = "X", en = "X" },
	["ShopUI.Menu"] = { ru = "Магазин", en = "Shop" },
	["ShopUI.TabGamePasses"] = { ru = "Геймпассы", en = "Game Passes" },
	["ShopUI.TabOneTime"] = { ru = "Разовые покупки", en = "One-time" },
	["ShopUI.TabSeason"] = { ru = "Сезонный пропуск", en = "Season Pass" },
	["ShopUI.PriceLoading"] = { ru = "Цена: загрузка...", en = "Price: loading..." },
	["ShopUI.Price"] = { ru = "%d R$", en = "%d R$" },
	["ShopUI.PriceFailed"] = { ru = "Цена недоступна", en = "Price unavailable" },
	["ShopUI.NotForSale"] = { ru = "Не продаётся", en = "Not for sale" },
	["ShopUI.NotConfigured"] = { ru = "Геймпасс не настроен", en = "Pass not set up" },
	["ShopUI.Buy"] = { ru = "Купить", en = "Buy" },
	["ShopUI.Owned"] = { ru = "Куплено", en = "Owned" },
	["ShopUI.Waiting"] = { ru = "...", en = "..." },
	["ShopUI.Unavailable"] = { ru = "Недоступно", en = "Unavailable" },
	["ShopUI.SoonButton"] = { ru = "Скоро", en = "Soon" },
	["ShopUI.SoonPrice"] = { ru = "Цена появится позже", en = "Price coming later" },

	-- PetInventoryUI
	["PetInventoryUI.Title"] = { ru = "Питомцы", en = "Pets" },
	["PetInventoryUI.Close"] = { ru = "X", en = "X" },
	["PetInventoryUI.Menu"] = { ru = "Питомцы", en = "Pets" },
	["PetInventoryUI.Slots"] = { ru = "Слоты: %d / %d · Петов: %d", en = "Slots: %d / %d · Pets: %d" },
	["PetInventoryUI.Hatch"] = { ru = "%s — %.0f", en = "%s — %.0f" },
	["PetInventoryUI.InventoryFull"] = { ru = "Инвентарь полон", en = "Inventory full" },
	["PetInventoryUI.Empty"] = { ru = "Петов пока нет — вылупите кокон", en = "No pets yet — hatch a cocoon" },
	["PetInventoryUI.Equip"] = { ru = "Надеть", en = "Equip" },
	["PetInventoryUI.Unequip"] = { ru = "Снять", en = "Unequip" },
	["PetInventoryUI.NoSlots"] = { ru = "Нет слотов", en = "No slots" },
	["PetInventoryUI.Waiting"] = { ru = "...", en = "..." },
	["PetInventoryUI.Mutation"] = { ru = "мутация: %s", en = "mutation: %s" },
	["PetInventoryUI.Hatched"] = { ru = "Вылупился: %s (%s)", en = "Hatched: %s (%s)" },
	["PetInventoryUI.Denied"] = { ru = "Запрос отклонён сервером", en = "Request denied by server" },
	["PetInventoryUI.Pet"] = { ru = "%s · %s · %s", en = "%s · %s · %s" },

	-- PlayerEffects (Visuals)
	["PlayerEffects.Raided"] = { ru = "Вторжение в ваш сон!", en = "Your dream is being invaded!" },
	-- ChaosEventUI
	["ChaosEventUI.Title"] = { ru = "Вторжение Кошмара", en = "Nightmare Invasion" },
	["ChaosEventUI.Health"] = { ru = "%s / %s", en = "%s / %s" },
	["ChaosEventUI.Contribution"] = { ru = "Ваш вклад: %s урона", en = "Your damage: %s" },
	["ChaosEventUI.Attack"] = { ru = "Атаковать", en = "Attack" },
	["ChaosEventUI.TooFar"] = { ru = "Подойдите ближе к Кошмару", en = "Get closer to the Nightmare" },
	["ChaosEventUI.Victory"] = { ru = "Кошмар повержен!", en = "Nightmare defeated!" },
	["ChaosEventUI.Timeout"] = { ru = "Кошмар отступил.", en = "Nightmare retreated." },
	["ChaosEventUI.Reward"] = { ru = "Награда: +%s Essence", en = "Reward: +%s Essence" },
	["ChaosEventUI.NoReward"] = { ru = "Вы не участвовали. Награда: 0", en = "You did not take part. Reward: 0" },
} :: { [string]: LocalizedString }

-- Ключи, о которых уже предупредили (не спамим лог на каждое обращение).
local reported: { [string]: true } = {}

function Loc.Get(key: string, locale: LocaleId?): string
	local lang = locale or Loc.DefaultLocale
	local entry = Loc.Strings[key]
	local text = if type(entry) == "table" then (entry :: any)[lang] else nil
	if type(text) == "string" and text ~= "" then
		return text
	end
	if not reported[key] then
		reported[key] = true
		warn(`[Loc] Нет строки "{tostring(key)}" для языка {tostring(lang)} — показан ключ`)
	end
	return tostring(key)
end

return Loc
