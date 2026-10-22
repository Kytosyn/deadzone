--!strict
-- PlayerManager.luau — health, temp HP, down-but-not-out, revives, pins,
-- knockback and money.
--
-- Everything that mutates a player's state goes through here so the HUD and
-- the Director can always see the truth.
--
-- Public API:
--   PlayerManager.new() -> PlayerManager
--   pm:Start()
--   pm:Damage(player, amount, source?)
--   pm:Heal(player, amount, isTemp?)
--   pm:Down(player)
--   pm:Revive(player, reviver?)
--   pm:ReleasePin(player)
--   pm:Pin(player, duration)
--   pm:Knockback(player, direction, damage)
--   pm:AddMoney(player, amount)
--   pm:GetState(player) -> table

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)

export type PlayerState = {
	player: Player,
	health: number,
	tempHealth: number,
	down: boolean,
	bleedOut: number,
	pinned: boolean,
	money: number,
	revives: number,
	kills: number,
	invulnerable: number,
}

local PlayerManager = {}
PlayerManager.__index = PlayerManager

function PlayerManager.new()
	local self = setmetatable({}, PlayerManager)
	self._states = {}
	return self
end

function PlayerManager:Register(player: Player)
	self._states[player] = {
		player = player,
		health = Config.MaxHealth,
		tempHealth = 0,
		down = false,
		bleedOut = 0,
		pinned = false,
		money = 0,
		revives = 0,
		kills = 0,
		invulnerable = 0,
	}
end

function PlayerManager:Unregister(player: Player)
	self._states[player] = nil
end

function PlayerManager:GetState(player: Player): PlayerState?
	return self._states[player]
end

function PlayerManager:_hum(player: Player): Humanoid?
	local char = player.Character
	return char and char:FindFirstChildOfClass("Humanoid")
end

function PlayerManager:Damage(player: Player, amount: number, source: string?)
	local st = self._states[player]
	if not st then
		return
	end
	if st.invulnerable > 0 or st.down then
		return
	end

	-- Temp HP absorbs first.
	if st.tempHealth > 0 then
		local absorbed = math.min(st.tempHealth, amount)
		st.tempHealth -= absorbed
		amount -= absorbed
	end

	st.health -= amount

	local hum = self:_hum(player)
	if hum then
		hum:TakeDamage(amount)
	end

	if st.health <= 0 then
		st.health = 0
		self:Down(player)
	end
end

function PlayerManager:Heal(player: Player, amount: number, isTemp: boolean)
	local st = self._states[player]
	if not st then
		return
	end
	if isTemp then
		st.tempHealth = math.min(Config.PillTempHealth, st.tempHealth + amount)
		return
	end
	st.health = math.min(Config.MaxHealth, st.health + amount)
end

function PlayerManager:Down(player: Player)
	local st = self._states[player]
	if not st or st.down then
		return
	end
	st.down = true
	st.bleedOut = Config.DownBleedOut
	st.health = 0

	-- A downed player can't be damaged further but can still be revived.
	local hum = self:_hum(player)
	if hum then
		hum.Health = 1
		hum.WalkSpeed = 6
		hum.JumpPower = 0
	end
end

function PlayerManager:Revive(player: Player, reviver: Player?)
	local st = self._states[player]
	if not st or not st.down then
		return
	end
	st.down = false
	st.health = Config.ReviveHealth
	st.bleedOut = 0
	st.invulnerable = Config.ReviveInvulnerability

	local hum = self:_hum(player)
	if hum then
		hum.Health = Config.ReviveHealth
		hum.WalkSpeed = 16
		hum.JumpPower = 50
	end

	if reviver then
		local r = self._states[reviver]
		if r then
			r.revives += 1
		end
		self:AddMoney(reviver, Config.Money.ReviveBonus)
	end
end

function PlayerManager:Pin(player: Player, duration: number)
	local st = self._states[player]
	if not st then
		return
	end
	st.pinned = true
	task.delay(duration, function()
		self:ReleasePin(player)
	end)
end

function PlayerManager:ReleasePin(player: Player)
	local st = self._states[player]
	if st then
		st.pinned = false
	end
end

function PlayerManager:Knockback(player: Player, direction: Vector3, damage: number)
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end
	local dir = direction.Unit
	if dir ~= dir then -- NaN guard
		dir = Vector3.new(0, 0, 1)
	end
	root.AssemblyLinearVelocity = dir * 60 + Vector3.new(0, 30, 0)
	self:Damage(player, damage, "Charger")
end

function PlayerManager:AddMoney(player: Player, amount: number)
	local st = self._states[player]
	if st then
		st.money += amount
	end
end

function PlayerManager:AddKill(player: Player)
	local st = self._states[player]
	if st then
		st.kills += 1
	end
end

function PlayerManager:AllStates(): { PlayerState }
	local out = {}
	for _, st in pairs(self._states) do
		table.insert(out, st)
	end
	return out
end

-- ---------------------------------------------------------------- main loop

function PlayerManager:Start()
	-- Bleed-out countdown and temp HP decay.
	task.spawn(function()
		while true do
			local dt = task.wait(0.25)
			for player, st in pairs(self._states) do
				if st.down then
					st.bleedOut -= dt
					if st.bleedOut <= 0 then
						st.down = false
						local hum = self:_hum(player)
						if hum then
							hum.Health = 0
						end
					end
				end
				if st.tempHealth > 0 then
					st.tempHealth = math.max(0, st.tempHealth - Config.TempHealthDecayPerSecond * dt)
				end
				if st.invulnerable > 0 then
					st.invulnerable = math.max(0, st.invulnerable - dt)
				end
			end
		end
	end)
end

return PlayerManager
