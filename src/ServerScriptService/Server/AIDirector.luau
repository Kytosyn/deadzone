--!strict
-- AIDirector.luau — the L4D2 Director: spawn pressure driven by player
-- stress, not by a clock.
--
-- Public API:
--   Director.new(zoneManager)            -> Director
--   director:Start()                     begin managing the current zone
--   director:Stop()
--   director:ReportDamage(player, amount)
--   director:ReportNoise(player, position, loudness)
--   director:OnZombieKilled(zombie)
--   director:GetStress(player)           0..100
--   director:GetPhase()                  "build"|"sustain"|"relax"|"crescendo"
--
-- The Director is a state machine with four phases per zone. It spends a
-- refreshable budget on common infected, keeps a separate cadence for specials,
-- and fires hordes on a stress-shortened cooldown.

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)

export type Zombie = any -- set by ZombieAI; kept loose to avoid a cycle

local Director = {}
Director.__index = Director

local phaseOrder = { "build", "sustain", "relax", "crescendo" }

function Director.new(spawnProvider: any, zoneManager: any)
	local self = setmetatable({}, Director)

	self._spawnProvider = spawnProvider
	self._zoneManager = zoneManager

	self._running = false
	self._phaseIndex = 1
	self._phaseTime = 0
	self._budget = 0
	self._specialTimer = Config.Director.SpecialIntervalBase
	self._hordeTimer = 30
	self._commonAlive = 0
	self._specialAlive = 0
	self._stress = {}          -- [Player] = number
	self._targeting = {}       -- [Player] = count of zombies hunting them
	self._noise = {}           -- [Player] = decaying noise level

	self._zoneDanger = 1
	self._zoneCommonCap = Config.Director.CommonAliveCapBase

	return self
end

-- ---------------------------------------------------------------- tracking

function Director:RegisterPlayer(player: Player)
	self._stress[player] = 0
	self._targeting[player] = 0
	self._noise[player] = 0
end

function Director:UnregisterPlayer(player: Player)
	self._stress[player] = nil
	self._targeting[player] = nil
	self._noise[player] = nil
end

function Director:ReportDamage(player: Player, amount: number)
	local s = self._stress[player]
	if not s then
		return
	end
	self._stress[player] = math.min(Config.Director.StressMax,
		s + amount * Config.Director.StressPerDamage)
end

function Director:ReportNoise(player: Player, position: Vector3, loudness: number)
	local n = self._noise[player] or 0
	self._noise[player] = math.min(Config.Director.StressMax, n + loudness)
	self._stress[player] = math.min(Config.Director.StressMax,
		(self._stress[player] or 0) + Config.Director.StressPerNoiseEvent * loudness * 0.1)
	-- Noise also attracts the horde: hand the position to the spawn provider.
	self._spawnProvider:Alert(position, loudness)
end

function Director:SetTargeting(player: Player, delta: number)
	local t = self._targeting[player]
	if not t then
		return
	end
	self._targeting[player] = math.max(0, t + delta)
end

function Director:GetStress(player: Player): number
	return self._stress[player] or 0
end

function Director:GetPhase(): string
	return phaseOrder[self._phaseIndex] or "build"
end

function Director:AlertHorde()
	-- Crescendo event: jump straight to the horde phase.
	self._phaseIndex = 4
	self._phaseTime = 0
end

function Director:SetZone(danger: number, commonCapBonus: number)
	self._zoneDanger = danger
	self._zoneCommonCap = Config.Director.CommonAliveCapBase + commonCapBonus
	-- Entering a new zone always starts calm.
	self._phaseIndex = 1
	self._phaseTime = 0
end

function Director:OnZombieKilled()
	self._commonAlive = math.max(0, self._commonAlive - 1)
end

function Director:OnSpecialKilled()
	self._specialAlive = Math.max(0, self._specialAlive - 1)
end

-- ---------------------------------------------------------------- phases

local phaseLengths = {
	build = Config.Director.BuildPhase,
	sustain = Config.Director.SustainPhase,
	relax = Config.Director.RelaxPhase,
	crescendo = 12, -- a horde is bounded, not endless
}

function Director:_advancePhase()
	self._phaseIndex = self._phaseIndex % #phaseOrder + 1
	self._phaseTime = 0
	if self:GetPhase() == "relax" then
		-- Wipe the horde state so the breather is real.
		self._hordeTimer = self:_rollHordeCooldown()
	end
end

function Director:_rollHordeCooldown(): number
	local stress = self:_squadStress()
	local base = math.random(Config.Director.HordeCooldownMin, Config.Director.HordeCooldownMax)
	return math.max(12, base - stress * Config.Director.HordeCooldownStressScale * 0.1)
end

function Director:_squadStress(): number
	local total, count = 0, 0
	for _, s in pairs(self._stress) do
		total += s
		count += 1
	end
	if count == 0 then
		return 0
	end
	return total / count
end

-- ---------------------------------------------------------------- main loop

function Director:Start()
	if self._running then
		return
	end
	self._running = true
	self._phaseIndex = 1
	self._phaseTime = 0
	self._budget = Config.Director.BudgetMax * 0.5

	task.spawn(function()
		while self._running do
			local dt = task.wait(0.25)
			self:_tick(dt)
		end
	end)
end

function Director:Stop()
	self._running = false
end

function Director:_tick(dt: number)
	self._phaseTime += dt

	local phase = self:GetPhase()
	local length = phaseLengths[phase] or 30

	-- 1. decay stress and noise
	for player, s in pairs(self._stress) do
		local target = self._targeting[player] or 0
		local fromTargets = target * Config.Director.StressPerTargetingZombie
		local decayed = s - Config.Director.StressDecayPerSecond * dt
		-- Targeting pressure decays much more slowly than damage pressure.
		self._stress[player] = math.max(fromTargets, math.min(Config.Director.StressMax, decayed))
	end
	for player, n in pairs(self._noise) do
		self._noise[player] = math.max(0, n - 20 * dt)
	end

	-- 2. refresh budget
	local stress = self:_squadStress()
	self._budget = math.min(
		Config.Director.BudgetMax,
		self._budget + Config.Director.BudgetPerStress * stress * Config.Director.BudgetRefreshPerSecond * dt
	)

	-- 3. phase machine
	if phase == "relax" then
		-- Breather: no spawns at all. This is what makes hordes land.
		if self._phaseTime >= length then
			self:_advancePhase()
		end
		return
	end

	if phase == "crescendo" then
		-- Pour everything in for the duration of the event.
		self:_spawnCommons(dt, true)
		if self._phaseTime >= length then
			self:_advancePhase()
		end
		return
	end

	-- build / sustain
	if self._phaseTime >= length then
		self:_advancePhase()
	end

	self:_spawnCommons(dt, false)
	self:_spawnSpecials(dt)
	self:_maybeHorde(dt, stress)
end

function Director:_spawnCommons(dt: number, force: boolean)
	if not force and self:GetPhase() == "relax" then
		return
	end

	local cap = self._zoneCommonCap
	if force then
		cap += Config.Director.HordeSizeMax
	end
	if self._commonAlive >= cap then
		return
	end

	-- Batch size scales with how far under the cap we are.
	local headroom = cap - self._commonAlive
	local batchMax = math.min(
		Config.Director.CommonSpawnBatchMax,
		math.max(Config.Director.CommonSpawnBatchMin, math.floor(headroom * 0.6))
	)
	local batch = math.random(Config.Director.CommonSpawnBatchMin, batchMax)

	local spawned = 0
	for _ = 1, batch do
		if self._budget < Config.Director.CommonCost then
			break
		end
		if self._commonAlive >= cap then
			break
		end
		local ok = self._spawnProvider:SpawnCommon()
		if ok then
			self._budget -= Config.Director.CommonCost
			self._commonAlive += 1
			spawned += 1
		end
	end

	if spawned > 0 then
		self._spawnProvider:BroadcastSpawnAlert(spawned)
	end
end

function Director:_spawnSpecials(dt: number)
	if self._specialAlive >= Config.Director.SpecialAliveCap then
		return
	end

	self._specialTimer -= dt
	if self._specialTimer > 0 then
		return
	end

	local zone = Config.Zones[self._zoneManager:GetCurrentZoneIndex()] or Config.Zones[1]
	local ok = self._spawnProvider:SpawnSpecial(zone.FavouredSpecial)
	if ok then
		self._specialAlive += 1
	end

	local stress = self:_squadStress()
	local interval = math.max(
		Config.Director.SpecialIntervalMin,
		Config.Director.SpecialIntervalBase - stress * Config.Director.SpecialIntervalStressScale * 0.1
	)
	self._specialTimer = interval
end

function Director:_maybeHorde(dt: number, stress: number)
	self._hordeTimer -= dt
	if self._hordeTimer > 0 then
		return
	end

	-- Fire the horde.
	self:AlertHorde()
	self._hordeTimer = self:_rollHordeCooldown()
end

return Director
