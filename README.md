# Valeera

A lightweight World of Warcraft addon that tracks **Valeera Sanguinar's companion XP** while you run Delves — time per run, XP gained, XP/min, loot drops, and projections for how many runs / how long until her next level.

The window **only appears while you are inside a Delve** and hides itself everywhere else.

## Leveling Valeera fast

Harldan's guide covers the current fastest method — farming **Mislaid Curiosities in The Grudge Pit**:

1. **Get Dundun's Favor** (utility curio). Complete any Delve (bountiful not required), loot the end chest for curios; enough runs unlocks it at rank 1. Rank doesn't matter — just having it equipped makes you auto-consume any Mislaid Curiosity you walk over, no clearing the room first.
2. **Push a Delve tier to 11 elsewhere.** Curiosity XP scales with Delve level, so run at T11. Easy pushes at time of recording: Gulf of Memory, Sporespecial, Shadowguard Point, Calamitous — they rotate daily.
3. **Enter The Grudge Pit at T11**, pan the camera, run over every curiosity you can find (~3k Valeera XP each for common; rare/epic ones drop more), then leave instantly with a leave-delve macro (Harldan pins his in the video comments) and repeat.

Notes from the video: no stealth or class needed, but Druid/Rogue makes it easier — watch for the venom-cursed mobs that sometimes spawn on top of curiosities. There's variance (some sweeps yield only two). Lower Valeera levels scale up faster; his napkin math is ~4 hours from 60 to 80 (the new cap). Other XP sources (end-of-delve, mob kills) were disabled in preseason; when they work again, Collegiate Calamity with the invasive-glow variant is usually the better XP/hour.

Use this addon's *Avg run* / *XP per minute* / *Time to level* lines to check your own rate.

▶ [Harldan — Fastest Valeera XP Farm (Grudge Pit curiosities)](https://www.youtube.com/watch?v=vX-RXiUGzso)

## Features

- **Portrait ring** — Valeera's portrait with a circular XP progress ring (fills from the bottom, clockwise) and a level badge, styled after the in-game companion panel.
- **Live run stats** — current Delve name + tier, elapsed time, companion level & % into level, XP gained this run, XP per minute, XP to next level.
- **Projections** — average run time and XP (last 10 XP-yielding runs), estimated runs to level, estimated time to level.
- **Loot tracking** — counts of uncommon / rare / epic items you loot per run and all-time.
- **Persistent history** — every completed run is saved to `ValeeraDB` (SavedVariables) so stats survive logout.
- **Last-run summary** shown when no run is active.
- **Configurable** — options panel under *Options → AddOns → Valeera*: show/hide window, lock position, show/hide portrait, font size, and a checkbox for every data line.

## Installation

### Manual

1. Download the latest release ZIP (or clone this repo).
2. Extract so you end up with this folder structure:

   ```
   World of Warcraft\_retail_\Interface\AddOns\Valeera\
       Valeera.toc
       Valeera.lua
   ```

   The folder **must** be named `Valeera` (matching `Valeera.toc`).
3. Launch WoW (or `/reload` if already logged in).
4. On the character select screen click **AddOns** and make sure *Valeera* is enabled. If it shows as *out of date*, tick **Load out of date AddOns**.

Default WoW paths:

| OS | Path |
|---|---|
| Windows | `C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns\` |
| macOS | `/Applications/World of Warcraft/_retail_/Interface/AddOns/` |

### From a clone (Windows, PowerShell)

```powershell
git clone https://github.com/johnrogers101a/valeera.git
$dst = "C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns\Valeera"
New-Item -ItemType Directory -Force $dst | Out-Null
Copy-Item .\valeera\Valeera.toc, .\valeera\Valeera.lua $dst -Force
```

## Usage

Just enter a Delve — the window appears automatically and a run starts. Leaving the Delve (or completing the scenario) ends the run, prints a summary to chat, and saves it to history.

Drag the window to move it (unless *Lock window position* is on).

### Slash commands

| Command | Effect |
|---|---|
| `/valeera` | Toggle the *Show window* option |
| `/valeera options` | Open the options panel |
| `/valeera reset` | Discard the current run and restart timing |
| `/valeera history` | Print the last 10 runs to chat |
| `/valeera clearhistory` | Wipe saved run history / stats |
| `/valeera faction <id>` | Pin the companion reputation faction ID (only if auto-detect fails) |

## How it works

- **Delve detection** — `C_PartyInfo.IsDelveInProgress()`, falling back to scenario instance type + Delve difficulty ID 208.
- **Companion XP** — read from Valeera's friendship reputation (`C_GossipInfo.GetFriendshipReputation`); the faction ID is auto-resolved by name.
- **Tier** — scraped from the Delve difficulty picker dropdown when you select a tier (approach borrowed from [this r/wowaddons thread](https://www.reddit.com/r/wowaddons/comments/1s0zilk/valeera_xp_gain_tracking)).
- **Loot** — `CHAT_MSG_LOOT` events for your own character, bucketed by item quality.

## Screenshots

Tracker window (idle, showing last-run stats):

![Tracker window](https://raw.githubusercontent.com/johnrogers101a/valeera/main/docs/tracker.png)

Live run — the ring fills from the bottom clockwise as Valeera gains XP:

![Tracker in a delve](https://raw.githubusercontent.com/johnrogers101a/valeera/main/docs/tracker-in-delve.png)

Chat summary printed when a run ends:

![Chat summary](https://raw.githubusercontent.com/johnrogers101a/valeera/main/docs/chat-summary.png)

Options panel (*Options → AddOns → Valeera*):

![Options panel](https://raw.githubusercontent.com/johnrogers101a/valeera/main/docs/options.png)

## License

MIT
