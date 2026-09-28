--!strict

--[[
	Пороги серверной проверки достоверности позиции игрока (MovementGuard, анти-чит — раздел 7 ТЗ).
	SERVER-ONLY: эксплойтер не должен видеть точный потолок, чтобы подстроить телепорт под него.

	Скорость считается отдельно по горизонтали, вверх и вниз: падение законно быстрее ходьбы,
	а подъём ограничен прыжком. За dt секунд с последней доверенной точки «бесплатно» можно
	сместиться на MaxHorizontalSpeed × dt по горизонтали, MaxRiseSpeed × dt вверх и
	MaxFallSpeed × dt вниз. Превышение (пачка репликации после лага, два вызова в одном кадре
	с dt ≈ 0) списывается из «ведра» допуска: ёмкость BurstAllowance studs, пополнение
	BurstRefillRate studs/s. Не хватает запаса — скачок.

	Ведро, а не фиксированный допуск на замер: допуск на каждый замер складывался бы в
	скорость (частые запросы клиента → потолок + допуск × частота). С ведром длительная
	скорость не выше MaxHorizontalSpeed + BurstRefillRate при любой частоте запросов.

	Стартовые значения — с запасом от дефолтов Roblox (WalkSpeed 16, JumpPower 50 → ~50 studs/s
	вверх в момент толчка, Workspace.Gravity 196.2). Апгрейдов скорости, отбрасывания и
	транспорта в игре нет. Реальная настройка — economy-balancer/QA по логам живых игроков; при
	появлении ускорителей/батутов/Seat/движущихся платформ потолки нужно поднять вместе с ними
	(или учитывать скорость носителя).
]]

export type MovementGuardDefinition = {
	-- Как часто сервер сам снимает позицию всех игроков (сек). Держит доверенную точку свежей
	-- между запросами: без фоновых замеров телепорт после долгой паузы прятался бы в большом dt.
	SampleInterval: number,
	-- Горизонтальный потолок (studs/s): WalkSpeed 16 × 2.
	MaxHorizontalSpeed: number,
	-- Длительный потолок подъёма (studs/s): склон/лестница на WalkSpeed 16 + запас. Прыжок
	-- (JumpPower 50 → ~6.4 studs за первые 0.25 с, пик ~6.4 studs) укладывается в ведро
	-- допуска; держать высокий потолок ради прыжка значило бы пропускать fly-hack.
	MaxRiseSpeed: number,
	-- Вертикальный потолок вниз (studs/s): свободное падение с ~400 studs даёт ≈ 396 studs/s.
	MaxFallSpeed: number,
	-- Ёмкость ведра допуска (studs): пачка репликации после ~1–1.5 с лага при WalkSpeed 16.
	BurstAllowance: number,
	-- Пополнение ведра (studs/s): длительная скорость эксплойта ≤ MaxHorizontalSpeed + это.
	BurstRefillRate: number,
	-- После отклонённого скачка (или периода без живого корня) доверенная точка догоняет
	-- персонажа только на этой скорости (studs/s) по горизонтали и вверх: телепорт + ожидание
	-- дают не больше честной ходьбы (WalkSpeed 16 × 1.25), а честного игрока после редкого
	-- физического «флинга» всё же отпускает без респавна.
	RecoverySpeed: number,
	-- Не больше одного предупреждения о подозрительном скачке на игрока за это окно (сек).
	SuspiciousLogWindow: number,
	-- Через сколько секунд без HumanoidRootPart в Workspace предупредить в лог (ожидание базы
	-- при этом продолжается реже — до появления корня, нового персонажа или выхода).
	SpawnRootTimeout: number,
}

local MovementGuardConfig: MovementGuardDefinition = {
	SampleInterval = 0.25,
	MaxHorizontalSpeed = 32,
	MaxRiseSpeed = 20,
	MaxFallSpeed = 400,
	BurstAllowance = 12,
	BurstRefillRate = 8,
	RecoverySpeed = 20,
	SuspiciousLogWindow = 60,
	SpawnRootTimeout = 10,
}

for key, value in MovementGuardConfig :: any do
	assert(
		type(value) == "number" and value == value and value > 0 and value < math.huge,
		`MovementGuardConfig.{key} должен быть конечным положительным числом, получено {value}`
	)
end
assert(
	MovementGuardConfig.RecoverySpeed <= MovementGuardConfig.MaxHorizontalSpeed,
	"MovementGuardConfig: RecoverySpeed не должен превышать MaxHorizontalSpeed"
)

return MovementGuardConfig
