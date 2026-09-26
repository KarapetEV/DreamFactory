--!strict

-- Коконы снов (раздел 5.3 ТЗ): что можно вылупить и за сколько Essence. Не секрет — клиент
-- берёт отсюда список и цены для магазина. Шансы редкости и мутаций сюда НЕ кладём: они
-- server-only (src/server/Config/PetRarityConfig.luau), у каждого кокона здесь там обязана
-- быть таблица шансов (проверяется при загрузке PetRarityConfig).
-- Каркас: заглушечные значения. Реальный баланс считает economy-balancer.

export type CocoonDefinition = {
	Id: string,
	DisplayName: string,
	-- Цена в Essence; списывает только сервер (PetSystem.HatchCocoon).
	Price: number,
	SortOrder: number,
}

local CocoonConfig: { [string]: CocoonDefinition } = {
	DrowsyCocoon = {
		Id = "DrowsyCocoon",
		DisplayName = "Дремотный кокон",
		Price = 100,
		SortOrder = 1,
	},
	LucidCocoon = {
		Id = "LucidCocoon",
		DisplayName = "Осознанный кокон",
		Price = 1000,
		SortOrder = 2,
	},
}

return CocoonConfig
