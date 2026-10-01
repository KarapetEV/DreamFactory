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

return BuffTimer
