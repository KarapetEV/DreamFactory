--!strict

--[[
	Стражи Сна и формула PvP-защиты (раздел 5.6 ТЗ/GDD). Отдельно от PvPConfig (лимиты кражи)
	и от MonetizationConfig (цены) — здесь только эффект обороны. Не секрет — лежит в shared:
	будущий UI расстановки стражей покажет их эффект. Считает PvPRaidSystem.

	Формула (детерминированная, без ролла — шанса провала рейда нет, стражи только
	уменьшают добычу):
	    guards  = Σ Types[id].Defense по первым MaxGuards записям PvP.GuardsPlaced цели
	              (неизвестный id — 0, записи сверх MaxGuards не считаются);
	    pets    = FearfulDefense цели × FearfulPetDefenseScale
	              (FearfulDefense — Σ бонусов надетых Fearful-петов, PetSystem.GetCachedBonuses);
	    защита  = min(guards + pets, MaxReduction);
	    stolen  = floor(base × (1 − защита)),  base — PvPConfig (StealPercent/HardCap).
	Линейная сумма с потолком выбрана ради предсказуемости: игрок видит «+10% защиты» у
	каждого стража, а MaxReduction < 1 не даёт сделать фабрику полностью неуязвимой одной
	только расстановкой (полная неуязвимость — отдельный геймпасс «Щит Сновидца», не здесь).

	Каркас: заглушечные значения. Реальный баланс считает economy-balancer.
]]

local UpgradeEffects = require(script.Parent.Parent.UpgradeEffects)

export type GuardDefinition = {
	Id: string, -- значение в PvP.GuardsPlaced
	DisplayName: string,
	Defense: number, -- доля снижения кражи, (0, MaxReduction]
}

export type GuardConfigDefinition = {
	Types: { [string]: GuardDefinition },
	-- Сколько записей GuardsPlaced учитывается (лимит расстановки).
	MaxGuards: number,
	-- Перевод очков Fearful-петов (Σ бонусов) в долю защиты.
	FearfulPetDefenseScale: number,
	-- Потолок суммарной защиты, [0, 1).
	MaxReduction: number,
}

local GuardConfig: GuardConfigDefinition = {
	Types = {
		SleepyWisp = {
			Id = "SleepyWisp",
			DisplayName = "Сонный огонёк",
			Defense = 0.05,
		},
		LullabyTurret = {
			Id = "LullabyTurret",
			DisplayName = "Турель колыбельной",
			Defense = 0.1,
		},
		NightWarden = {
			Id = "NightWarden",
			DisplayName = "Ночной страж",
			Defense = 0.15,
		},
	},
	MaxGuards = 3,
	FearfulPetDefenseScale = 0.5,
	MaxReduction = 0.6,
}

-- Проверки при загрузке: защита ≥ 1 обнулила бы кражу, отрицательная — увеличила бы её.
do
	local isFinite = UpgradeEffects.IsFinite
	local c = GuardConfig
	assert(
		isFinite(c.MaxReduction) and c.MaxReduction >= 0 and c.MaxReduction < 1,
		`GuardConfig: MaxReduction должен быть в [0, 1), получено {c.MaxReduction}`
	)
	assert(
		isFinite(c.MaxGuards) and c.MaxGuards >= 0 and c.MaxGuards % 1 == 0,
		`GuardConfig: некорректный MaxGuards {c.MaxGuards}`
	)
	assert(
		isFinite(c.FearfulPetDefenseScale) and c.FearfulPetDefenseScale >= 0,
		`GuardConfig: FearfulPetDefenseScale должен быть ≥ 0, получено {c.FearfulPetDefenseScale}`
	)
	for key, guard in c.Types do
		assert(guard.Id == key, `GuardConfig: ключ {key} не совпадает с Id {guard.Id}`)
		assert(
			type(guard.DisplayName) == "string" and guard.DisplayName ~= "",
			`GuardConfig: у {key} нет DisplayName`
		)
		assert(
			isFinite(guard.Defense) and guard.Defense > 0 and guard.Defense <= c.MaxReduction,
			`GuardConfig: у {key} Defense должен быть в (0, MaxReduction], получено {guard.Defense}`
		)
	end
end

return GuardConfig
