--!strict

-- Не секретные параметры петов (раздел 5.3 ТЗ): слоты активных петов, лимиты инвентаря и запросов.
-- Шансы редкости/мутаций — отдельно и только на сервере (src/server/Config/PetRarityConfig.luau).
-- Каркас: заглушечные значения. Реальный баланс считает economy-balancer.

export type PetDefinition = {
	-- Активных петов без геймпасса (GDD: «до 3 активных петов бесплатно»).
	BaseEquipSlots: number,
	-- Id геймпасса доп. слотов в профиле (Monetization.GamePassesOwned) и сколько слотов он даёт.
	-- Владение в профиль пишет MonetizationSystem; PetSystem читает только поле профиля.
	ExtraSlotsGamePassId: string,
	ExtraEquipSlots: number,
	-- Потолок числа петов в профиле: без него HatchCocoon раздувал бы запись DataStore без предела.
	MaxInventory: number,
	-- Rate limiting HatchCocoon/EquipPet/UnequipPet (общий на игрока): не больше
	-- MaxRequestsPerWindow вызовов за RequestWindow секунд.
	RequestWindow: number,
	MaxRequestsPerWindow: number,
	-- Сколько отклонённых запросов в окне считается подозрительной активностью (пишется в лог).
	SuspiciousRejectThreshold: number,
	-- Через сколько секунд после первого снимка при загрузке профиля отправить его ещё раз
	-- (страховка от гонки: клиент мог не успеть подключить OnClientEvent). Один повтор, не цикл.
	InitialSnapshotResendDelay: number,
}

local PetConfig: PetDefinition = {
	BaseEquipSlots = 3,
	ExtraSlotsGamePassId = "ExtraPetSlots",
	ExtraEquipSlots = 3,
	MaxInventory = 200,
	RequestWindow = 1,
	MaxRequestsPerWindow = 5,
	SuspiciousRejectThreshold = 15,
	InitialSnapshotResendDelay = 2,
}

return PetConfig
