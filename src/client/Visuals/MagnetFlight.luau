--!strict

--[[
	MagnetFlight — чистая часть анимации магнитного сбора (FragmentVisuals): решение «лететь или
	вспыхнуть на месте» и поза кристалла в полёте. Без Instance — проверяется в lune.

	- Лететь — только если сервер пометил сбор как магнитный (Attributes.FragmentCollectMode =
	  "Magnet"), известен собравший (FragmentCollectedBy — UserId) и не превышен лимит
	  одновременных полётов. Сбор касанием ("Touch") и старые/битые атрибуты — прежняя вспышка.
	- Поза: прогресс 0..1 за duration секунд; путь к игроку с разгоном (progress²) — «притяжение»;
	  подъём по дуге sin(π·progress)·arc; масштаб линейно от 1 до endScale.
]]

local MagnetFlight = {}

export type Pose = {
	Progress: number, -- 0..1 доля времени полёта
	Travel: number, -- 0..1 доля пути от точки фрагмента до персонажа
	Lift: number, -- studs над прямой «фрагмент → персонаж»
	Scale: number, -- масштаб кристалла
	Done: boolean, -- долетел: вспышка у персонажа и удаление
}

function MagnetFlight.ShouldFly(mode: unknown, collectorUserId: unknown, activeFlights: number, maxFlights: number): boolean
	return mode == "Magnet"
		and type(collectorUserId) == "number"
		and collectorUserId == collectorUserId
		and activeFlights < maxFlights
end

function MagnetFlight.Pose(elapsed: number, duration: number, arc: number, endScale: number): Pose
	local progress = elapsed / duration
	-- NaN (битое время/длительность) — считаем долетевшим, чтобы кристалл не завис в мире.
	if progress ~= progress then
		progress = 1
	end
	progress = math.clamp(progress, 0, 1)
	return {
		Progress = progress,
		Travel = progress * progress,
		Lift = math.sin(progress * math.pi) * arc,
		Scale = 1 + (endScale - 1) * progress,
		Done = progress >= 1,
	}
end

return MagnetFlight
