--!strict
-- Config.luau — every tuning number in DEAD ZONE lives here.
-- Nothing in the other modules hardcodes a balance value.

local Config = {}

-- ---------------------------------------------------------------- squad
Config.MaxPlayers = 4
Config.MinPlayersToStart = 1          -- MVP: solo is allowed so it's testable
Config.LobbyCountdown = 10

-- ---------------------------------------------------------------- health
Config.MaxHealth = 100
Config.BandageHeal = 30               -- stops bleed-out only, no temp HP
Config.MedkitHeal = 100
Config.PillTempHealth = 50
Config.AdrenalineDuration = 10
Config.TempHealthDecayPerSecond = 2

Config.DownBleedOut = 30              -- seconds before a downed player dies
Config.ReviveChannelTime = 3
Config.ReviveHealth = 10
Config.ReviveInvulnerability = 2

-- ---------------------------------------------------------------- weapons
Config.Primary = {
	Damage = 34,
	HeadshotMultiplier = 2.0,
	FireInterval = 0.13,
	Magazine = 30,
	ReserveMax = 180,
	ReloadTime = 2.1,
	Range = 400,
	SpreadRadians = 0.012,
}
Config.Secondary = {
	Damage = 20,
	HeadshotMultiplier = 1.5,
	FireInterval = 0.28,
	Magazine = 12,
	ReserveMax = 9999,                 -- effectively infinite
	ReloadTime = 1.4,
	Range = 200,
	SpreadRadians = 0.02,
}
Config.Melee = {
	Damage = 55,
	Range = 12,
	ArcRadians = math.pi / 2.2,
	Cooldown = 1.0,
	-- Shove is what gets you out of a swarm: knocks back, stuns briefly.
	ShoveRange = 14,
	ShoveForce = 55,
	ShoveStun = 0.9,
	ShoveCooldown = 2.5,
}

-- ---------------------------------------------------------------- economy
Config.Money = {
	CommonKill = 15,
	SpecialKill = 75,
	TankKill = 400,
	ZoneClear = 250,
	ReviveBonus = 50,
}

-- ---------------------------------------------------------------- AI Director
Config.Director = {
	-- Stress is 0..100 per player.
	StressPerDamage = 0.9,
	StressPerTargetingZombie = 1.4,
	StressPerNoiseEvent = 8,
	StressDecayPerSecond = 3.5,
	StressMax = 100,

	-- Budget is what the Director can spend this tick.
	BudgetPerStress = 0.09,
	BudgetMax = 220,
	BudgetRefreshPerSecond = 1,

	-- Common infected
	CommonCost = 6,
	CommonAliveCapBase = 24,
	CommonAliveCapPerZone = 6,
	CommonSpawnBatchMin = 4,
	CommonSpawnBatchMax = 9,

	-- Special infected
	SpecialAliveCap = 3,
	SpecialIntervalBase = 22,          -- seconds between specials at rest
	SpecialIntervalMin = 9,
	SpecialIntervalStressScale = 14,   -- interval shrinks with stress

	-- Hordes
	HordeCooldownMin = 26,
	HordeCooldownMax = 55,
	HordeCooldownStressScale = 20,     -- stress shortens the gap
	HordeSizeMin = 12,
	HordeSizeMax = 30,
	HordeSizePerZone = 5,

	-- Phase lengths (seconds)
	BuildPhase = 24,
	SustainPhase = 45,
	RelaxPhase = 14,

	-- Spawn distance: never in view, never on top of them.
	SpawnMinDistance = 90,
	SpawnMaxDistance = 180,
}

-- ---------------------------------------------------------------- zombies
Config.Common = {
	Health = 55,
	WalkSpeed = 10,
	RunSpeed = 18,
	Damage = 12,
	AttackRange = 3.2,
	AttackInterval = 0.9,
	HearingRadius = 60,
	SightRange = 80,
	-- Target memory: keep chasing for this long after losing line of sight.
	LoseTargetAfter = 6,
}

Config.Specials = {
	Hunter = {
		Health = 250,
		WalkSpeed = 16,
		Damage = 20,
		PounceRange = 45,
		PounceSpeed = 70,
		PounceDamage = 25,
		PounceCooldown = 6,
		PinDuration = 4,
	},
	Smoker = {
		Health = 150,
		WalkSpeed = 9,
		TongueRange = 70,
		TonguePullSpeed = 18,
		TongueDamage = 8,
		TongueDuration = 6,
	},
	Boomer = {
		Health = 50,
		WalkSpeed = 6,
		BileRadius = 30,
		BileHordeSize = 18,
		ExplodeDamage = 5,
	},
	Charger = {
		Health = 600,
		WalkSpeed = 14,
		WindupTime = 1.6,
		ChargeSpeed = 55,
		ChargeDuration = 2.4,
		ChargeDamage = 30,
		ChargeCooldown = 8,
	},
	Tank = {
		Health = 6000,
		WalkSpeed = 16,
		SlamDamage = 40,
		SlamRadius = 16,
		SlamCooldown = 3.5,
		DebrisDamage = 25,
		DebrisRange = 60,
		DebrisCooldown = 6,
	},
}

-- ---------------------------------------------------------------- pickups
Config.Pickups = {
	Medkit = { Respawn = 90 },
	Bandage = { Respawn = 30 },
	Pills = { Respawn = 45 },
	Adrenaline = { Respawn = 60 },
	AmmoPile = { Respawn = 60, ReserveGiven = 90 },
}

-- ---------------------------------------------------------------- zones
Config.Zones = {
	{
		Id = "suburbs",
		Name = "Maple Street",
		Danger = 1,
		CommonCapBonus = 0,
		FavouredSpecial = "Hunter",
	},
	{
		Id = "hospital",
		Name = "St. Mercy Hospital",
		Danger = 2,
		CommonCapBonus = 4,
		FavouredSpecial = "Boomer",
	},
	{
		Id = "mall",
		Name = "Northgate Mall",
		Danger = 3,
		CommonCapBonus = 8,
		FavouredSpecial = "Charger",
	},
	{
		Id = "base",
		Name = "Fort Carlyle",
		Danger = 4,
		CommonCapBonus = 12,
		FavouredSpecial = "Tank",
		Boss = "Tank",
	},
}

return Config
