--!strict
-- ZoneManager.luau — zone activation, gates, and extraction.
--
-- A zone is a folder in Workspace.DeadZone.Zones with a few tagged children.
-- The gate is a model tagged "Gate"; interacting with it opens the way to the
-- next zone. Reaching the last zone's extraction point ends the run.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)

local ZoneManager = {}
ZoneManager.__index = ZoneManager

function ZoneManager.new()
	local self = setmetatable({}, ZoneManager)
	self._index = 0
	self._active = false
	self._gates = {}
	self._extracts = {}
	return self
end

function ZoneManager:GetCurrentZoneIndex(): number
	return self._index
end

function ZoneManager:GetCurrentZone()
	return Config.Zones[self._index]
end

function ZoneManager:IsLastZone(): boolean
	return self._index >= #Config.Zones
end

-- Reset to a clean pre-run state.
function ZoneManager:ClearZone()
	self._index = 0
	self._active = false
end

-- Find the spawn point for a zone: any part tagged "SpawnPoint".
function ZoneManager:GetSpawnPoints(index: number): { BasePart }
	local zoneFolder = workspace:FindFirstChild("DeadZone")
		and workspace.DeadZone:FindFirstChild("Zones")
		and workspace.DeadZone.Zones:FindFirstChild(Config.Zones[index].Id)
	if not zoneFolder then
		return {}
	end
	local out = {}
	for _, inst in ipairs(zoneFolder:GetDescendants()) do
		if inst:IsA("BasePart") and inst:GetAttribute("Role") == "SpawnPoint" then
			table.insert(out, inst)
		end
	end
	return out
end

-- Teleport the squad into a zone.
function ZoneManager:ActivateZone(index: number)
	self._index = index
	self._active = true
	local zone = Config.Zones[index]
	local spawns = self:GetSpawnPoints(index)

	for i, player in ipairs(Players:GetPlayers()) do
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if char and root then
			local spot = spawns[(i - 1) % #spawns + 1]
			if spot then
				char:PivotTo(CFrame.new(spot.Position + Vector3.new(0, 3, 0)))
			end
		end
	end

	return zone
end

-- Called when a player interacts with the gate.
function ZoneManager:OpenGate(player: Player): boolean
	if not self._active or self:IsLastZone() then
		return false
	end
	-- Every living player must be near the gate, or be down (auto-carried).
	for _, p in ipairs(Players:GetPlayers()) do
		local char = p.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if char and root then
			local gate = self:_gateForZone(self._index)
			if gate and (root.Position - gate.Position).Magnitude > 40 then
				-- Too far away: not ready yet.
				return false
			end
		end
	end

	local nextIndex = self._index + 1
	self:ActivateZone(nextIndex)
	return true
end

function ZoneManager:_gateForZone(index: number): Vector3?
	local folder = workspace:FindFirstChild("DeadZone")
		and workspace.DeadZone:FindFirstChild("Gates")
		and workspace.DeadZone.Gates:FindFirstChild(Config.Zones[index].Id)
	if not folder then
		return nil
	end
	local gate = folder:FindFirstChildWhichIsA("BasePart", true)
	return gate and gate.Position or nil
end

-- Extraction: the last zone's extraction point ends the run.
function ZoneManager:CheckExtraction(): boolean
	if not self._active or not self:IsLastZone() then
		return false
	end
	local zone = Config.Zones[self._index]
	local folder = workspace:FindFirstChild("DeadZone")
		and workspace.DeadZone:FindFirstChild("Zones")
		and workspace.DeadZone.Zones:FindFirstChild(zone.Id)
	if not folder then
		return false
	end

	local extract = nil
	for _, inst in ipairs(folder:GetDescendants()) do
		if inst:IsA("BasePart") and inst:GetAttribute("Role") == "Extraction" then
			extract = inst
			break
		end
	end
	if not extract then
		return false
	end

	-- Everyone alive must be inside the extraction radius.
	for _, p in ipairs(Players:GetPlayers()) do
		local char = p.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if char and root and (root.Position - extract.Position).Magnitude > 25 then
			return false
		end
	end
	return true
end

return ZoneManager
