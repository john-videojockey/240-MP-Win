# Install 240-MP on Windows

Requirements: Windows 10 21H2 or later (Windows 11 recommended), x64.

## Option 1 — install script (recommended)

Open **PowerShell** (no admin needed) and run:

```powershell
irm https://github.com/john_videojockey/240-MP-Win/releases/latest/download/install.ps1 | iex
```

The script:

1. Installs **mpv** (the playback engine) and **yt-dlp** (used by the YouTube module) via winget — falling back to scoop or chocolatey if that's what you use.
2. Downloads the latest release zip, verifies its SHA-256 checksum, and installs it to `%LOCALAPPDATA%\Programs\240-MP`.
3. Creates a Start Menu shortcut.

Useful variations (download the script first for these):

```powershell
.\install.ps1 -Autostart      # also start 240-MP automatically at logon
.\install.ps1 -SkipDeps       # don't install/touch mpv or yt-dlp
.\install.ps1 -InstallDir D:\Apps\240-MP
.\install.ps1 -Uninstall      # remove the app + shortcuts (your settings survive)
```

> The per-user install location is what lets the in-app updater (Settings → Update)
> swap in new versions without a UAC prompt. If you move the app somewhere that
> needs admin rights (e.g. Program Files), self-update falls back to showing you
> the downloaded zip for a manual swap.

## Option 2 — manual

1. Install mpv: `winget install shinchiro.mpv` (or grab a build from [mpv.io/installation](https://mpv.io/installation/) and put it on your PATH — **or** drop `mpv.exe` and its files into a `mpv\` folder inside the 240-MP folder; 240-MP checks there first).
2. Optionally install yt-dlp for the YouTube module: `winget install yt-dlp.yt-dlp`.
3. Download `240-MP-<version>-windows-x64.zip` from [Releases](https://github.com/john_videojockey/240-MP-Win/releases), extract it anywhere you like, and run `240mp.exe`.

## First run

- The app starts fullscreen. Navigate with **arrow keys / Enter / Esc** or a game controller (Xbox, PlayStation, 8BitDo… — hotplug works).
- **Ctrl+Q** quits from anywhere; there's also a Quit entry in Settings.
- Local Files looks for media in `%APPDATA%\240-MP\media` by default — point it at your library in **Settings → Local Files → Media Directory** (you can browse to any drive).

## Where your data lives

| What | Where |
|---|---|
| App | `%LOCALAPPDATA%\Programs\240-MP` |
| Settings, auth, history | `%APPDATA%\240-MP\` (`config.json`, `plex_auth.json`, …) |
| Logs | `%APPDATA%\240-MP\logs\240mp.log` |
| Gamepad overrides | `%APPDATA%\240-MP\input.cfg` ([details](BUILDING.md#gamepad-input-inputcfg)) |
| Your own mpv preferences | `%APPDATA%\mpv\mpv.conf` (read by mpv on every launch) |

Settings live outside the app folder, so updating or reinstalling never wipes them.

## Update

Use **Settings → Update** inside the app — it checks GitHub Releases, downloads, verifies, and swaps itself. Or re-run the install one-liner; or replace the folder with a newer zip by hand. All three end up in the same place.

## Uninstall

```powershell
irm https://github.com/john_videojockey/240-MP-Win/releases/latest/download/install.ps1 | iex; & "$env:TEMP\install.ps1" -Uninstall
```

…or simply download `install.ps1` and run `.\install.ps1 -Uninstall`, or delete `%LOCALAPPDATA%\Programs\240-MP` and the Start Menu/Startup shortcuts yourself. Delete `%APPDATA%\240-MP` too if you want your settings gone.

## Raspberry Pi or macOS?

Use [upstream 240-MP](https://github.com/anthonycaccese/240-MP) — this repository only ships Windows builds.
