# WHIP Racing

Street racing for servers running the [WHIP](https://whipfx.net) framework: a racing tablet, custom tracks built in game, race lobbies with buy-ins and pink slips, vehicle classes, records with ghost replays, daily rewards and crews.

> **Unofficial resource.** WHIP Racing is a community-made resource by TrulyHydro, built on WHIP's public exports. It is **not** an official WHIP resource and is not made, endorsed or supported by WHIP or WHIPFX. Please don't take problems with it to WHIP's support; report them to the resource's author. "WHIP" is used here only to say what it works with.

Runs on FiveM Legacy and GTA V Enhanced.

## 1. Install

You need **whip_core** and **oxmysql** (both already part of a WHIP server). There is no ox_lib, ox_inventory or target dependency: WHIP provides the inventory, money, vehicles, notifications and permissions.

1. Keep the resource folder named `whip-racing`.
2. Add it to `server.cfg` **after** WHIP's lines:

```cfg
ensure oxmysql
ensure whip_core
# ... the rest of WHIP ...
ensure whip-racing
```

3. Start the server. That's it: **there is no SQL to import.** On start, WHIP Racing creates its tables (`whip_racing_*`) itself, keeping any rows already there.

Optional: import `sql/tracks-data.sql` once to add the supplied tracks.

> **Do not run `sql/install.sql` on a live server.** It is only for a manual fresh install and it deletes existing tracks and clears their records. You don't need it on WHIP.

## 2. Configure

Edit these two files, then restart `whip-racing`:

| File | What to change |
| --- | --- |
| `config/config.lua` | Permissions, race limits, payments, checkpoint props and rewards |
| `config/vehicle_classes.lua` | Which vehicles belong to S, A, B, C and D |

Start with these settings in `config/config.lua`:

| Setting | Purpose |
| --- | --- |
| `Config.Framework` | `auto` picks WHIP when whip_core is running. Leave it on `auto` |
| `Config.MoneyAccount` | `cash` (WHIP banknotes the player carries) or `bank` (their default WHIP account) for buy-ins, payouts and crew fees |
| `Config.CreatorWhitelist` | Who may create tracks; empty allows everyone |
| `Config.Admins` | Extra racing admins by identifier; empty grants nobody (see below) |
| `Config.Race` | Player limits, laps, countdown and finish deadline |
| `Config.Buyin` | Entry-fee limits, house share and payout splits |
| `Config.PinkSlips` | Vehicle stakes |
| `Config.DailyRewards` | Race milestones, rewards and daily reset time |

### Who is an admin

Racing admins can manage every track, cancel any race and attach item rewards to finishing places. A player is a racing admin if **any** of these is true:

- They are a full WHIP admin: the `whip.devtools` ACE with developer mode on (`/w`).
- They hold the **Racing admin** permission (`whip-racing.admin`). Give or take it in `/whip` → Players → Player Manager → the player → Permissions. It works at once, with no restart.
- They have the `whipracing.admin` ACE in `server.cfg`.
- Their identifier is in `Config.Admins`. On WHIP a player's id here is their **charId** (the character's id, shown in the Player Manager), or a full `license:...` identifier for the account.

The `whipracing.editor` ACE gives editor access: editing and deleting other players' tracks.

```lua
Config.Admins = {
    'license:YOUR_LICENSE_HERE',
    -- '42',   -- a WHIP charId, as text
}
```

### Enable or disable commands

Set any entry to `false` in `Config.Commands`, then restart the resource:

```lua
Config.Commands = {
    tablet = true,       -- /racing and its key binding
    editor = true,       -- /raceeditor
    cancelRace = true,   -- /cancelrace (admin only)
    trackList = true,    -- racing:tracks (console only)
    trackDump = true,    -- racing:dump (console only)
    publishAll = true,   -- racing:publishall (console only)
}
```

`Config.Command` and `Config.CreatorCommand` set the tablet and editor command names. Another client resource can open the tablet with:

```lua
exports['whip-racing']:openTablet()
```

### Vehicle classes

Move or add vehicle spawn names inside the existing class lists:

```lua
S = {
    'adder',
    'zentorno',
},
```

Use each vehicle name once. Addon vehicles work the same way. Unlisted vehicles show as **Unclassified** and can enter unrestricted races only.

`Config.AllowedClasses` uses GTA's numeric vehicle categories. It is separate from the S/A/B/C/D lists; leave it empty to allow all GTA categories.

### Checkpoint props

Road flares are the default:

```lua
checkpointprop = 'flares',
```

To use cones or another installed prop, change these lines inside `Config.Gates`:

```lua
checkpointprop = 'prop',
prop = 'prop_roadcone02a',
```

Flares use the stock red effect; their smoke and flame colours are not configurable. `flare.scale` changes their size.

### Money, rewards and pink slips

- **Money is WHIP's.** Buy-ins are charged with WHIP's `ChargePlayer` and payouts paid with `PayPlayer`, in cash or bank per `Config.MoneyAccount`. Every payment shows in WHIP's activity log under `whip-racing`.
- **The `racing_case` item is registered automatically**, with its picture; there is nothing to add to an items file. Daily rewards default to one case at 2, 5 and 8 completed races, reset on US Eastern time. Keep the tiers in increasing order.
- **Item rewards go into the WHIP inventory.** If a player's pockets are full the reward is not dropped; they're told, and a daily case stays claimable until they free a slot.
- **Admins can attach item rewards** to finishing places when creating a race, picked from every item WHIP knows.
- **Pink slips use WHIP's vehicles.** A racer can only stake a car they own and are sitting in. When the race ends, every staked car goes to the winner with a key. The loser's keys in their pockets are taken, but a key left in the ignition still works (that's how WHIP's transfer behaves).
- Collision ghost modes and record replays are different settings. Keep the order of `Config.GhostModes` unchanged because the tablet uses the same order.

## 3. Open the tablet

Use **`/racing`**. Players can assign a key under **Settings > Key Bindings > FiveM**.

## 4. Race

1. Open **Race lobbies** and create a race.
2. Select a route, then choose laps, vehicle classes, entry fee and other rules.
3. Other racers join the lobby in their vehicles. The host starts the race.
4. View results in the tablet's recent races list.

Leaving your vehicle does **not** remove you from a race. Return to the driver's seat to continue through checkpoints. To quit, open the tablet and select **Leave race**.

The timer continues while you are out of the vehicle. The finish deadline still applies after the first racer finishes.

Profile statistics count completed races. Money Made means payouts received, not profit after entry fees. Average Place rounds to a whole position, such as **1st** or **2nd**. Elo scoring is not implemented.

Crew creation, browsing, ownership and owner deletion are supported. `Config.CrewCreateMoney` defaults to 5000 and is charged from `Config.MoneyAccount`; use 0 for free creation. Names and tags must be unique. Membership invitations, custom roles, crew scoring and crew battles are not implemented yet.

## 5. Build a track

1. Open the track creation screen in the tablet and select **Track Editor**.
2. Drive the route and place at least three checkpoints.
3. Press **Enter** to return to the tablet.
4. Set the track name, type and visibility, then select **Save**.

| Key | Action |
| --- | --- |
| E | Place checkpoint |
| Backspace | Undo last checkpoint |
| Mouse wheel | Select checkpoint |
| Left / Right or Page Up / Page Down | Adjust checkpoint width |
| G | Teleport to selected checkpoint |
| Delete | Delete selected checkpoint |
| Tab | Switch between checkpoints and scenery props |
| Left Alt | Toggle mouse control |
| F1 | Hide editor panel |
| Enter | Return route to tablet |

`/raceeditor` opens the editor directly. Run it again to leave without saving. Scenery models available in the editor are listed in `Config.Props.catalogue`.

## How it uses WHIP

For anyone reading the code: every message from a player's game is checked by WHIP before the handler runs. The tablet's calls are WHIP `SecureCallback`s, and race progress, finishing and dropping out are `SecureEvent`s, with rate limits, typed values, and a loaded, living character required by default. Refused calls show in `/whip` → System → **Monitor** with the reason. The few ox_lib calls the original code used are answered by `shared/lib_shim.lua`, and `shared/bridge.lua` holds every WHIP call in one place.

## Troubleshooting

| Problem | Check |
| --- | --- |
| Tablet does not open | Check `whip-racing` is started after WHIP in `server.cfg`, and look for red lines in the server console and F8 |
| A tablet button does nothing | `/whip` → System → Monitor lists every `whip-racing:` call and why one was refused (for example "Player is dead" or a rate limit) |
| Checkpoints show only a column, with no distance | F8 says `scaleform ... did not load`. The beam movies stream when you connect: make sure `whip-racing` is running, then fully disconnect and rejoin |
| Vehicle shows Unclassified | Add its spawn name to `config/vehicle_classes.lua`, then restart the resource |
| Cannot create tracks or reach admin tools | Check the admin rules above: the Racing admin permission, developer mode, or `Config.Admins` |
| Daily reward cannot be claimed | The player's pockets are full: free a slot and redeem again |
| "Unknown command" for /racing | The resource isn't started, or `Config.Commands.tablet` is false |
| Flares stay red | Expected: flare colour customisation is not supported |

## UI files

The screens wear WHIP's own look: its colours, fonts (Barlow, with Bricolage Grotesque for titles) and shapes come straight from whip_core's design tokens, so a WHIP theme reaches the racing UI too.

- WHIP styling layer: `web/whip-theme.css`
- Racing tablet: `web/tablet.css` and `web/tablet.js`
- HUD, countdown and editor: `web/style.css`
- Checkpoint beam and distance readout: `web/dui/`
- World marker and beam colours: `Config.Colors` in `config/config.lua` (WHIP's Signal Blue)

Keep `web/app.js`, `web/dui`, the fonts and the map tiles; the HUD, checkpoint beams and route previews use them.

## Other frameworks

The code still carries its adapters for Qbox, QB-Core, the Hydro framework and standalone. To run it without WHIP, put `'@ox_lib/init.lua'` back at the top of `shared_scripts` in `fxmanifest.lua` (the WHIP shim then steps aside), remove the `whip_core` dependency and satellite line, set `Config.Framework`, and import `sql/install.sql` for the tables. That setup isn't what this copy is maintained for.

## Credits

WHIP Racing by TrulyHydro. Built for, not by, [WHIP](https://whipfx.net). Uses WHIP's public exports and loads `@whip_core/lib/satellite.lua` from whip_core; no WHIP files are copied into this resource.
