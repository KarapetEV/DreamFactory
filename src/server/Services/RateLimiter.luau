--!strict

-- Простой rate limit по таблице меток времени (раздел 7 ТЗ): не больше maxRequests
-- вызовов за window секунд. Таблицу times хранит вызывающая система (одна на игрока).

local RateLimiter = {}

-- true — запрос можно обрабатывать (его метка уже добавлена в times).
function RateLimiter.Allow(times: { number }, now: number, window: number, maxRequests: number): boolean
	local windowStart = now - window

	local kept = 0
	for _, t in times do
		if t > windowStart then
			kept += 1
			times[kept] = t
		end
	end
	for i = #times, kept + 1, -1 do
		times[i] = nil
	end

	if kept >= maxRequests then
		return false
	end

	times[kept + 1] = now
	return true
end

return RateLimiter
