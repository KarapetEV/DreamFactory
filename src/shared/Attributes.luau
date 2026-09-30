--!strict

--[[
	Имена атрибутов инстансов, которые сервер выставляет только для отображения (визуал MVP).
	Пишет только сервер; клиент читает и рисует. Ни одна серверная проверка на эти атрибуты
	не опирается — источник истины остаётся в профиле/реестрах систем.

	Фрагмент снов (Part в Workspace.DreamFragments, CollectionSystem):
	  FragmentEmotion — Types.EmotionType, выбранный сервером при спавне;
	  FragmentBiome   — BiomeConfig.Id зоны спавна (вторичный акцент окружения).
	Игрок (Player):
	  EquippedPets     — EquippedPetsCodec.Encode надетых петов, дающих бонус (PetSystem);
	  ShieldExpiresAt  — os.time() конца PvP-щита, nil — щита нет (PvPRaidSystem);
	  RaidedCount      — сколько раз игрока ограбили за сессию на этом сервере (PvPRaidSystem).
]]

return {
	FragmentEmotion = "FragmentEmotion",
	FragmentBiome = "FragmentBiome",
	EquippedPets = "EquippedPets",
	ShieldExpiresAt = "ShieldExpiresAt",
	RaidedCount = "RaidedCount",
}
