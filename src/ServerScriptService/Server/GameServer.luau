--!strict
-- GameServer.luau — the orchestrator. Lobby → zones → debrief.
--
-- Wires together the Director, ZombieAI, PlayerManager, WeaponService and
-- ZoneManager, owns the RemoteEvents, and runs the main game state machine.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage.Shared.Config)

local PlayerManager = require(script.Parent.PlayerManager)
local ZoneManager = require(script.Parent.ZoneManager)
local ZombieAI = require(script.Parent.ZombieAI)
local AIDirector = require(script.Parent.AIDirector)
local WeaponService = require(script.Parent.WeaponService)

export type GameState = "lobby" | "playing" | "debrief"

local GameServer = {}
GameServer.__index = GameServer

function GameServer.new()
	local self = setmetatable({}, GameServer)

	self.State = "lobby"
	self.Remotes = ReplicatedStorage.Remotes
	self._lastStart = 0

	self.PlayerManager = PlayerManager.new()
	self.ZoneManager = ZoneManager.new()
	self.Director = AIDirector.new(nil, self.ZoneManager) -- spawn provider wired below
	self.ZombieAI = ZombieAI.new(self.Director, self.PlayerManager)
	self.WeaponService = WeaponService.new(self.PlayerManager, self.Director)

	-- The Director calls into ZombieAI to actually create zombies.
	self.Director._spawnProvider = self.ZombieAI

	return self
end

-- ---------------------------------------------------------------- lifecycle

function GameServer:Start()
	self.PlayerManager:Start()
	self.ZombieAI:Start()

	for _, player in ipairs(Players:GetPlayers()) do
		self:_onPlayerAdded(player)
	end
	Players.PlayerAdded:Connect(function(p) self:_onPlayerAdded(p) end)
	Players.PlayerRemoving:Connect(function(p) self:_onPlayerRemoved(p) end)

	self:_hookRemotes()
	self:_loop()
end

function GameServer:_onPlayerAdded(player: Player)
	self.PlayerManager:Register(player)
	self.Director:RegisterPlayer(player)
	self.WeaponService:Register(player)
	player.CharacterAdded:Connect(function()
		-- Re-apply state to a fresh character.
		local st = self.PlayerManager:GetState(player)
		if st then
			self.PlayerManager:Register(player)
		end
	end)
end

function GameServer:_onPlayerRemoved(player: Player)
	self.PlayerManager:Unregister(player)
	self.Director:UnregisterPlayer(player)
	self.WeaponService:Unregister(player)
end

function GameServer:_hookRemotes()
	local R = self.Remotes

	R.FireWeapon.OnServerEvent:Connect(function(player, slot, origin, direction)
		if self.State ~= "playing" then
			return
		end
		self.WeaponService:Fire(player, slot, origin, direction)
		self:_sync(player)
	end)

	R.MeleeShove.OnServerEvent:Connect(function(player, origin, direction)
		if self.State ~= "playing" then
			return
		end
		self.WeaponService:Shove(player, origin, direction)
	end)

	R.RevivePlayer.OnServerEvent:Connect(function(player)
		if self.State ~= "playing" then
			return
		end
		-- The client only asks; the server picks who is down and near enough.
		local target = self.PlayerManager:NearestDowned(player)
		if target then
			self.PlayerManager:Revive(target, player)
		end
		self:_syncAll()
	end)

	R.OpenGate.OnServerEvent:Connect(function(player)
		if self.State ~= "playing" then
			return
		end
		if self.ZoneManager:OpenGate(player) then
			self.Director:SetZone(
				self.ZoneManager:GetCurrentZone().Danger,
				self.ZoneManager:GetCurrentZone().CommonCapBonus
			)
			self.ZombieAI:Clear()
			self:_syncAll()
		end
	end)

	R.RequestStart.OnServerEvent:Connect(function(player)
		-- Any player can start the run; that is a party vote by design. It is
		-- rate-limited because it resets the whole world.
		local now = tick()
		if now - self._lastStart < 5 then
			return
		end
		self._lastStart = now
		if self.State == "lobby" then
			self:_beginRun()
		end
	end)
end

-- ---------------------------------------------------------------- state machine

function GameServer:_beginRun()
	self.State = "playing"
	self.ZombieAI:Clear()

	local zone = self.ZoneManager:ActivateZone(1)
	self.Director:SetZone(zone.Danger, zone.CommonCapBonus)
	self.Director:Start()

	for _, player in ipairs(Players:GetPlayers()) do
		self.PlayerManager:Register(player)
	end

	self:_syncAll()
end

function GameServer:_endRun()
	self.State = "debrief"
	self.Director:Stop()
	self.ZombieAI:Clear()

	local payout = 0
	for _, player in ipairs(Players:GetPlayers()) do
		local st = self.PlayerManager:GetState(player)
		if st then
			payout += st.kills * 10 + st.revives * 5
		end
	end

	for _, player in ipairs(Players:GetPlayers()) do
		self.Remotes.StateSync:FireClient(player, {
			state = "debrief",
			payout = payout,
			zone = self.ZoneManager:GetCurrentZone().Name,
		})
	end

	-- Back to the lobby after a breather.
	task.delay(12, function()
		self.State = "lobby"
		self.ZoneManager:ClearZone()
		self:_syncAll()
	end)
end

-- ---------------------------------------------------------------- main loop

function GameServer:_loop()
	task.spawn(function()
		while true do
			task.wait(0.25)
			if self.State ~= "playing" then
				continue
			end

			-- Extraction ends the run.
			if self.ZoneManager:CheckExtraction() then
				self:_endRun()
				continue
			end

			-- Squad wipe: everyone down simultaneously.
			local alive = 0
			for _, player in ipairs(Players:GetPlayers()) do
				local st = self.PlayerManager:GetState(player)
				if st and not st.down then
					alive += 1
				end
			end
			if alive == 0 then
				self:_endRun()
				continue
			end
		end
	end)
end

-- ---------------------------------------------------------------- sync

function GameServer:_sync(player: Player)
	local st = self.PlayerManager:GetState(player)
	if not st then
		return
	end
	local lo = self.WeaponService:GetLoadout(player)
	self.Remotes.StateSync:FireClient(player, {
		state = self.State,
		health = st.health,
		tempHealth = st.tempHealth,
		down = st.down,
		bleedOut = st.bleedOut,
		money = st.money,
		kills = st.kills,
		zone = self.ZoneManager:GetCurrentZone().Name,
		zoneIndex = self.ZoneManager:GetCurrentZoneIndex(),
		phase = self.Director:GetPhase(),
		magazine = lo and lo.primary.magazine or 0,
		reserve = lo and lo.primary.reserve or 0,
	})
end

function GameServer:_syncAll()
	for _, player in ipairs(Players:GetPlayers()) do
		self:_sync(player)
	end
end

-- ---------------------------------------------------------------- bootstrap

local server = GameServer.new()
server:Start()

return server
