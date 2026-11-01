--!strict
-- mock.luau — a minimal Roblox API surface so DEAD ZONE's modules can run
-- under Lune without Roblox Studio. This is what turns "written but never
-- executed" into "executed and checked".
--
-- Lune instances reject arbitrary member assignment, so every method and
-- service here is attached with roblox.registerService / implementMethod /
-- implementProperty, which is also how Lune expects extensions to be written.

local roblox = require("@lune/roblox")
local luneTask = require("@lune/task")
local fs = require("@lune/fs")

local Instance = roblox.Instance
local Vector3 = roblox.Vector3

local mock = {}

-- Debug hook for the test suite: the mock's Workspace:Raycast and
-- FindPartsInRegion3 are implemented with implementMethod, so their behaviour
-- is not directly inspectable from a test.
mock.lastRaycast = nil

-- ---------------------------------------------------------------- instance helpers

local function makeInstance(className: string, name: string, parent: Instance?): Instance
	local inst = Instance.new(className)
	inst.Name = name
	if parent then
		inst.Parent = parent
	end
	return inst
end

-- ---------------------------------------------------------------- DataModel

local game = Instance.new("DataModel")

local ReplicatedStorage = makeInstance("ReplicatedStorage", "ReplicatedStorage", game)
local ServerScriptService = makeInstance("ServerScriptService", "ServerScriptService", game)
local StarterPlayer = makeInstance("StarterPlayer", "StarterPlayer", game)
local Workspace = makeInstance("Workspace", "Workspace", game)
local ServerStorage = makeInstance("ServerStorage", "ServerStorage", game)

-- ModuleScript instances so Roblox-style require paths resolve to tree paths.
local Shared = makeInstance("Folder", "Shared", ReplicatedStorage)
local ServerFolder = makeInstance("Folder", "Server", ServerScriptService)
makeInstance("ModuleScript", "Config", Shared)
for _, name in ipairs({ "PlayerManager", "ZoneManager", "ZombieAI", "AIDirector", "WeaponService" }) do
	makeInstance("ModuleScript", name, ServerFolder)
end

-- Workspace.DeadZone structure the ZoneManager looks for.
local DeadZone = makeInstance("Folder", "DeadZone", Workspace)
local ZonesFolder = makeInstance("Folder", "Zones", DeadZone)
local GatesFolder = makeInstance("Folder", "Gates", DeadZone)
local LootFolder = makeInstance("Folder", "Loot", DeadZone)

-- ---------------------------------------------------------------- services

-- Players
-- Players, PathfindingService and Debris already exist as Lune classes, so
-- only their methods need implementing.

type FakePlayer = { name: string, instance: Instance, character: Instance? }
local players: { FakePlayer } = {}
local characters: { [Instance]: Instance } = {}

roblox.implementMethod("Players", "GetPlayers", function()
	local out = {}
	for _, p in ipairs(players) do
		table.insert(out, p.instance)
	end
	return out
end)

roblox.implementMethod("Humanoid", "TakeDamage", function(self: Instance, _amount: number)
	-- Health is not simulated in the harness; the call just has to not throw,
	-- which it does in a real place.
end)

roblox.implementMethod("PathfindingService", "CreatePath", function(_: Instance)
	return {
		ComputeAsync = function(self: any, _a: Vector3, _b: Vector3): boolean
			self.Status = roblox.Enum.PathStatus.Success
			return true
		end,
		GetWaypoints = function(self: any)
			return self._waypoints or {}
		end,
		_waypoints = {},
		Status = roblox.Enum.PathStatus.NoPath,
	}
end)

roblox.implementMethod("Debris", "AddItem", function(_: Instance, _inst: Instance, _ttl: number) end)

-- Workspace has no geometry in the harness. Zombies in region can be injected
-- by tests via mock.regionZombies so shove/area logic has something to hit.
mock.regionZombies = {}

roblox.implementMethod("Workspace", "Raycast", function(_: Instance, origin: Vector3, dir: Vector3, _p: any?): any
	-- No geometry in the harness, so no shot ever connects.
	mock.lastRaycast = { origin = origin, dir = dir }
	return nil
end)

roblox.implementMethod("Workspace", "FindPartsInRegion3", function(_: Instance, _r: any, _i: Instance?, _m: number?): { Instance }
	return mock.regionZombies
end)

-- game:GetService must hand back the real service instances.
roblox.implementMethod("DataModel", "GetService", function(self: Instance, name: string): Instance
	local direct = self:FindFirstChild(name)
	if direct then
		return direct
	end
	local svc = Instance.new(name)
	svc.Name = name
	svc.Parent = self
	return svc
end)

-- `game.Workspace` and `game.Players` are how the modules reach these.
roblox.implementProperty("DataModel", "Workspace", function(self: Instance)
	return self:FindFirstChild("Workspace")
end)
roblox.implementProperty("DataModel", "Players", function(self: Instance)
	return self:GetService("Players")
end)

-- ---------------------------------------------------------------- player factory

local function addPlayer(name: string): FakePlayer
	local p = Instance.new("Player")
	p.Name = name

	local char = makeInstance("Model", "Character", nil)
	local root = makeInstance("Part", "HumanoidRootPart", char)
	root.Size = Vector3.new(2, 2, 1)
	root.Position = Vector3.new(0, 3, 0)
	-- A Head so first-person fire origins (head + ~0.6) sit inside the
	-- WeaponService origin tolerance of the character root.
	local head = makeInstance("Part", "Head", char)
	head.Size = Vector3.new(1, 1, 1)
	head.Position = root.Position + Vector3.new(0, 0.6, 0)
	local hum = makeInstance("Humanoid", "Humanoid", char)
	hum.MaxHealth = 100
	hum.Health = 100
	hum.WalkSpeed = 16
	char.PrimaryPart = root
	char.Parent = Workspace

	local entry: FakePlayer = { name = name, instance = p, character = char }
	table.insert(players, entry)

	-- Roblox's engine links a Model with a Humanoid in Workspace to the player
	-- automatically; Lune does not, so the harness has to do it explicitly or
	-- every server-side player lookup (WeaponService's origin check, ZoneManager
	-- teleports, revives) would see no character.
	local ok = pcall(function()
		p.Character = char
	end)
	if not ok then
		characters[p] = char
		roblox.implementProperty("Player", "Character", function(self: Instance)
			return characters[self]
		end)
	end

	return entry
end

-- ---------------------------------------------------------------- module loader

-- Resolve the source root from this file's own absolute path so the suite runs
-- on any machine, instead of a hardcoded dev-box path. `debug.info` returns an
-- absolute path in Lune regardless of the working directory.
local function scriptDir(): string
	local here = debug.info(1, "s") -- ".../tests/mock"
	local slash = here:match("()[^/]*$")
	if slash then
		return here:sub(1, slash - 1)
	end
	return "."
end

local SOURCE_ROOT = scriptDir() .. "/../src"

local MODULE_MAP: { [string]: string } = {
	["ReplicatedStorage.Shared.Config"] = SOURCE_ROOT .. "/ReplicatedStorage/Shared/Config.luau",
	["ServerScriptService.Server.PlayerManager"] = SOURCE_ROOT .. "/ServerScriptService/Server/PlayerManager.luau",
	["ServerScriptService.Server.ZoneManager"] = SOURCE_ROOT .. "/ServerScriptService/Server/ZoneManager.luau",
	["ServerScriptService.Server.ZombieAI"] = SOURCE_ROOT .. "/ServerScriptService/Server/ZombieAI.luau",
	["ServerScriptService.Server.AIDirector"] = SOURCE_ROOT .. "/ServerScriptService/Server/AIDirector.luau",
	["ServerScriptService.Server.WeaponService"] = SOURCE_ROOT .. "/ServerScriptService/Server/WeaponService.luau",
}

local moduleCache: { [string]: any } = {}

local function resolvePath(target: any): string?
	if typeof(target) == "Instance" then
		local parts = {}
		local node: Instance? = target
		while node and node ~= game do
			table.insert(parts, 1, node.Name)
			node = node.Parent
		end
		return table.concat(parts, ".")
	end
	return target
end

function mock.requireModule(target: any): any
	local path = resolvePath(target)
	if not path then
		error("mock.requireModule: cannot resolve " .. tostring(target))
	end
	if moduleCache[path] then
		return moduleCache[path]
	end
	local file = MODULE_MAP[path]
	if not file then
		error("mock.requireModule: no mapping for '" .. path .. "'")
	end
	-- Lune has no loadfile; loadstring over the file contents is the equivalent.
	local contents, readErr = fs.readFile(file)
	if not contents then
		error("mock.requireModule: failed to read '" .. path .. "': " .. tostring(readErr))
	end
	local chunk, err = loadstring(contents, "@" .. file)
	if not chunk then
		error("mock.requireModule: failed to compile '" .. path .. "': " .. tostring(err))
	end
	local value = chunk()
	moduleCache[path] = value
	return value
end

-- ---------------------------------------------------------------- globals

local scriptInstance = { Parent = ServerFolder, Name = "GameServer" }

local globals: { [string]: any } = {
	game = game,
	workspace = Workspace,
	script = scriptInstance,
	require = mock.requireModule,
	task = luneTask,
	tick = function(): number
		return os.clock()
	end,
	Vector3 = Vector3,
	CFrame = roblox.CFrame,
	Color3 = roblox.Color3,
	UDim2 = roblox.UDim2,
	Region3 = roblox.Region3,
	Enum = roblox.Enum,
	Instance = Instance,
	Vector2 = roblox.Vector2,
	RaycastParams = {
		new = function()
			return { FilterType = 0, FilterDescendantsInstances = {}, IgnoreWater = false }
		end,
	},
}

-- Globals must be assigned *implicitly* in a scope that has no local named
-- `game` (see globals.luau for why).
local globalsModule = require("./globals")
globalsModule.install(globals)

-- Diagnostics: confirm the globals are visible to a loadstring chunk.
local probe = loadstring("return type(game) .. '/' .. type(workspace) .. '/' .. type(require)")
print("[mock] chunk sees game/workspace/require:", pcall(probe))

-- ---------------------------------------------------------------- exports

mock.game = game
mock.Workspace = Workspace
mock.ReplicatedStorage = ReplicatedStorage
mock.ServerFolder = ServerFolder
mock.ZonesFolder = ZonesFolder
mock.GatesFolder = GatesFolder
mock.LootFolder = LootFolder
mock.addPlayer = addPlayer
mock.players = players

return mock
