# DEAD ZONE

A 4-player co-op zombie FPS for Roblox — L4D2's combat DNA inside a
GTA-style zone-to-zone session structure.

Four players drop into a quarantined city and fight zone to zone. Scavenge,
survive hordes, hit the gate, move on. See [DESIGN.md](DESIGN.md) for the full
design.

## Status

**The simulation is built and verified. The game is not yet playable.**

- 8 Luau modules (~2,400 lines), all syntax-clean
- Builds with Rojo to a real `.rbxl`
- Unit tests run the modules under Lune: **30/30 passing**
- No map, no engine playtest, no publish — see "What's missing" below

## Layout

```
default.project.json              Rojo project (source tree -> DataModel)
DESIGN.md                         full design: loop, zones, Director, specials
PUSH.md                           how to get this into Roblox Studio
src/
  ReplicatedStorage/Shared/Config.luau    every tuning number in one place
  ServerScriptService/Server/
    GameServer.luau                       lobby -> zones -> debrief
    AIDirector.luau                       L4D2 Director: stress-driven spawns
    ZombieAI.luau                         common + special infected behaviours
    PlayerManager.luau                    health, down/revive, money
    WeaponService.luau                    hitscan, ammo, melee shove
    ZoneManager.luau                      zones, gates, extraction
  StarterPlayer/StarterPlayerScripts/
    ClientController.luau                 FPS camera, HUD, input
tests/
  mock.luau                         minimal Roblox API surface for Lune
  globals.luau                      installs those globals into the runtime
  run.luau                          the test suite (30 checks)
```

## Build

```bash
rojo build --output deadzone.rbxl
```

## Test

```bash
lune run tests/run.luau   # module logic (30 checks)
lune run tests/map.luau   # map integrity  (33 checks)
```

Both need [Rojo](https://rojo.space) and [Lune](https://lune-org.github.io).
Version pins are not vendored here — install current releases of both.

The suite runs the **real** modules against a mock Roblox API, so it covers
logic without needing Studio:

- Director: stress model, phase machine, spawn budget, stress cap
- PlayerManager: damage, heal, down, bleed-out, revive, temp HP
- WeaponService: ammo consumption, fire-rate anti-cheat, shove cooldown
- Map: every zone has its spawn pads, gate and loot the server looks up

## Map

```bash
python3 build_map.py      # regenerates map/*.model.json
rojo build --output deadzone.rbxl
```

`map/` is generated — edit `build_map.py` and regenerate rather than hand-editing
the JSON. The tags are the contract `ZoneManager`/`ZombieAI` read:

| Where | Tag | Read by |
|---|---|---|
| `Zones/<id>/**` | `Role = "SpawnPoint"` | `GetSpawnPoints` |
| `Zones/base/**` | `Role = "Extraction"` | `CheckExtraction` |
| `Gates/<id>/**` | any BasePart | `_gateForZone` |
| `Loot/**` | `Role = "Pickup"`, `Kind = <kind>` | loot spawner |

Zone ids match `Config.Zones[*].Id`: `suburbs`, `hospital`, `mall`, `base`.

## What's missing

- **No engine playtest.** The 63 checks run against a mock and the generated map
  JSON, not the real engine — no physics, real camera, or pathfinding. This is
  the largest remaining risk: nothing has executed in Studio.
- **`ClientController` and `GameServer` are untested** at runtime, and are not
  covered by the Lune suite either (they need a live client/server).
- **No art.** The map is a greybox: flat coloured parts, no meshes, textures,
  lighting or audio. It exists to make the loop playable, not to look finished.
- **No publish.** Publishing needs either Roblox Studio (blocked on the unsigned
  account — see below) or an Open Cloud API key, which routes around Studio.

## Roblox Studio

Studio is installed on this Mac (`/Applications/RobloxStudio.app`) and the
`Roblox_Studio` MCP server is wired up in Hermes. **It is not signed in** —
Studio's own log says `Authenticated : NO`, and there is no
`~/Library/Application Support/Roblox` directory at all. Because of that the MCP
server connects but exposes **0 tools**:

```
$ hermes mcp test Roblox_Studio
  ✓ Connected (10815ms)
  ✓ Tools discovered: 0
```

Signing in is the single gate on going playable. Two ways to finish it:

```bash
# A) interactively: open Studio, log in through its browser window
open -a RobloxStudio

# B) non-interactively, if you already have a .ROBLOSECURITY cookie
#    (Studio stores it in the macOS keychain, not a file)
```

Until Studio is authenticated, Rojo can build the place and the Lune suite can
verify logic, but nothing can be pushed into Studio or playtested. See PUSH.md.

## Verification

Verified on macOS, 2026-10-23:

| Check | Result |
|---|---|
| `luau-compile` syntax, all modules | pass |
| `rojo build` | pass |
| `lune run tests/run.luau` | 30/30 pass |
| `lune run tests/map.luau` | 33/33 pass |
| Map parts generated | 97 across 9 folders |
| Roblox engine playtest | not run — Studio not signed in |
| Publish | not done |

Earlier notes in this README described a Linux/Wine setup. This repo is now
worked on macOS, where Studio runs natively; the Wine login bug is moot here.
