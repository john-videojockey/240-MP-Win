# Install 240-MP on Windows

Requirements: Windows 10 21H2 or later (Windows 11 recommended), x64.

## Option 1 — install script (recommended)

Open **PowerShell** (no admin needed) and run:

```powershell
irm https://github.com/john-videojockey/240-MP-Win/releases/latest/download/install.ps1 | iex
```

The script:

1. Installs the runtime helpers via winget (falling back to scoop or chocolatey): **mpv** (playback), **yt-dlp** (YouTube module) and **ffmpeg** (Local Files extra thumbnails).
2. Downloads the latest release zip, verifies its SHA-256 checksum, and installs it to `%LOCALAPPDATA%\Programs\240-MP`.
3. Creates a Start Menu shortcut.

> **Execution policy?** The one-liner pipes the script straight into PowerShell (`| iex`), so a restrictive execution policy **does not apply** — nothing is saved or run as a `.ps1` file. That's why it's the recommended form.

### Passing options

Wrap the same download in a script block so it stays execution-policy-free while taking arguments:

```powershell
& ([scriptblock]::Create((irm https://github.com/john-videojockey/240-MP-Win/releases/latest/download/install.ps1))) -Autostart
```

| Switch | Effect |
|---|---|
| `-Autostart` | also start 240-MP automatically at logon |
| `-SkipDeps` | don't install/touch mpv, yt-dlp or ffmpeg |
| `-SkipUpscalers` | don't download the upscaler shaders |
| `-InstallDir <path>` | install somewhere other than `%LOCALAPPDATA%\Programs\240-MP` |
| `-Uninstall` | remove the app + shortcuts (your settings survive) |

(If you prefer to download `install.ps1` and run it as a file, an execution policy that blocks unsigned scripts will stop it — use `powershell -ExecutionPolicy Bypass -File .\install.ps1 -Autostart`, or just use the script-block form above.)

> The per-user install location is what lets the in-app updater (Settings → Update)
> swap in new versions without a UAC prompt. If you move the app somewhere that
> needs admin rights (e.g. Program Files), self-update falls back to showing you
> the downloaded zip for a manual swap.

## Option 2 — manual

1. Install mpv: `winget install shinchiro.mpv` (or grab a build from [mpv.io/installation](https://mpv.io/installation/) and put it on your PATH — **or** drop `mpv.exe` and its files into a `mpv\` folder inside the 240-MP folder; 240-MP checks there first).
2. Optionally install yt-dlp (YouTube module) and ffmpeg (Local Files extra thumbnails): `winget install yt-dlp.yt-dlp Gyan.FFmpeg`.
3. Download `240-MP-<version>-windows-x64.zip` from [Releases](https://github.com/john-videojockey/240-MP-Win/releases), extract it anywhere you like, and run `240mp.exe`.

## First run

- The app starts fullscreen. Navigate with **arrow keys / Enter / Esc** or a game controller (Xbox, PlayStation, 8BitDo… — hotplug works).
- **Ctrl+Q** quits from anywhere; there's also a Quit entry in Settings.
- Local Files looks for media in `%APPDATA%\240-MP-Win\media` by default — point it at your library in **Settings → Local Files → Media Directory** (you can browse to any drive).

## Where your data lives

| What | Where |
|---|---|
| App | `%LOCALAPPDATA%\Programs\240-MP` |
| Settings, auth, history | `%APPDATA%\240-MP-Win\` (`config.json`, `plex_auth.json`, …) |
| Logs | `%APPDATA%\240-MP-Win\logs\240mp.log` |
| Gamepad overrides | `%APPDATA%\240-MP-Win\input.cfg` ([details](BUILDING.md#gamepad-input-inputcfg)) |
| Your own mpv preferences | `%APPDATA%\mpv\mpv.conf` (read by mpv on every launch) |

Settings live outside the app folder, so updating or reinstalling never wipes them.

## Update

Use **Settings → Update** inside the app — it checks GitHub Releases, downloads, verifies, and swaps itself. Or re-run the install one-liner; or replace the folder with a newer zip by hand. All three end up in the same place.

## Uninstall

```powershell
irm https://github.com/john-videojockey/240-MP-Win/releases/latest/download/install.ps1 | iex; & "$env:TEMP\install.ps1" -Uninstall
```

…or simply download `install.ps1` and run `.\install.ps1 -Uninstall`, or delete `%LOCALAPPDATA%\Programs\240-MP` and the Start Menu/Startup shortcuts yourself. Delete `%APPDATA%\240-MP-Win` too if you want your settings gone.

## Raspberry Pi or macOS?

Use [upstream 240-MP](https://github.com/anthonycaccese/240-MP) — this repository only ships Windows builds.
