--!strict

-- Каркас конфига: структура + заглушечные значения. Реальный баланс считает economy-balancer.
--
-- Ступенчатые апгрейды (раздел 5.2 ТЗ; находки M-1/M-4 security-ревью): на каждый EffectType —
-- цепочка уровней с явным MaxLevel. Профиль хранит только уровень (целое 0..MaxLevel),
-- значение эффекта сервер берёт отсюда на каждое обращение — готовое число в профиль не пишется.
--
-- Id апгрейда (аргумент Remotes.PurchaseUpgrade) = EffectType = ключ таблицы.
-- Уровень 0 = «ничего не куплено», значение эффекта на нём — BaseValue.
-- Levels[n] — покупка уровня n: Price в Essence и Value эффекта после покупки.
-- MaxLevel обязан совпадать с #Levels (проверяется при загрузке UpgradeEffects).
--
-- Смысл Value по типам:
--   ConveyorSpeed    — задержка конвейера, секунд на один цикл переработки (меньше = быстрее);
--   StorageCapacity  — ёмкость буфера сырых фрагментов (Factory.RawFragments);
--   CollectionRadius — радиус сбора фрагментов, studs;
--   CollectionSpeed  — кулдаун между успешными сборами, секунд (меньше = быстрее).

export type UpgradeEffectType = "ConveyorSpeed" | "StorageCapacity" | "CollectionRadius" | "CollectionSpeed"

export type UpgradeLevel = {
	Price: number,
	Value: number,
}

export type UpgradeTrack = {
	Id: UpgradeEffectType,
	DisplayName: string,
	BaseValue: number,
	MaxLevel: number,
	Levels: { UpgradeLevel },
}

local UpgradeConfig: { [string]: UpgradeTrack } = {
	ConveyorSpeed = {
		Id = "ConveyorSpeed",
		DisplayName = "Ускоренный конвейер",
		BaseValue = 2,
		MaxLevel = 5,
		Levels = {
			{ Price = 100, Value = 1.7 },
			{ Price = 250, Value = 1.45 },
			{ Price = 600, Value = 1.2 },
			{ Price = 1500, Value = 1 },
			{ Price = 4000, Value = 0.8 },
		},
	},
	StorageCapacity = {
		Id = "StorageCapacity",
		DisplayName = "Склад",
		BaseValue = 100,
		MaxLevel = 5,
		Levels = {
			{ Price = 150, Value = 150 },
			{ Price = 400, Value = 225 },
			{ Price = 1000, Value = 350 },
			{ Price = 2500, Value = 500 },
			{ Price = 6000, Value = 750 },
		},
	},
	CollectionRadius = {
		Id = "CollectionRadius",
		DisplayName = "Радиус сбора",
		BaseValue = 12,
		MaxLevel = 5,
		Levels = {
			{ Price = 120, Value = 14 },
			{ Price = 300, Value = 16 },
			{ Price = 750, Value = 18 },
			{ Price = 1800, Value = 20 },
			{ Price = 4500, Value = 22 },
		},
	},
	CollectionSpeed = {
		Id = "CollectionSpeed",
		DisplayName = "Скорость сбора",
		BaseValue = 0.3,
		MaxLevel = 5,
		Levels = {
			{ Price = 120, Value = 0.27 },
			{ Price = 300, Value = 0.24 },
			{ Price = 750, Value = 0.21 },
			{ Price = 1800, Value = 0.18 },
			{ Price = 4500, Value = 0.15 },
		},
	},
}

return UpgradeConfig
