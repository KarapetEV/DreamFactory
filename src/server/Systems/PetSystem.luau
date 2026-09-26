--!strict

--[[
	PetSystem — вылупление петов и состав активных (раздел 5.3 ТЗ, анти-чит — раздел 7).
	Бонусы петов (агрегированный модификатор) — следующая сессия (S8).

	HatchCocoon(cocoonId):
	- клиент присылает только id кокона; цену сервер берёт из CocoonConfig, шансы — из
	  server-only PetRarityConfig (клиенту не реплицируется, подсмотреть/подделать нельзя);
	- проверки, списание Essence, ролл и запись пета — одна функция без yield: между
	  проверкой баланса и записью не может вклиниться другой запрос;
	- ролл: редкость по Chance кокона → равновероятный вид редкости → независимый ролл
	  мутации (Mutation.Chance) → тип мутации по весам. Источник случайности — серверный Random.

	EquipPet / UnequipPet(petInstanceId):
	- пет ищется только в профиле вызывающего игрока — чужой Id просто «не найден»;
	- лимит активных: PetConfig.BaseEquipSlots + ExtraEquipSlots при наличии геймпасса
	  в Monetization.GamePassesOwned (владение пишет в профиль MonetizationSystem).
	  Если слотов стало меньше, чем уже надето (например, геймпасс отозван), лишние
	  не снимаются автоматически, но новые не надеваются, пока не освободится слот.

	Ответ (Remotes.PetSnapshot): на каждый запрос, прошедший rate limit, — снимок с Ack;
	плюс полный снимок после загрузки профиля. Только собственные данные игрока. На отказ
	список петов не шлём (Pets = nil): состав не изменился, а полный инвентарь в ответ на
	мусорный запрос дал бы спамеру усиление исходящего трафика.
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.shared.Types)
local Remotes = require(ReplicatedStorage.shared.Remotes)
local UpgradeEffects = require(ReplicatedStorage.shared.UpgradeEffects)
local CocoonConfig = require(ReplicatedStorage.shared.Config.CocoonConfig)
local PetConfig = require(ReplicatedStorage.shared.Config.PetConfig)
local PetRarityConfig = require(script.Parent.Parent.Config.PetRarityConfig)
local DataSystem = require(script.Parent.DataSystem)
local RateLimiter = require(script.Parent.Parent.Services.RateLimiter)

type PlayerProfile = Types.PlayerProfile
type PetRecord = Types.PetRecord

type PlayerState = {
	RequestTimes: { number }, -- метки вызовов HatchCocoon/EquipPet/UnequipPet в окне rate limit
	Rejects: number,
	RejectWindowStart: number,
	CorruptionReported: boolean, -- предупреждение о битом профиле уже записано
}

-- Источник случайности ролла: NextNumber() в [0, 1).
export type RandomSource = { NextNumber: (self: any) -> number }

export type RollResult = {
	SpeciesId: string,
	Rarity: string,
	Mutation: string?,
}

local REJECT_LOG_WINDOW = 60
local MAX_PET_ID_LENGTH = 64

local isFinite = UpgradeEffects.IsFinite

for key, cocoon in CocoonConfig do
	assert(cocoon.Id == key, `CocoonConfig: ключ {key} не совпадает с Id {cocoon.Id}`)
	assert(isFinite(cocoon.Price) and cocoon.Price > 0, `CocoonConfig: у {key} некорректная цена`)
end
for _, field in { "BaseEquipSlots", "ExtraEquipSlots", "MaxInventory", "MaxRequestsPerWindow" } do
	local value = (PetConfig :: any)[field]
	assert(isFinite(value) and value >= 0 and value % 1 == 0, `PetConfig: некорректный {field}`)
end

local PetSystem = {}

local rng = Random.new()
local playerStates: { [Player]: PlayerState } = {}
-- Игроки, чей FireServer на односторонний PetSnapshot уже записан в лог. Ключи слабые.
local reportedForeignFires: { [Player]: true } = setmetatable({}, { __mode = "k" }) :: any

local function getPlayerState(player: Player): PlayerState
	local state = playerStates[player]
	if not state then
		state = {
			RequestTimes = {},
			Rejects = 0,
			RejectWindowStart = 0,
			CorruptionReported = false,
		}
		playerStates[player] = state
	end
	return state
end

local function registerReject(player: Player, reason: string, now: number)
	local state = getPlayerState(player)
	if now - state.RejectWindowStart > REJECT_LOG_WINDOW then
		state.RejectWindowStart = now
		state.Rejects = 0
	end

	state.Rejects += 1
	if state.Rejects == PetConfig.SuspiciousRejectThreshold then
		warn(
			`[PetSystem] Подозрительная активность: {player.Name} ({player.UserId}), `
				.. `{state.Rejects} отклонённых запросов петов за {REJECT_LOG_WINDOW} с, последняя причина: {reason}`
		)
	end
end

local function reportCorruption(player: Player, reason: string)
	local state = getPlayerState(player)
	if not state.CorruptionReported then
		state.CorruptionReported = true
		warn(`[PetSystem] Некорректные данные профиля {player.Name} ({player.UserId}): {reason}`)
	end
end

-- Случайное число строго в [0, 1): защита от источника, вернувшего 1 или мусор.
local function nextUnit(source: RandomSource): number
	local u = source:NextNumber()
	if not isFinite(u) or u < 0 or u >= 1 then
		return 0
	end
	return u
end

-- Индекс по весам: u в [0, 1) → первый i, у которого накопленный вес > u * total.
-- При ошибке округления (u * total у самого края) — последний элемент.
local function pickWeighted(weights: { number }, u: number): number
	local total = 0
	for _, w in weights do
		total += w
	end
	local target = u * total
	local cumulative = 0
	for i, w in weights do
		cumulative += w
		if target < cumulative then
			return i
		end
	end
	return #weights
end

local function pickUniform<T>(list: { T }, u: number): T
	return list[math.min(math.floor(u * #list) + 1, #list)]
end

-- Честный ролл пета для кокона: редкость → вид → независимая мутация. Без yield и без
-- обращений к профилю. Экспортируется для тестов (статистика по конфигу); source — любой
-- объект с NextNumber() (в игре — серверный Random). nil — неизвестный кокон.
function PetSystem.RollPet(cocoonId: string, source: RandomSource): RollResult?
	local odds = PetRarityConfig.Cocoons[cocoonId]
	if not odds then
		return nil
	end

	local chances = table.create(#odds)
	for i, entry in odds do
		chances[i] = entry.Chance
	end
	local rarity = odds[pickWeighted(chances, nextUnit(source))]
	local speciesId = pickUniform(rarity.Species, nextUnit(source))

	-- Мутация — отдельный бросок: результат ролла редкости в нём не участвует.
	local mutation: string? = nil
	local mutationConfig = PetRarityConfig.Mutation
	if nextUnit(source) < mutationConfig.Chance then
		local weights = table.create(#mutationConfig.Types)
		for i, mutationType in mutationConfig.Types do
			weights[i] = mutationType.Weight
		end
		mutation = mutationConfig.Types[pickWeighted(weights, nextUnit(source))].Id
	end

	return {
		SpeciesId = speciesId,
		Rarity = rarity.Rarity,
		Mutation = mutation,
	}
end

local function ownsGamePass(data: PlayerProfile, gamePassId: string): boolean
	local owned = data.Monetization.GamePassesOwned
	if type(owned) ~= "table" then
		return false
	end
	for _, id in owned do
		if id == gamePassId then
			return true
		end
	end
	return false
end

-- Сколько петов игрок может держать активными (сервер решает по профилю).
function PetSystem.GetEquipSlots(data: PlayerProfile): number
	local slots = PetConfig.BaseEquipSlots
	if ownsGamePass(data, PetConfig.ExtraSlotsGamePassId) then
		slots += PetConfig.ExtraEquipSlots
	end
	return slots
end

-- Список петов профиля; nil — раздел Pets испорчен: не таблица или не плотный массив
-- (у словаря/массива с дырами # занижен, и MaxInventory не сработал бы).
local function getPets(player: Player, data: PlayerProfile): { PetRecord }?
	local pets = data.Pets
	if type(pets) ~= "table" then
		reportCorruption(player, `Pets = {pets}`)
		return nil
	end
	local count = 0
	for _ in pets do
		count += 1
	end
	if count ~= #pets then
		reportCorruption(player, `Pets не массив: {count} записей при длине {#pets}`)
		return nil
	end
	return pets
end

local function findPet(pets: { PetRecord }, petId: string): PetRecord?
	for _, pet in pets do
		if type(pet) == "table" and pet.Id == petId then
			return pet
		end
	end
	return nil
end

local function countEquipped(pets: { PetRecord }): number
	local count = 0
	for _, pet in pets do
		if type(pet) == "table" and pet.Equipped == true then
			count += 1
		end
	end
	return count
end

-- Уникальный Id экземпляра. Коллизия GUID практически невозможна, но проверка дешёвая.
local function newPetId(pets: { PetRecord }): string?
	for _ = 1, 3 do
		local id = HttpService:GenerateGUID(false)
		if not findPet(pets, id) then
			return id
		end
	end
	return nil
end

-- Единая транзакция вылупления: проверки, списание, ролл и запись — без yield.
-- Возвращает (причина отказа, nil) или (nil, Id нового пета).
local function tryHatch(player: Player, cocoonId: unknown): (string?, string?)
	if type(cocoonId) ~= "string" then
		return "bad-argument", nil
	end
	local cocoon = CocoonConfig[cocoonId]
	if not cocoon then
		return "unknown-cocoon", nil
	end

	local data = DataSystem.GetData(player)
	if not data then
		return "no-profile", nil
	end
	local pets = getPets(player, data)
	if not pets then
		return "corrupt-pets", nil
	end
	if #pets >= PetConfig.MaxInventory then
		return "inventory-full", nil
	end

	local essence = data.Currency.Essence
	if not isFinite(essence) or essence < 0 then
		reportCorruption(player, `Essence = {essence}`)
		return "corrupt-essence", nil
	end
	if essence < cocoon.Price then
		return "insufficient-essence", nil
	end
	local newEssence = essence - cocoon.Price
	if not isFinite(newEssence) then
		return "non-finite-result", nil
	end

	local roll = PetSystem.RollPet(cocoonId, rng)
	local petId = newPetId(pets)
	if not roll or not petId then
		return "roll-failed", nil
	end

	data.Currency.Essence = newEssence
	table.insert(pets, {
		Id = petId,
		SpeciesId = roll.SpeciesId,
		Rarity = roll.Rarity,
		Mutation = roll.Mutation,
		Level = 1,
		Equipped = false,
	})
	return nil, petId
end

local function validPetId(petId: unknown): boolean
	return type(petId) == "string" and #petId > 0 and #petId <= MAX_PET_ID_LENGTH
end

local function tryEquip(player: Player, petId: unknown): string?
	if not validPetId(petId) then
		return "bad-argument"
	end
	local data = DataSystem.GetData(player)
	if not data then
		return "no-profile"
	end
	local pets = getPets(player, data)
	if not pets then
		return "corrupt-pets"
	end

	-- Поиск только в профиле вызывающего: Id чужого пета здесь не найдётся.
	local pet = findPet(pets, petId :: string)
	if not pet then
		return "not-owned"
	end
	if pet.Equipped == true then
		return "already-equipped" -- повтор запроса, состояние не меняем
	end
	if countEquipped(pets) >= PetSystem.GetEquipSlots(data) then
		return "slots-full"
	end

	pet.Equipped = true
	return nil
end

local function tryUnequip(player: Player, petId: unknown): string?
	if not validPetId(petId) then
		return "bad-argument"
	end
	local data = DataSystem.GetData(player)
	if not data then
		return "no-profile"
	end
	local pets = getPets(player, data)
	if not pets then
		return "corrupt-pets"
	end

	local pet = findPet(pets, petId :: string)
	if not pet then
		return "not-owned"
	end
	if pet.Equipped ~= true then
		return "not-equipped"
	end

	pet.Equipped = false
	return nil
end

-- Снимок только из полей известного вида: битые записи пропускаются, лишние поля не утекают.
local function buildSnapshot(
	data: PlayerProfile,
	withPets: boolean,
	ack: string?,
	hatchedPetId: string?
): Types.PetSnapshot
	local pets: { PetRecord }? = nil
	if withPets then
		pets = {}
	end
	if pets and type(data.Pets) == "table" then
		for _, pet in data.Pets do
			if type(pet) == "table" and type(pet.Id) == "string" then
				table.insert(pets, {
					Id = pet.Id,
					SpeciesId = pet.SpeciesId,
					Rarity = pet.Rarity,
					Mutation = pet.Mutation,
					Level = pet.Level,
					Equipped = pet.Equipped == true,
				})
			end
		end
	end
	return {
		Pets = pets,
		EquipSlots = PetSystem.GetEquipSlots(data),
		Ack = ack,
		HatchedPetId = hatchedPetId,
	}
end

-- Отправка снимка владельцу. Ошибка сборки (битый профиль) не должна ронять обработчик
-- после уже выполненной транзакции — изолируем и пишем в лог один раз.
local function sendSnapshot(player: Player, withPets: boolean, ack: string?, hatchedPetId: string?)
	local ok, err = pcall(function()
		local data = DataSystem.GetData(player)
		if data then
			Remotes.PetSnapshot:FireClient(player, buildSnapshot(data, withPets, ack, hatchedPetId))
		end
	end)
	if not ok then
		reportCorruption(player, `ошибка сборки снимка петов: {err}`)
	end
end

-- Общая обвязка ремоут: вышедший игрок, rate limit, лог отказов, ответ-снимок.
local function makeHandler(ack: string, run: (player: Player, arg: unknown) -> (string?, string?))
	return function(player: Player, arg: unknown)
		if player.Parent == nil then
			return
		end

		local now = os.clock()
		local state = getPlayerState(player)
		if not RateLimiter.Allow(state.RequestTimes, now, PetConfig.RequestWindow, PetConfig.MaxRequestsPerWindow) then
			-- Без ответа: не даём спамеру усиление исходящего трафика.
			registerReject(player, "rate-limit", now)
			return
		end

		-- Транзакция не мутирует профиль до последней проверки, поэтому ошибка на битом
		-- разделе (например, Currency не таблица — reconcile() типы не чинит) ничего не
		-- портит; ловим её, чтобы клиент всё равно получил ответ, а лог — одну запись.
		local ok, reason, hatchedPetId = pcall(run, player, arg)
		if not ok then
			reportCorruption(player, `ошибка обработки {ack}: {reason}`)
			reason, hatchedPetId = "error", nil
		end
		if reason then
			registerReject(player, reason, now)
		end
		sendSnapshot(player, reason == nil, ack, hatchedPetId)
	end
end

local onHatchCocoon = makeHandler("HatchCocoon", tryHatch)
local onEquipPet = makeHandler("EquipPet", function(player, arg)
	return tryEquip(player, arg), nil
end)
local onUnequipPet = makeHandler("UnequipPet", function(player, arg)
	return tryUnequip(player, arg), nil
end)

local function sendInitialSnapshot(player: Player)
	task.spawn(function()
		local data = DataSystem.WaitForData(player)
		if data and player.Parent ~= nil then
			sendSnapshot(player, true, nil, nil)
		end
	end)
end

function PetSystem.Init()
	Remotes.HatchCocoon.OnServerEvent:Connect(onHatchCocoon)
	Remotes.EquipPet.OnServerEvent:Connect(onEquipPet)
	Remotes.UnequipPet.OnServerEvent:Connect(onUnequipPet)

	-- PetSnapshot — только сервер → клиент; FireServer означает модифицированный клиент.
	Remotes.PetSnapshot.OnServerEvent:Connect(function(player: Player)
		if reportedForeignFires[player] then
			return
		end
		reportedForeignFires[player] = true
		warn(`[PetSystem] Клиент вызвал серверный вход PetSnapshot: {player.Name} ({player.UserId})`)
	end)

	Players.PlayerAdded:Connect(sendInitialSnapshot)
	for _, player in Players:GetPlayers() do
		sendInitialSnapshot(player)
	end

	Players.PlayerRemoving:Connect(function(player)
		playerStates[player] = nil
		reportedForeignFires[player] = nil
	end)
end

return PetSystem
