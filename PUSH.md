# Getting DEAD ZONE into Roblox Studio

The code is written and syntax-clean (all 8 Luau modules pass `luau-compile`).
It cannot be *run* until Roblox Studio is authenticated — see step 0.

## Step 0 — the only gate

Studio must be signed in to a Roblox account. Until then the MCP servers
expose no tools and Rojo cannot attach. Two ways to finish the login:

```bash
# A) interactively, in the Chromium window Studio already opened
#    (click the dashboard's Computer tab to take control of the desktop)

# B) non-interactively, from the dashboard Terminal tab:
WINEPREFIX=/data/home/.local/share/grapejuice/prefixes/studio wine reg add \
  "HKCU\Software\Roblox\RobloxStudioBrowser\roblox.com" /v .ROBLOSECURITY \
  /t REG_SZ /d "<your .ROBLOSECURITY cookie>" /f
```

## Step 1 — pick a push path

### Path A: Rojo (recommended — syncs the whole tree)

```bash
# install rojo
cargo install rojo                        # or download a release from GitHub
```

Drop the Rojo plugin into Studio's plugins folder, then:

```bash
cd /data/workspace/deadzone
rojo serve                               # default port 34872
```

In Studio: Plugins → Rojo → Connect. Every file in `src/` lands in the right
place in the DataModel, mapped by `default.project.json`.

### Path B: MCP (no Rojo needed)

Hermes already has the `roblox-mcp` server connected. Once Studio is logged in
and the plugin is connected:

```
create_object / set_script_source / set_property
```

The module → target mapping:

| Local file | Studio target |
|---|---|
| `ReplicatedStorage/Shared/Config.luau` | `ReplicatedStorage.Shared.Config` (ModuleScript) |
| `ServerScriptService/Server/GameServer.luau` | `ServerScriptService.Server.GameServer` (Script) |
| `ServerScriptService/Server/PlayerManager.luau` | `…Server.PlayerManager` (ModuleScript) |
| `ServerScriptService/Server/ZoneManager.luau` | `…Server.ZoneManager` (ModuleScript) |
| `ServerScriptService/Server/ZombieAI.luau` | `…Server.ZombieAI` (ModuleScript) |
| `ServerScriptService/Server/AIDirector.luau` | `…Server.AIDirector` (ModuleScript) |
| `ServerScriptService/Server/WeaponService.luau` | `…Server.WeaponService` (ModuleScript) |
| `StarterPlayer/StarterPlayerScripts/ClientController.luau` | `StarterPlayer.StarterPlayerScripts.ClientController` (LocalScript) |

## Step 2 — build the map

The code references world geometry by tag, so the map can be blocked out fast.
In `Workspace → DeadZone`:

```
Zones/<zoneId>/
    a Part named anything, Attribute Role = "SpawnPoint"
    a Part named anything, Attribute Role = "Extraction"   (last zone only)
Gates/<zoneId>/
    any BasePart — the gate the squad interacts with
Loot/
    Parts with Attribute Role = "Pickup" and Attribute Kind = "Medkit"|"Pills"|"AmmoPile"|…
```

Zone ids must match `Config.Zones[*].Id`: `suburbs`, `hospital`, `mall`, `base`.

A greybox with four flat parts tagged as spawn points is enough to playtest the
whole loop. Art comes later.

## Step 3 — press play

`Roblox-mcp` exposes `start_stop_play`, `get_console_output`, `screen_capture`,
`user_keyboard_input` and `user_mouse_input`, so once it's live I can launch a
playtest, watch the output log, screenshot the viewport and drive a character —
then fix whatever breaks.

## Known issues to hit first

- **No GPU.** The viewport renders through llvmpipe. Expect slow, but the
  simulation is server-side and unaffected.
- **`ActivateZone` expects tagged parts.** If the map is empty, spawning and
  gate logic no-op rather than error — check output for that.
- **`--!strict`** is on everywhere. The type checker will flag real problems
  that `luau-compile` can't see; run `luau-analyze` with Roblox global
  definitions once the definitions file is available.
- **Untested at runtime.** This code has never executed. First playtest is a
  debug session, not a validation.

## Verification status

| Check | Result |
|---|---|
| `luau-compile` syntax, all 8 modules | ✅ clean |
| `default.project.json` JSON | ✅ valid |
| Roblox type analysis | ⚠️ needs Roblox global definitions |
| Runtime | ❌ not executed — blocked on login |
