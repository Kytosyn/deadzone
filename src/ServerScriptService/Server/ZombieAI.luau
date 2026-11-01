--!strict
-- ZombieAI.luau — common infected hordes and the five special infected.
--
-- This module is the "spawn provider" the Director talks to. It owns every
-- zombie instance, drives their behaviour, and reports back so the Director
-- can react (targeting pressure, kills, mob counts).
--
-- Public API:
--   ZombieAI.new(director, playerManager) -> ZombieAI
--   ai:SpawnCommon(cframe?) -> boolean
--   ai:SpawnSpecial(kind, cframe?) -> boolean
--   ai:Alert(position, loudness)
--   ai:BroadcastSpawnAlert(count)
--   ai:GetCommonAlive() / GetSpecialAlive()
--   ai:Clear()

local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local Config = require(ReplicatedStorage.Shared.Config)

export type Director = any
export type PlayerManager = any

type Zombie = {
	model: Model,
	kind: string,
	target: Player?,
	path: any,
	nextRepath: number,
	nextAttack: number,
	state: string,
	stateTime: number,
	pinned: Player?,
	cooldown: number,
	investigateAt: Vector3?,
	lastSeen: number?,
	chargeDir: Vector3?,
}

local ZombieAI = {}
ZombieAI.__index = ZombieAI

-- ---------------------------------------------------------------- helpers

local function nearestPlayer(position: Vector3): Player?
	local best, bestDist = nil, math.huge
	for _, p in ipairs(Players:GetPlayers()) do
		local char = p.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if char and root then
			local d = (root.Position - position).Magnitude
			if d < bestDist then
				best, bestDist = p, d
			end
		end
	end
	return best
end

local function livingPlayers(): { Player }
	local out = {}
	for _, p in ipairs(Players:GetPlayers()) do
		local char = p.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if char and hum and hum.Health > 0 then
			table.insert(out, p)
		end
	end
	return out
end

-- ---------------------------------------------------------------- constructor

function ZombieAI.new(director: Director, playerManager: PlayerManager)
	local self = setmetatable({}, ZombieAI)
	self._director = director
	self._playerManager = playerManager
	self._zombies = {}
	self._nextId = 1
	self._alerts = {}      -- recent noise positions
	self._navAgent = PathfindingService
	return self
end

-- ---------------------------------------------------------------- spawning

function ZombieAI:_spawnPoint(minDist: number, maxDist: number): CFrame
	local players = livingPlayers()
	local anchor = players[1]
	local char = anchor and anchor.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local origin = root and root.Position or Vector3.new()

	local ray = RaycastParams.new()
	ray.FilterType = Enum.RaycastFilterType.Exclude
	-- Walk outward until we find a spot that is far enough away and on the ground.
	for _ = 1, 24 do
		local angle = math.random() * math.pi * 2
		local dist = math.random(minDist, maxDist)
		local candidate = origin + Vector3.new(math.cos(angle) * dist, 0, math.sin(angle) * dist)
		ray.FilterDescendantsInstances = { workspace }
		local hit = workspace:Raycast(candidate + Vector3.new(0, 200, 0), Vector3.new(0, -400, 0), ray)
		if hit then
			return CFrame.new(hit.Position + Vector3.new(0, 3, 0))
		end
	end
	return CFrame.new(origin + Vector3.new(minDist, 0, 0))
end

function ZombieAI:_makeHumanoid(name: string, health: number, speed: number): Model
	local model = Instance.new("Model")
	model.Name = name

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.Anchored = false
	root.CanCollide = true
	root.Transparency = 1
	root.Parent = model

	local hum = Instance.new("Humanoid")
	hum.MaxHealth = health
	hum.Health = health
	hum.WalkSpeed = speed
	hum.Parent = model

	model.PrimaryPart = root
	return model
end

function ZombieAI:SpawnCommon(cframe: CFrame?): boolean
	local cf = cframe or self:_spawnPoint(Config.Director.SpawnMinDistance, Config.Director.SpawnMaxDistance)
	local model = self:_makeHumanoid("Common", Config.Common.Health, Config.Common.WalkSpeed)
	model.Parent = workspace

	-- A plain capsule body so it reads as a silhouette without art assets.
	local body = Instance.new("Part")
	body.Name = "Torso"
	body.Size = Vector3.new(1.6, 2.2, 0.9)
	body.Color = Color3.fromRGB(88, 104, 82)
	body.Material = Enum.Material.Slate
	body.Parent = model
	body.CFrame = cf

	model:PivotTo(cf)
	model.PrimaryPart.CFrame = cf

	local z: Zombie = {
		model = model,
		kind = "Common",
		target = nil,
		path = nil,
		nextRepath = 0,
		nextAttack = 0,
		state = "seek",
		stateTime = 0,
		pinned = nil,
		cooldown = 0,
	}
	model:SetAttribute("ZombieKind", "Common")
	self._zombies[self._nextId] = z
	self._nextId += 1

	self:_hookZombie(z)
	return true
end

function ZombieAI:SpawnSpecial(kind: string, cframe: CFrame?): boolean
	local cfg = Config.Specials[kind]
	if not cfg then
		return false
	end

	local cf = cframe or self:_spawnPoint(Config.Director.SpawnMinDistance, Config.Director.SpawnMaxDistance)
	local model = self:_makeHumanoid(kind, cfg.Health, cfg.WalkSpeed)
	model.Parent = workspace

	local body = Instance.new("Part")
	body.Name = "Torso"
	body.Size = Vector3.new(1.8, 2.4, 1.0)
	body.Color = Color3.fromRGB(196, 60, 84)
	body.Material = Enum.Material.Neon
	body.Parent = model
	model:PivotTo(cf)

	local z: Zombie = {
		model = model,
		kind = kind,
		target = nil,
		path = nil,
		nextRepath = 0,
		nextAttack = 0,
		state = "seek",
		stateTime = 0,
		pinned = nil,
		cooldown = 0,
	}
	model:SetAttribute("ZombieKind", kind)
	model:SetAttribute("IsSpecial", true)
	self._zombies[self._nextId] = z
	self._nextId += 1

	self:_hookZombie(z)
	return true
end

-- ---------------------------------------------------------------- lifecycle

function ZombieAI:_hookZombie(z: Zombie)
	local hum = z.model:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.Died:Connect(function()
			self:_onZombieDied(z)
		end)
	end
end

function ZombieAI:_onZombieDied(z: Zombie)
	-- Release anyone this zombie was pinning.
	if z.pinned then
		self._playerManager:ReleasePin(z.pinned)
		z.pinned = nil
	end

	if z.kind == "Common" then
		self._director:OnZombieKilled()
	else
		self._director:OnSpecialKilled()
	end

	-- Bile: a dead Boomer still triggers its effect.
	if z.kind == "Boomer" then
		self:AlertHordeAt(z.model.PrimaryPart.Position, Config.Specials.Boomer.BileHordeSize)
	end

	-- Remove from the live set.
	for id, entry in pairs(self._zombies) do
		if entry == z then
			self._zombies[id] = nil
			break
		end
	end
	Debris:AddItem(z.model, 6)
end

function ZombieAI:Alert(position: Vector3, loudness: number)
	-- Gunfire and explosions pull nearby commons toward the source.
	for _, z in pairs(self._zombies) do
		if z.kind ~= "Common" then
			continue
		end
		local root = z.model.PrimaryPart
		if root and (root.Position - position).Magnitude <= Config.Common.HearingRadius * 2 then
			z.target = nil
			z.state = "investigate"
			z.stateTime = 0
			z.path = nil
			z.nextRepath = 0
			z.investigateAt = position
		end
	end
end

function ZombieAI:BroadcastSpawnAlert(count: number)
	-- Nothing for now: hook for audio/UI cues.
end

function ZombieAI:AlertHordeAt(position: Vector3, size: number)
	for _ = 1, size do
		local angle = math.random() * math.pi * 2
		local dist = math.random(10, 30)
		local cf = CFrame.new(position + Vector3.new(math.cos(angle) * dist, 4, math.sin(angle) * dist))
		if self:SpawnCommon(cf) then
			-- Boomer bile hordes converge on the bile victim.
			local z = self._zombies[self._nextId - 1]
			if z then
				z.state = "investigate"
				z.investigateAt = position
			end
		end
	end
end

function ZombieAI:GetCommonAlive(): number
	local n = 0
	for _, z in pairs(self._zombies) do
		if z.kind == "Common" then
			n += 1
		end
	end
	return n
end

function ZombieAI:GetSpecialAlive(): number
	local n = 0
	for _, z in pairs(self._zombies) do
		if z.kind ~= "Common" then
			n += 1
		end
	end
	return n
end

function ZombieAI:Clear()
	for _, z in pairs(self._zombies) do
		if z.model then
			z.model:Destroy()
		end
	end
	table.clear(self._zombies)
end

-- ---------------------------------------------------------------- behaviour

function ZombieAI:_repath(z: Zombie, goal: Vector3)
	local hum = z.model:FindFirstChildOfClass("Humanoid")
	local root = z.model.PrimaryPart
	if not hum or not root then
		return
	end

	local ok, path = pcall(function()
		return self._navAgent:CreatePath({
			AgentRadius = 2,
			AgentHeight = 5,
			AgentCanJump = false,
			Costs = { Water = math.huge },
		})
	end)
	if not ok or not path then
		return
	end

	path:ComputeAsync(root.Position, goal)
	if path.Status == Enum.PathStatus.Success then
		z.path = path
	end
end

function ZombieAI:_followPath(z: Zombie)
	local hum = z.model:FindFirstChildOfClass("Humanoid")
	if not hum or not z.path then
		return
	end
	local waypoints = z.path:GetWaypoints()
	if #waypoints == 0 then
		return
	end
	local next = waypoints[1]
	if next and next.Position then
		hum:MoveTo(next.Position)
	end
end

function ZombieAI:_attack(z: Zombie, target: Player)
	local hum = z.model:FindFirstChildOfClass("Humanoid")
	local root = z.model.PrimaryPart
	local char = target.Character
	local theirRoot = char and char:FindFirstChild("HumanoidRootPart")
	if not hum or not root or not char or not theirRoot then
		return
	end

	local cfg = Config.Common
	if (root.Position - theirRoot.Position).Magnitude > cfg.AttackRange then
		return
	end

	if tick() - z.nextAttack < cfg.AttackInterval then
		return
	end
	z.nextAttack = tick()

	local theirHum = char:FindFirstChildOfClass("Humanoid")
	if theirHum then
		theirHum:TakeDamage(cfg.Damage)
		self._director:ReportDamage(target, cfg.Damage)
	end
end

function ZombieAI:_updateCommon(z: Zombie, dt: number)
	local root = z.model.PrimaryPart
	if not root then
		return
	end

	z.nextRepath -= dt

	-- Pick a target: the closest living player, or the last noise.
	if z.state == "investigate" then
		local at = z.investigateAt
		if at and (root.Position - at).Magnitude > 6 then
			if z.nextRepath <= 0 then
				self:_repath(z, at)
				z.nextRepath = 1.5
			end
			self:_followPath(z)
			return
		end
		z.state = "seek"
		z.target = nil
	end

	local target = z.target
	local char = target and target.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not target or not char or not hum or hum.Health <= 0 then
		target = nearestPlayer(root.Position)
		z.target = target
		z.path = nil
		if target then
			self._director:SetTargeting(target, 1)
		end
	end

	if not target then
		return
	end

	local theirRoot = target.Character and target.Character:FindFirstChild("HumanoidRootPart")
	if not theirRoot then
		return
	end

	local dist = (root.Position - theirRoot.Position).Magnitude
	if dist > Config.Common.SightRange then
		-- Lost them: keep chasing for a while, then give up.
		if tick() - (z.lastSeen or 0) > Config.Common.LoseTargetAfter then
			self._director:SetTargeting(target, -1)
			z.target = nil
			z.state = "investigate"
			z.investigateAt = theirRoot.Position
			return
		end
	else
		z.lastSeen = tick()
	end

	if z.nextRepath <= 0 then
		self:_repath(z, theirRoot.Position)
		z.nextRepath = 0.6
	end
	self:_followPath(z)
	self:_attack(z, target)
end

-- ---------------------------------------------------------------- specials

function ZombieAI:_updateHunter(z: Zombie, dt: number)
	local cfg = Config.Specials.Hunter
	local root = z.model.PrimaryPart
	if not root then
		return
	end

	local target = nearestPlayer(root.Position)
	if not target then
		return
	end
	local theirRoot = target.Character and target.Character:FindFirstChild("HumanoidRootPart")
	if not theirRoot then
		return
	end

	local dist = (root.Position - theirRoot.Position).Magnitude
	z.cooldown -= dt

	if z.state == "pounce" then
		-- Already airborne; resolve the pin on landing.
		if z.stateTime <= 0 then
			self._playerManager:Pin(target, cfg.PinDuration)
			z.pinned = target
			z.state = "seek"
			z.cooldown = cfg.PounceCooldown
		end
		z.stateTime -= dt
		return
	end

	if dist <= cfg.PounceRange and z.cooldown <= 0 then
		z.state = "pounce"
		z.stateTime = 0.35
		-- Launch at the target.
		local dir = (theirRoot.Position - root.Position).Unit
		local hum = z.model:FindFirstChildOfClass("Humanoid")
		if hum then
			hum.JumpPower = 0
		end
		z.model:PivotTo(CFrame.lookAt(root.Position, root.Position + dir))
		root.AssemblyLinearVelocity = dir * cfg.PounceSpeed
		return
	end

	-- Otherwise just close the distance fast.
	if z.nextRepath <= 0 then
		self:_repath(z, theirRoot.Position)
		z.nextRepath = 0.5
	end
	self:_followPath(z)
end

function ZombieAI:_updateSmoker(z: Zombie, dt: number)
	local cfg = Config.Specials.Smoker
	local root = z.model.PrimaryPart
	if not root then
		return
	end

	z.cooldown -= dt

	if z.pinned then
		-- Reel the victim in.
		local char = z.pinned.Character
		local theirRoot = char and char:FindFirstChild("HumanoidRootPart")
		if not char or not theirRoot then
			self._playerManager:ReleasePin(z.pinned)
			z.pinned = nil
			return
		end
		local dir = (root.Position - theirRoot.Position).Unit
		theirRoot.AssemblyLinearVelocity = dir * cfg.TonguePullSpeed
		return
	end

	local target = nearestPlayer(root.Position)
	if not target then
		return
	end
	local theirRoot = target.Character and target.Character:FindFirstChild("HumanoidRootPart")
	if not theirRoot then
		return
	end

	local dist = (root.Position - theirRoot.Position).Magnitude
	if dist <= cfg.TongueRange and z.cooldown <= 0 then
		z.pinned = target
		z.cooldown = cfg.TongueDuration
		self._director:ReportNoise(target, theirRoot.Position, 1)
		return
	end

	-- Stay at range: back off if they get close.
	if dist < cfg.TongueRange * 0.5 then
		local dir = (root.Position - theirRoot.Position).Unit
		z.model:PivotTo(CFrame.lookAt(root.Position + dir * 10, root.Position))
	end
end

function ZombieAI:_updateBoomer(z: Zombie, dt: number)
	-- The Boomer just waddles toward the nearest player and dies fast.
	-- Its real effect fires in _onZombieDied.
	local root = z.model.PrimaryPart
	if not root then
		return
	end
	local target = nearestPlayer(root.Position)
	if not target then
		return
	end
	local theirRoot = target.Character and target.Character:FindFirstChild("HumanoidRootPart")
	if not theirRoot then
		return
	end
	if z.nextRepath <= 0 then
		self:_repath(z, theirRoot.Position)
		z.nextRepath = 0.8
	end
	self:_followPath(z)
end

function ZombieAI:_updateCharger(z: Zombie, dt: number)
	local cfg = Config.Specials.Charger
	local root = z.model.PrimaryPart
	if not root then
		return
	end

	z.cooldown -= dt

	if z.state == "windup" then
		z.stateTime -= dt
		if z.stateTime <= 0 then
			z.state = "charge"
			z.stateTime = cfg.ChargeDuration
			z.chargeDir = z.chargeDir or Vector3.new(1, 0, 0)
			root.AssemblyLinearVelocity = z.chargeDir * cfg.ChargeSpeed
		end
		return
	end

	if z.state == "charge" then
		z.stateTime -= dt
		if z.stateTime <= 0 then
			z.state = "seek"
			z.cooldown = cfg.ChargeCooldown
			root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
		end
		-- Hit anyone in the line.
		for _, p in ipairs(livingPlayers()) do
			local char = p.Character
			local theirRoot = char and char:FindFirstChild("HumanoidRootPart")
			if theirRoot and (theirRoot.Position - root.Position).Magnitude <= 6 then
				self._playerManager:Knockback(p, z.chargeDir or Vector3.new(1, 0, 0), cfg.ChargeDamage)
			end
		end
		return
	end

	local target = nearestPlayer(root.Position)
	if not target then
		return
	end
	local theirRoot = target.Character and target.Character:FindFirstChild("HumanoidRootPart")
	if not theirRoot then
		return
	end

	if z.cooldown <= 0 then
		local dir = (theirRoot.Position - root.Position).Unit
		z.chargeDir = dir
		z.state = "windup"
		z.stateTime = cfg.WindupTime
		return
	end

	if z.nextRepath <= 0 then
		self:_repath(z, theirRoot.Position)
		z.nextRepath = 0.7
	end
	self:_followPath(z)
end

function ZombieAI:_updateTank(z: Zombie, dt: number)
	local cfg = Config.Specials.Tank
	local root = z.model.PrimaryPart
	if not root then
		return
	end

	z.cooldown -= dt

	local target = nearestPlayer(root.Position)
	if not target then
		return
	end
	local theirRoot = target.Character and target.Character:FindFirstChild("HumanoidRootPart")
	if not theirRoot then
		return
	end

	local dist = (root.Position - theirRoot.Position).Magnitude

	if dist <= cfg.SlamRadius and z.cooldown <= 0 then
		z.cooldown = cfg.SlamCooldown
		-- Ground slam: AoE around the tank.
		for _, p in ipairs(livingPlayers()) do
			local char = p.Character
			local r = char and char:FindFirstChild("HumanoidRootPart")
			if r and (r.Position - root.Position).Magnitude <= cfg.SlamRadius then
				self._playerManager:DamagePlayer(p, cfg.SlamDamage, "Tank")
			end
		end
		return
	end

	if dist > cfg.SlamRadius and z.cooldown <= -2 then
		-- Throw debris at range.
		z.cooldown = cfg.DebrisCooldown
		self._playerManager:DamagePlayer(target, cfg.DebrisDamage, "Tank")
	end

	if z.nextRepath <= 0 then
		self:_repath(z, theirRoot.Position)
		z.nextRepath = 0.8
	end
	self:_followPath(z)
end

-- ---------------------------------------------------------------- update loop

local updaters = {
	Hunter = ZombieAI._updateHunter,
	Smoker = ZombieAI._updateSmoker,
	Boomer = ZombieAI._updateBoomer,
	Charger = ZombieAI._updateCharger,
	Tank = ZombieAI._updateTank,
}

function ZombieAI:Start()
	task.spawn(function()
		while true do
			local dt = task.wait(0.1)
			for id, z in pairs(self._zombies) do
				if z.kind == "Common" then
					self:_updateCommon(z, dt)
				else
					local fn = updaters[z.kind]
					if fn then
						fn(self, z, dt)
					end
				end
			end
		end
	end)
end

return ZombieAI
