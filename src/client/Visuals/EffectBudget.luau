--!strict

--[[
	EffectBudget — лимит разовых эффектов (вспышек частиц) при плотном сборе: не больше
	maxConcurrent одновременно (каждый держит слот lifetime секунд) и не больше maxPerSecond
	запусков за скользящую секунду. Лишний запрос отбрасывается — эффект просто не играет,
	FPS не проседает. Чистая логика без Roblox API: время передаёт вызывающий (lune-тесты).
]]

export type EffectBudget = {
	TryAcquire: (self: EffectBudget, now: number) -> number?,
	ActiveCount: (self: EffectBudget, now: number) -> number,
}

local EffectBudget = {}
EffectBudget.__index = EffectBudget

function EffectBudget.new(maxConcurrent: number, maxPerSecond: number, lifetime: number): EffectBudget
	assert(maxConcurrent >= 1 and maxConcurrent % 1 == 0, "EffectBudget: maxConcurrent — целое ≥ 1")
	assert(maxPerSecond > 0 and lifetime > 0, "EffectBudget: maxPerSecond и lifetime > 0")
	local slots = table.create(maxConcurrent, -math.huge)
	return (setmetatable({
		_slots = slots, -- слот → момент освобождения
		_starts = {} :: { number }, -- моменты запусков за последнюю секунду
		_maxPerSecond = maxPerSecond,
		_lifetime = lifetime,
		_next = 1,
	}, EffectBudget) :: any) :: EffectBudget
end

-- Номер свободного слота (1..maxConcurrent) или nil, если бюджет исчерпан.
function EffectBudget.TryAcquire(self: any, now: number): number?
	local starts: { number } = self._starts
	while #starts > 0 and now - starts[1] >= 1 do
		table.remove(starts, 1)
	end
	if #starts >= self._maxPerSecond then
		return nil
	end

	local slots: { number } = self._slots
	-- Круговой обход с последнего выданного: соседние вспышки не делят один эмиттер.
	for step = 0, #slots - 1 do
		local index = (self._next - 1 + step) % #slots + 1
		if slots[index] <= now then
			slots[index] = now + self._lifetime
			self._next = index % #slots + 1
			table.insert(starts, now)
			return index
		end
	end
	return nil
end

function EffectBudget.ActiveCount(self: any, now: number): number
	local count = 0
	for _, freeAt in self._slots :: { number } do
		if freeAt > now then
			count += 1
		end
	end
	return count
end

return EffectBudget
