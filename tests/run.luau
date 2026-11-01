--!strict
-- run.luau — executes DEAD ZONE's modules under the Lune mock and checks the
-- behaviour we actually care about. No Roblox Studio involved.

local mock = require("./mock")

local passed, failed = 0, 0

local function check(label: string, condition: boolean, detail: string?)
	if condition then
		passed += 1
		print("  PASS  " .. label)
	else
		failed += 1
		print("  FAIL  " .. label .. (detail and ("  -- " .. detail) or ""))
	end
end

local function section(name: string)
	print("\n== " .. name .. " ==")
end

-- ---------------------------------------------------------------- Config

section("Config")
local Config = mock.requireModule(mock.ReplicatedStorage.Shared.Config)
check("Config loads", type(Config) == "table")
check("4 zones defined", #Config.Zones == 4, "got " .. tostring(#Config.Zones))
check("zone ids match ZoneManager expectations",
	Config.Zones[1].Id == "suburbs" and Config.Zones[4].Id == "base")
check("Director budget is positive", Config.Director.BudgetMax > 0)
check("all 5 special infected configured",
	Config.Specials.Hunter ~= nil
	and Config.Specials.Smoker ~= nil
	and Config.Specials.Boomer ~= nil
	and Config.Specials.Charger ~= nil
	and Config.Specials.Tank ~= nil)

-- ---------------------------------------------------------------- AIDirector

section("AIDirector")
local AIDirector = mock.requireModule(mock.ServerFolder.AIDirector)

-- A fake spawn provider so we can count what the Director asks for.
local spawnedCommons, spawnedSpecials = 0, 0
local spawnProvider = {
	SpawnCommon = function(): boolean
		spawnedCommons += 1
		return true
	end,
	SpawnSpecial = function(_kind: string): boolean
		spawnedSpecials += 1
		return true
	end,
	Alert = function(_position: Vector3, _loudness: number) end,
	BroadcastSpawnAlert = function(_count: number) end,
}

local zoneManager = {
	GetCurrentZoneIndex = function(): number
		return 1
	end,
}

local p1 = mock.addPlayer("Tester1")
local p2 = mock.addPlayer("Tester2")

local director = AIDirector.new(spawnProvider, zoneManager)
director:RegisterPlayer(p1.instance)
director:RegisterPlayer(p2.instance)

check("starts in build phase", director:GetPhase() == "build")
check("stress starts at 0", director:GetStress(p1.instance) == 0)

-- Damage should raise stress.
director:ReportDamage(p1.instance, 50)
check("damage raises stress", director:GetStress(p1.instance) > 0,
	"stress=" .. string.format("%.1f", director:GetStress(p1.instance)))

-- Noise should raise stress further.
local before = director:GetStress(p1.instance)
director:ReportNoise(p1.instance, Vector3.new(0, 3, 0), 1)
check("noise raises stress", director:GetStress(p1.instance) > before)

-- Targeting pressure should be reflected.
director:SetTargeting(p1.instance, 5)
local s1 = director:GetStress(p1.instance)
check("targeting contributes to stress", s1 > 0)

-- Simulate ticks and confirm the Director actually spends budget.
spawnedCommons = 0
for _ = 1, 40 do
	director:_tick(0.25)
end
check("Director spawns commons during play", spawnedCommons > 0,
	"spawned=" .. tostring(spawnedCommons))

-- A horde should force the crescendo phase.
director:AlertHorde()
check("AlertHorde forces crescendo", director:GetPhase() == "crescendo")

-- Stress must never exceed the cap.
for _ = 1, 20 do
	director:ReportDamage(p2.instance, 999)
end
check("stress is capped", director:GetStress(p2.instance) <= Config.Director.StressMax,
	"stress=" .. string.format("%.1f", director:GetStress(p2.instance)))

director:UnregisterPlayer(p1.instance)
director:UnregisterPlayer(p2.instance)

-- ---------------------------------------------------------------- PlayerManager

section("PlayerManager")
local PlayerManager = mock.requireModule(mock.ServerFolder.PlayerManager)
local pm = PlayerManager.new()
pm:Register(p1.instance)

local st = pm:GetState(p1.instance)
check("player starts at full health", st.health == Config.MaxHealth)

pm:Damage(p1.instance, 30, "Test")
check("damage reduces health", pm:GetState(p1.instance).health == Config.MaxHealth - 30,
	"health=" .. tostring(pm:GetState(p1.instance).health))

pm:Heal(p1.instance, 10, false)
check("heal restores health", pm:GetState(p1.instance).health == Config.MaxHealth - 20)

-- Down state.
pm:Damage(p1.instance, 500, "Test")
check("lethal damage downs the player", pm:GetState(p1.instance).down == true)
check("bleed-out timer is running", pm:GetState(p1.instance).bleedOut > 0)

-- A downed player takes no further damage.
local hpBeforeDown = pm:GetState(p1.instance).health
pm:Damage(p1.instance, 100, "Test")
check("downed player is not damaged further", pm:GetState(p1.instance).health == hpBeforeDown)

-- Revive.
pm:Revive(p1.instance, p2.instance)
local after = pm:GetState(p1.instance)
check("revive clears down state", after.down == false)
check("revive restores minimal health", after.health == Config.ReviveHealth)
check("revive grants invulnerability", after.invulnerable > 0)

-- Temp HP decays and is capped.
pm:Heal(p1.instance, 999, true)
check("temp health is capped", pm:GetState(p1.instance).tempHealth <= Config.PillTempHealth)

-- ---------------------------------------------------------------- WeaponService

section("WeaponService")
local WeaponService = mock.requireModule(mock.ServerFolder.WeaponService)
local ws = WeaponService.new(pm, director)
ws:Register(p1.instance)

local lo = ws:GetLoadout(p1.instance)
check("loadout starts full", lo.primary.magazine == Config.Primary.Magazine)

-- Firing consumes ammo. The mock raycast hits nothing, so we only assert the
-- bookkeeping and the anti-cheat gate.
-- First-person origin: the camera sits at the head, just above the character
-- root at (0, 3, 0). WeaponService checks the claimed origin against the
-- player's real position, so the test must send a plausible one.
local origin = Vector3.new(0, 3.6, 0)
local dir = Vector3.new(0, 0, -1)
check("first shot is accepted", ws:Fire(p1.instance, "primary", origin, dir) == true)
check("ammo was consumed", ws:GetLoadout(p1.instance).primary.magazine == Config.Primary.Magazine - 1)

-- The anti-cheat gate must reject a shot fired faster than the weapon allows.
check("rate limit rejects an instant second shot",
	ws:Fire(p1.instance, "primary", origin, dir) == false)
check("no ammo was consumed by the rejected shot",
	ws:GetLoadout(p1.instance).primary.magazine == Config.Primary.Magazine - 1)

-- A client that claims to be shooting from somewhere it is not must be refused,
-- even with ammo in the magazine. This is the origin-spoof check.
local spoofOrigin = Vector3.new(0, 3.6, 0) + Vector3.new(500, 0, 0)
local magBeforeSpoof = ws:GetLoadout(p1.instance).primary.magazine
check("a spoofed origin is rejected", ws:Fire(p1.instance, "primary", spoofOrigin, dir) == false)
check("a spoofed origin spends no ammo",
	ws:GetLoadout(p1.instance).primary.magazine == magBeforeSpoof)
check("a non-unit direction is rejected", ws:Fire(p1.instance, "primary", origin, Vector3.new(0, 0, 0)) == false)
check("an unknown slot is rejected", ws:Fire(p1.instance, "launcher", origin, dir) == false)
check("a shot uses the server's position, not the client's claim",
	mock.lastRaycast ~= nil and (mock.lastRaycast.origin - Vector3.new(0, 3, 0)).Magnitude < 0.01,
	"origin=" .. tostring(mock.lastRaycast and mock.lastRaycast.origin))

-- Shove has its own cooldown. Give the region a fake zombie so there is
-- something to push, which is what the shove actually reports on.
local zombieModel = mock.Workspace:FindFirstChild("Character") or nil
local shoveTarget = Instance.new("Part")
shoveTarget.Name = "Torso"
local zombie = Instance.new("Model")
zombie.Name = "Common"
zombie:SetAttribute("ZombieKind", "Common")
shoveTarget.Parent = zombie
local zroot = Instance.new("Part")
zroot.Name = "HumanoidRootPart"
zroot.Size = Vector3.new(2, 2, 1)
zroot.Position = origin + Vector3.new(6, 0, 0)
zroot.Parent = zombie
zombie.PrimaryPart = zroot
zombie.Parent = mock.Workspace

mock.regionZombies = { shoveTarget }

local shoveOk = ws:Shove(p1.instance, origin, dir)
check("shove is accepted once", shoveOk == true)
check("shove cooldown rejects an immediate second shove",
	ws:Shove(p1.instance, origin, dir) == false)
-- The shove's origin is checked the same way as a shot.
check("shove with a spoofed origin is rejected",
	ws:Shove(p1.instance, spoofOrigin, dir) == false)

-- ---------------------------------------------------------------- summary

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
	-- Lune has no os.exit; a nonzero process exit is what CI checks.
	local process = require("@lune/process")
	process.exit(1)
end
