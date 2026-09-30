--!strict

--[[
	Имена атрибутов инстансов, которые сервер выставляет только для отображения (визуал MVP).
	Пишет только сервер; клиент читает и рисует. Ни одна серверная проверка на эти атрибуты
	не опирается — источник истины остаётся в профиле/реестрах систем.

	Фрагмент снов (Part в Workspace.DreamFragments, CollectionSystem):
	  FragmentEmotion — Types.EmotionType, выбранный сервером при спавне;
	  FragmentBiome   — BiomeConfig.Id зоны спавна (вторичный акцент окружения);
	  FragmentCollectMode — Types.CollectMode, ставится прямо перед Destroy собранного фрагмента:
	                    "Touch" (RequestCollect касанием) или "Magnet" (магнит сервера);
	  FragmentCollectedBy — UserId собравшего игрока (туда летит кристалл при "Magnet").
	Игрок (Player):
	  EquippedPets     — EquippedPetsCodec.Encode надетых петов, дающих бонус (PetSystem);
	  ShieldExpiresAt  — os.time() конца PvP-щита, nil — щита нет (PvPRaidSystem);
	  RaidedCount      — сколько раз игрока ограбили за сессию на этом сервере (PvPRaidSystem).
]]

return {
	FragmentEmotion = "FragmentEmotion",
	FragmentBiome = "FragmentBiome",
	FragmentCollectMode = "FragmentCollectMode",
	FragmentCollectedBy = "FragmentCollectedBy",
	EquippedPets = "EquippedPets",
	ShieldExpiresAt = "ShieldExpiresAt",
	RaidedCount = "RaidedCount",
}
