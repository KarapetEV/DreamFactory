--!strict

export type PlayerProfile = {
	Currency: {
		Essence: number,
	},
	Factory: {
		Level: number,
		StorageCapacity: number,
		ConveyorSpeedLevel: number,
		Decor: { string },
	},
	Collection: {
		RadiusLevel: number,
		SpeedLevel: number,
		AutoCollectorOwned: boolean,
	},
	Pets: {
		{
			Id: string,
			SpeciesId: string,
			Rarity: string,
			Mutation: string?,
			Level: number,
			Equipped: boolean,
		}
	},
	Rebirth: {
		Count: number,
		ClarityMultiplier: number,
		CurrentBiome: string,
	},
	Chaos: {
		PersonalContributionToday: number,
	},
	PvP: {
		ShieldExpiresAt: number?,
		LastRaidedAt: number?,
		GuardsPlaced: { string },
	},
	Monetization: {
		GamePassesOwned: { string },
		BattlePassSeasonId: string?,
		BattlePassTier: number,
	},
	Meta: {
		FirstJoinAt: number,
		LastLoginAt: number,
		SchemaVersion: number,
	},
}

return {}
