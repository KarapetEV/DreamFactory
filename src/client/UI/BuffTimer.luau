--!strict

--[[
	BuffTimer — чистая модель иконки временного баффа (BuffIcons): видна ли, сколько секунд
	осталось и какая доля иконки уже серая (серое заливает её сверху вниз). Без Instance —
	проверяется в lune.

	- Срок — os.time() конца баффа из атрибута игрока (пишет BuffSystem), «сейчас» — серверное
	  время клиента (Workspace:GetServerTimeNow). Нет атрибута, мусор или бафф истёк — не видна.
	- Полная шкала (Total) фиксируется, когда клиент впервые видит новый срок:
	  max(осталось, базовая длительность баффа). Продление покупкой (срок сдвинулся) — шкала
	  заново, иконка снова целиком цветная; вход в игру посреди баффа — серое сразу показывает
	  прошедшую часть от базовой длительности.
]]

export type Timer = {
	ExpiresAt: number?, -- срок, для которого посчитана шкала
	Total: number, -- секунд в полной шкале
}

export type State = {
	Visible: boolean,
	SecondsLeft: number, -- целые секунды вверх (0 — не видна)
	Grey: number, -- 0..1: доля иконки сверху, уже ставшая серой
}

local BuffTimer = {}

function BuffTimer.new(): Timer
	return { ExpiresAt = nil, Total = 0 }
end

-- Обновляет шкалу по текущему сроку и возвращает, что рисовать. baseDuration — длительность
-- одной покупки (BuffConfig.Buffs[id].Duration).
function BuffTimer.Update(timer: Timer, expiresAt: unknown, serverNow: number, baseDuration: number): State
	local valid = type(expiresAt) == "number" and expiresAt == expiresAt and expiresAt < math.huge
	local left = if valid then (expiresAt :: number) - serverNow else 0
	if not (left > 0) then
		timer.ExpiresAt = nil
		return { Visible = false, SecondsLeft = 0, Grey = 1 }
	end

	if timer.ExpiresAt ~= expiresAt then
		timer.ExpiresAt = expiresAt :: number
		timer.Total = math.max(left, baseDuration)
	end
	local grey = if timer.Total > 0 then math.clamp(1 - left / timer.Total, 0, 1) else 0
	return { Visible = true, SecondsLeft = math.ceil(left), Grey = grey }
end

export type ButtonState = "Hidden" | "Ready" | "Pending" | "Active"

-- Заряды из атрибута игрока: целое ≥ 0; мусор/nil — 0.
function BuffTimer.Charges(value: unknown): number
	if type(value) == "number" and value == value and value >= 0 and value < math.huge and value % 1 == 0 then
		return value
	end
	return 0
end

-- Состояние иконки-кнопки активации (BuffIcons). Только UX: заряд и запуск решает сервер.
--   Active  — бафф действует: таймер, клик игнорируется (заряд не тратится);
--   Hidden  — не действует и зарядов нет: иконки нет;
--   Pending — клик уже отправлен, ждём ответа сервера (атрибут срока): повторно не шлём;
--   Ready   — есть заряд: клик тратит его и запускает бафф.
function BuffTimer.ButtonState(charges: number, active: boolean, pending: boolean): ButtonState
	if active then
		return "Active"
	end
	if charges <= 0 then
		return "Hidden"
	end
	return if pending then "Pending" else "Ready"
end

return BuffTimer
