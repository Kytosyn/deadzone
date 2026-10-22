# DEAD ZONE — 4-player co-op zombie FPS for Roblox

## The pitch

Four players drop into a quarantined city and fight zone to zone. Scavenge,
survive hordes, hit the gate, move on. L4D2's combat DNA inside a GTA-style
session structure.

## Core loop

```
LOBBY (4 players, vote to start)
   │
   ▼
ZONE 1 ── scavenger ──► horde event ──► reach gate ──┐
ZONE 2 ── scavenger ──► horde event ──► reach gate ──┤
ZONE 3 ── scavenger ──► horde event ──► reach gate ──┤
ZONE 4 ── military base ──► Tank boss ──► EXTRACT ──┘
   │
   ▼
DEBRIEF (kills, money, next run)
```

The **gate is the saferoom**. It is a hard checkpoint: interact to open it, the
squad walks through, the door seals, the next zone activates. A player who is
down when the gate opens is auto-carried through.

## The two halves

**L4D2 core (built first, where the fun is)**

| System | What it does |
|---|---|
| AI Director | Spawns pressure based on player stress, not a timer |
| Common infected | Hordes that path toward noise and players |
| Special infected | Hunter, Smoker, Boomer, Charger, Tank |
| Horde events | Crescendo triggers (car alarm, generator, crescendo item) |
| Down / revive | Bleed-out timer, teammate revive, temp HP that decays |
| Pickups | Pills, adrenaline, medkit, ammo pile, weapon spawn |
| Melee shove | Push through a swarm without spending ammo |
| Friendly fire | On, always |

**GTA Online shell (phase 2, the big lift)**

Vehicles, money economy and buying at gates, DataStore-persisted profiles,
matchmaking. Deliberately out of MVP.

## Zone plan

| Zone | Setting | Size | Signature |
|---|---|---|---|
| 1 | Suburban streets | small | Tutorial pacing, one Hunter |
| 2 | Hospital | medium | Boomer in the wards, dark interiors |
| 3 | Shopping mall | medium-large | Charger in the open atrium, 2 crescendos |
| 4 | Military base | large | Tank boss, extraction point |

Each zone has: spawn points, nav targets, loot spawns, one gate, one crescendo
trigger, and a danger rating that feeds the Director.

## AI Director design

L4D2's Director is the reason the game feels alive. This is a simplified but
genuine version.

**Stress model** — every player has a stress value 0→100 built from:
- recent damage taken (+)
- zombies currently targeting them (+)
- time since their last hit (−)
- sprinting / firing / noise events (+)

Squad stress = average. The Director maps stress to a **spawn budget** and a
**horde cooldown**.

**Phases per zone**
1. *Build* — low, sparse spawns. Let them scavenge.
2. *Sustain* — trickle special infected.
3. *Relax* — near-silence after a horde. Breather.
4. *Crescendo* — the zone's scripted horde event.

The Director never spawns during *Relax*, always spawns during *Crescendo*, and
in between spends its budget proportionally to stress. It also tracks a
**mob counter** — if common infected are dying faster than they spawn, it
pours them in.

**Special infected** have their own cadence: one every N seconds per zone,
capped alive at once, weighted toward types the zone favours.

## Special infected

| Type | Behaviour | Counter |
|---|---|---|
| Hunter | Crouches, then pounces from range; pins a player | Shoot mid-leap, or shove |
| Smoker | Hides at range, tongue-grabs a player and reels them in | Shoot the tongue, kill the Smoker |
| Boomer | Slow, fat, approaches; on death vomits bile | Keep distance — bile summons a horde |
| Charger | Winds up, then rushes in a line, carrying a player | Sidestep, shoot the arm |
| Tank | Boss. Massive HP, ground slam AoE, throws debris | Whole squad focus fire, kite |

## Player systems

- **Health** 100, temp HP from pills that decays. Medkit restores, bandage
  stops bleed-out only.
- **Down-but-not-out** at 0 HP: 30s bleed-out, crawl, can be revived. Revived
  at 10 HP with a short invulnerability.
- **Loadout**: primary rifle (hitscan, limited ammo), pistol (infinite, weak),
  melee shove. Ammo is a real constraint — the Director knows when you're dry.
- **Money** from kills and zone clears; phase 2 turns it into purchases.

## MVP scope (what gets built first)

4-player private server, one map, 4 zones, full L4D2 combat core, gates,
down/revive, 5 special infected, HUD, crescendo triggers. **No vehicles, no
persistence.**

## File layout

```
default.project.json                  Rojo project → synced into Studio
src/
  ReplicatedStorage/Shared/
    Config.luau                       every tuning number in one place
  ServerScriptService/Server/
    GameServer.luau                   lobby → zones → debrief, main loop
    ZoneManager.luau                  zone activation, gates, extraction
    AIDirector.luau                   stress model + spawn budget
    ZombieAI.luau                     common + special infected behaviours
    PlayerManager.luau                health, down/revive, loadout, money
    WeaponService.luau                hitscan, ammo, melee shove
  StarterPlayer/StarterPlayerScripts/
    ClientController.luau             FPS camera, HUD, input, prompts
```

## Status

Code is written and **syntax-clean** (all 8 Luau modules pass `luau-compile`).
It is **not yet run** — Roblox Studio needs an authenticated account before
anything can be pushed in or played.

## Verification

| Check | Result |
|---|---|
| `luau-compile` syntax, all 8 modules | ✅ clean |
| `default.project.json` | ✅ valid JSON |
| `luau-analyze` semantic | ⚠️ 49–93 findings per file, all "Unknown global `game` / `require` path" — the analyzer lacks Roblox's global definitions, so these are expected, not real errors. `Config.luau` (no Roblox globals) is fully clean. |
| Runtime | ❌ never executed — blocked on login |

See `PUSH.md` for how to get it into Studio once the account is signed in.
