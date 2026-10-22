--!strict
-- WeaponService.luau — hitscan weapons and the melee shove.
--
-- The client sends a fire request with an origin and direction. The server
-- validates it (rate, ammo, cooldown) and does the raycast, so a client can't
-- just claim hits. Ammo lives here, keyed per player.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)

local WeaponService = {}
WeaponService.__index = WeaponService

type Loadout = {
	player: Player,
	primary: { magazine: number, reserve: number, reloading: boolean },
	secondary: { magazine: number, reserve: number, reloading: boolean },
	lastFire: number,
	lastShove: number,
}

function WeaponService.new(playerManager: any, director: any)
	local self = setmetatable({}, WeaponService)
	self._playerManager = playerManager
	self._director = director
	self._loadouts = {}
	return self
end

function WeaponService:Register(player: Player)
	self._loadouts[player] = {
		player = player,
		primary = {
			magazine = Config.Primary.Magazine,
			reserve = Config.Primary.ReserveMax,
			reloading = false,
		},
		secondary = {
			magazine = Config.Secondary.Magazine,
			reserve = Config.Secondary.ReserveMax,
			reloading = false,
		},
		lastFire = 0,
		lastShove = 0,
	}
end

function WeaponService:Unregister(player: Player)
	self._loadouts[player] = nil
end

function WeaponService:GetLoadout(player: Player)
	return self._loadouts[player]
end

function WeaponService:_raycast(origin: Vector3, direction: Vector3, range: number, exclude: { Instance }): any
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = exclude
	params.IgnoreWater = true
	return workspace:Raycast(origin, direction * range, params)
end

-- Fire a weapon. `slot` is "primary" or "secondary".
function WeaponService:Fire(player: Player, slot: string, origin: Vector3, direction: Vector3): boolean
	local lo = self._loadouts[player]
	if not lo then
		return false
	end
	local weapon = if slot == "primary" then lo.primary else lo.secondary
	local cfg = if slot == "primary" then Config.Primary else Config.Secondary

	-- Anti-cheat: reject if fired faster than the weapon allows.
	local now = tick()
	if now - lo.lastFire < cfg.FireInterval * 0.9 then
		return false
	end
	if weapon.reloading then
		return false
	end
	if weapon.magazine <= 0 then
		-- Auto-reload if there's reserve ammo.
		if weapon.reserve > 0 then
			self:Reload(player, slot)
		end
		return false
	end

	weapon.magazine -= 1
	lo.lastFire = now

	-- Raycast against everything except the shooter.
	local exclude = { player.Character }
	local hit = self:_raycast(origin, direction, cfg.Range, exclude)

	if hit and hit.Instance then
		local humanoid = hit.Instance:FindFirstAncestorOfClass("Model")
			and hit.Instance:FindFirstAncestorOfClass("Model"):FindFirstChildOfClass("Humanoid")
		if humanoid then
			local model = humanoid.Parent
			local isHead = hit.Instance.Name == "Head"
			local mult = if isHead then cfg.HeadshotMultiplier else 1
			humanoid:TakeDamage(cfg.Damage * mult)

			-- Kill credit: report to whoever owns this model.
			self:_creditKill(model, player)

			-- Notify the Director so it can react to the fight.
			local director = self._director
			if director then
				director:ReportNoise(player, origin, 0.6)
			end
		end
	end

	return true
end

function WeaponService:_creditKill(model: Model, player: Player)
	-- Zombie models are tagged with an attribute set by ZombieAI.
	local kind = model:GetAttribute("ZombieKind")
	if kind then
		local money = if kind == "Common"
			then Config.Money.CommonKill
			else Config.Money.SpecialKill
		self._playerManager:AddMoney(player, money)
		self._playerManager:AddKill(player)
	end
end

function WeaponService:Reload(player: Player, slot: string)
	local lo = self._loadouts[player]
	if not lo then
		return
	end
	local weapon = if slot == "primary" then lo.primary else lo.secondary
	local cfg = if slot == "primary" then Config.Primary else Config.Secondary
	if weapon.reloading then
		return
	end
	local need = cfg.Magazine - weapon.magazine
	if need <= 0 or weapon.reserve <= 0 then
		return
	end
	weapon.reloading = true
	task.delay(cfg.ReloadTime, function()
		local l = self._loadouts[player]
		if not l then
			return
		end
		local w = if slot == "primary" then l.primary else l.secondary
		local take = math.min(need, w.reserve)
		w.magazine += take
		w.reserve -= take
		w.reloading = false
	end)
end

-- Melee shove: the L4D2 panic button. Pushes zombies back and stuns them.
function WeaponService:Shove(player: Player, origin: Vector3, direction: Vector3): boolean
	local lo = self._loadouts[player]
	if not lo then
		return false
	end
	local now = tick()
	if now - lo.lastShove < Config.Melee.ShoveCooldown then
		return false
	end
	lo.lastShove = now

	local pushed = 0
	local region = Region3.new(
		origin - Vector3.new(Config.Melee.ShoveRange, 4, Config.Melee.ShoveRange),
		origin + Vector3.new(Config.Melee.ShoveRange, 6, Config.Melee.ShoveRange)
	)
	for _, inst in ipairs(workspace:FindPartsInRegion3(region, player.Character, 60)) do
		local model = inst:FindFirstAncestorOfClass("Model")
		if model and model ~= player.Character and model:GetAttribute("ZombieKind") then
			local root = model.PrimaryPart
			if root then
				local dir = (root.Position - origin)
				dir = Vector3.new(dir.X, 0, dir.Z)
				if dir.Magnitude > 0 then
					root.AssemblyLinearVelocity = dir.Unit * Config.Melee.ShoveForce
						+ Vector3.new(0, 25, 0)
					pushed += 1
				end
			end
		end
	end

	if pushed > 0 then
		local director = self._director
		if director then
			director:ReportNoise(player, origin, 1)
		end
	end

	return pushed > 0
end

return WeaponService
