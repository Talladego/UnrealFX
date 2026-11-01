# UnrealFX

UT-style kill announcer + world-attached TGA overlays for Return of Reckoning.

Based on **[UnrealDBAnnouncer](https://forums.returnofreckoning.com/viewtopic.php?t=32918)**
by **ztil** and **Wholdar**. UnrealFX keeps the kill-log + external sound helper idea
and adds world-attached FX overlays, a Python/PyInstaller watcher, and related alert baggage.

## Install

1. Place this folder in `Interface\AddOns\UnrealFX`
2. Enable **UnrealFX** in the addon list (disable **UnrealDBAnnouncer** if both are installed)
3. Start the sound helper: run `UnrealFX.exe` (or `python UnrealFX.py`)  
   Window title is `UnrealFX` — bind that in OBS Application Audio Capture  
   `StartRoR.cmd` prefers `UnrealFX.exe` when present
4. In-game: `/ufx help`

Requires [LibSlash](https://www.curseforge.com/) (or whatever ships with your UI pack).

### Rebuild `UnrealFX.exe`

From this folder (needs Python + pip):

```bat
build_exe.cmd
```

Uses PyInstaller one-file / windowed. Stdlib only (`tkinter`, `winsound`).

## Slash

| Command | Purpose |
| --- | --- |
| `/ufx help` | Command help |
| `/ufx fx <name> [grow\|spin\|spiral]` | Test overlay (optional motion) |
| `/ufx fx scale [n\|reset]` | Overlay scale |
| `/ufx alerts …` | Toggle alerts (see below) |
| `/ufx play <keyword>` | Play a WAV keyword |
| `/ufx list` | Known keywords |

Also registered as `/unrealfx`.

## How sound works

- The addon appends a keyword to `logs\UnrealFX.log`
- `UnrealFX.exe` (or `UnrealFX.py`) watches that log and plays `files\<keyword>.wav`
- Replace any shipped WAV to customize a keyword

## Alerts

Toggles: `/ufx alerts [readycheck|scenario|fortress|lotd|defeat|pve|embrace|fetch] [on|off|toggle]`

Core scope is kill announcer VO + corpse FX (including optional defeat / PVE). The rest
(ready check, scenario, fortress, LoTD, getoverhere / Embrace / Fetch) are kept as
optional baggage for now — useful, but not the product focus.

| Alert | Default | Sound | Scope |
| --- | --- | --- | --- |
| Ready check / bio | on | `files\readycheck.wav` | baggage |
| Scenario pop (+ window flash) | on | `files\notify.wav` | baggage |
| Fortress reservation | on | `files\fortressreservation.wav` | baggage |
| Land of the Dead ticket | on | `files\lotdticket.wav` | baggage |
| Defeat (your death) | **off** | `files\defeat.wav` | core (optional) |
| PVE kills (`You have slain …!`) | **off** | same deathblow pool as RvR; only while not RvR-flagged; ignores pets | core (optional) |
| Terrible Embrace (Marauder 40) | **off** | `files\getoverhere.wav` | baggage |
| Fetch! (White Lion 40) | **off** | `files\getoverhere.wav` | baggage |

## Shipped WAVs

### Deathblow (fixed)

| Keyword | File | When |
| --- | --- | --- |
| `firstblood` | `files\firstblood.wav` | First kill in a streak |
| `doublekill` | `files\doublekill.wav` | Second kill within 5s |

### Deathblow (normal pool, after >5s since last kill)

| Keyword | File |
| --- | --- |
| `annihilation` | `files\annihilation.wav` |
| `erradication` | `files\erradication.wav` |
| `extermination` | `files\extermination.wav` |
| `godlike` | `files\godlike.wav` |
| `headshot` | `files\headshot.wav` |
| `dominating` | `files\dominating.wav` |
| `denied` | `files\denied.wav` |
| `wickedsick` | `files\wickedsick.wav` |

### Deathblow (multi-kill pool, 3rd+ within 5s)

| Keyword | File |
| --- | --- |
| `bloodbath` | `files\bloodbath.wav` |
| `holyshit` | `files\holyshit.wav` |
| `killingspree` | `files\killingspree.wav` |
| `ludicrous` | `files\ludicrous.wav` |
| `megakill` | `files\megakill.wav` |
| `monsterkill1` | `files\monsterkill1.wav` |
| `monsterkill2` | `files\monsterkill2.wav` |
| `multikill` | `files\multikill.wav` |
| `rampage` | `files\rampage.wav` |
| `slaughter` | `files\slaughter.wav` |
| `unstoppable` | `files\unstoppable.wav` |

### Manual only

| Keyword | File |
| --- | --- |
| `triplekill` | `files\triplekill.wav` |
| `ultrakill` | `files\ultrakill.wav` |

## Assets / rebuild helpers

| Path | Notes |
| --- | --- |
| `files\*.tga` | Display-sized (456×256) RLE overlays |
| `files\*.wav` | Announcer clips |
| `files\make_tga_alpha.py` | TGA writer (RLE type 10) |
| `files\make_tga_456.py` | Resize full-res sources → 456×256 |
| `files\png_to_tga.py` | PNG/JPEG → TGA |
| `files\sync_fx_assets.py` | Regenerate XML/Lua texture tables from `files\*.tga` |
