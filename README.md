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
lune run tests/run.luau
```

Both need [Rojo](https://rojo.space) and [Lune](https://lune-org.github.io).
Version pins are not vendored here — install current releases of both.

The suite runs the **real** modules against a mock Roblox API, so it covers
logic without needing Studio:

- Director: stress model, phase machine, spawn budget, stress cap
- PlayerManager: damage, heal, down, bleed-out, revive, temp HP
- WeaponService: ammo consumption, fire-rate anti-cheat, shove cooldown

## What's missing

- **No map.** The code expects parts tagged `Role = "SpawnPoint"` and
  `Role = "Extraction"` under `Workspace.DeadZone.Zones` / `.Gates` / `.Loot`.
  Until those exist, zones, gates and loot no-op. See PUSH.md.
- **No engine playtest.** The 30 checks run against a mock, not the real
  engine — no physics, real camera, or pathfinding.
- **`ClientController` and `GameServer` are untested** at runtime.
- **No publish.** Publishing needs either Roblox Studio (blocked on Linux by a
  Wine auth bug) or an Open Cloud API key, which routes around Studio.

## Roblox Studio on Linux

Studio's browser-login handoff is broken under Wine here: the second Studio
process launched by the `roblox-studio-auth://` handler detects the original
(`Running instance count at launch 1`) but always fails
`sendExternalPKCEInfo because the original authenticating Studio is closed`.
This is a confirmed upstream Wine bug. WebView2 also cannot be installed under
Wine.

There is no native Linux Studio. Alternatives are a Windows VM, dual boot, or a
remote Windows box. See PUSH.md for the Rojo and MCP paths that work once
Studio is reachable.

## Verification

| Check | Result |
|---|---|
| `luau-compile` syntax, all modules | pass |
| `rojo build` | pass |
| `lune run tests/run.luau` | 30/30 pass |
| Roblox engine playtest | not run |
| Publish | not done |
