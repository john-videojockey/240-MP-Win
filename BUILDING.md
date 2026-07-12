# Building 240-MP for Windows

If you are interested in building your own version of 240-MP and adding things to it then this page covers what you need to get an environment set up. If you create a feature you would like to contribute back, please open a PR.

## Prerequisites (one-time)

**Visual Studio 2022 or later** with the *Desktop development with C++* workload (the Community edition is fine). This provides MSVC, CMake, and Ninja — no separate CMake install needed.

**Qt 6.10+ (MSVC x64).** Either the [Qt Online Installer](https://www.qt.io/download-open-source) or, much lighter, [aqtinstall](https://github.com/miurahr/aqtinstall) from any Python:

```powershell
pip install aqtinstall
python -m aqt install-qt windows desktop 6.10.3 win64_msvc2022_64 -O C:\Qt
```

**SDL2 (gamepad input — build-time dependency).** The prebuilt VC development package is all you need:

```powershell
irm https://github.com/libsdl-org/SDL/releases/download/release-2.32.10/SDL2-devel-2.32.10-VC.zip -OutFile $env:TEMP\sdl2.zip
Expand-Archive $env:TEMP\sdl2.zip C:\Qt\SDL2
```

**OpenSSL 3 (MSVC x64).** Used by the Plex module for Ed25519 device tokens (Windows CNG doesn't offer Ed25519, which is why this is a dependency at all). Qt distributes prebuilt binaries:

```powershell
python -m aqt install-tool windows desktop tools_opensslv3_x64 -O C:\Qt
```

**mpv (runtime only — required for playback).** 240-MP launches mpv as a subprocess; it is not linked at build time:

```powershell
winget install shinchiro.mpv
```

…or drop a portable `mpv.exe` into `<repo>\mpv\` — the app checks that folder first (the folder is gitignored).

**yt-dlp (runtime, optional — YouTube module only):** `winget install yt-dlp.yt-dlp`. The YouTube module also expects `youtube_subscriptions.txt` and/or `youtube_playlists.txt` in the data directory — see the [upstream wiki](https://github.com/anthonycaccese/240-MP/wiki/Module:-YouTube).

## Get the source

```powershell
git clone https://github.com/anthonycaccese/240-mp-win.git
cd 240-mp-win
```

## Build & run

The all-in-one dev script (configures on first run, builds, runs):

```powershell
.\scripts\run-local.ps1               # build + run
.\scripts\run-local.ps1 -BuildOnly    # just build
.\scripts\run-local.ps1 -Reconfigure  # wipe the CMake cache first
```

If your dependencies aren't in the default `C:\Qt\...` locations, pass `-QtDir/-Sdl2Dir/-OpenSslDir` or set the `QT_DIR/SDL2_DIR/OPENSSL_DIR` environment variables.

Or by hand from a *Developer PowerShell for VS* prompt:

```powershell
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release `
    -DCMAKE_PREFIX_PATH="C:\Qt\6.10.3\msvc2022_64;C:\Qt\SDL2\SDL2-2.32.10" `
    -DOPENSSL_ROOT_DIR="C:\Qt\Tools\OpenSSLv3\Win_x64"
cmake --build build

.\build\240mp.exe    # or double-click it
```

The build runs `windeployqt` as a post-build step, so `build\240mp.exe` is directly runnable — no PATH setup needed. (The exe finds the repo's QML by walking up from its own folder; set `APP_ROOT` only to point it somewhere else.) `Ctrl+Q` quits.

## Configuration

All user configuration is stored at:

```
%APPDATA%\240-MP\
  config.json       ← app and module settings
  plex_auth.json    ← plex auth
  input.cfg         ← optional gamepad mapping overrides (see Gamepad input below)
  logs\240mp.log    ← app log (see Debugging below)
```

This directory is created automatically on first run. It is separate from the app itself, so deleting or rebuilding the app will not wipe your settings.

## Gamepad input (input.cfg)

USB game controllers should work out of the box: SDL's built-in controller database normalizes most pads (Xbox, PlayStation, 8BitDo, NES-style clones etc...) to a standard layout — on Windows this covers both XInput and DirectInput devices. 240-MP maps that standard layout to its navigation actions:

| Controller input | Action |
|---|---|
| D-pad / left stick | navigate (up / down / left / right) |
| A | select |
| B/Select | back |
| Start | play / pause |
| LB / RB shoulder buttons | left / right (seek during playback) |

Controllers can be hotplugged at any time and during playback the same buttons drive mpv (seek, pause, quit) exactly like their keyboard equivalents.

Controller input can be turned off entirely in **Settings → Controller Input** (useful for a pad with a stuck button or stick drift that navigates on its own). Keyboard input always works, so the setting can't lock you out; hotplug detection keeps running, so re-enabling takes effect immediately.

**Overriding the mapping**

- Create an `input.cfg` file in `%APPDATA%\240-MP`.
- Add one binding per line, `<input> <action>`;
- Use `#` to start a comment, data is case-insensitive and you only need to include the things you want to change (anything not defined will fall back to defaults)
- The file is live-reloaded while the app runs, so you can tune bindings without restarting.

Inputs use SDL controller names — short (`a`, `b`, `x`, `y`, `back`, `start`, `leftshoulder`, `rightshoulder`, `dpup`, `dpdown`, `dpleft`, `dpright`, ...) or the long `SDL_CONTROLLER_BUTTON_*` forms. Analog axes take a `+`/`-` direction suffix (`lefty-`, `triggerright+`). Actions: `up`, `down`, `left`, `right`, `select`, `back`, `play_pause`, and `none` to unbind a default.

**Button names are positional**, following an Xbox reference layout: `a` means the *south* face button, `b` east, `x` west, `y` north, no matter what's printed on your pad. You can also write the positions directly: `south`, `east`, `west`, `north`.

**Footer labels** adapt automatically to the controller you touched last (Nintendo-type pads show B at south, PlayStation pads show X/O/SQ/TR). If your controller reports the wrong type (common for pads with Nintendo-style labels running in XInput mode) you can force labels with a `label` line:

```
# input.cfg — example overrides
south                    select       # positions: south/east/west/north
SDL_CONTROLLER_BUTTON_A  select       # long names work
b                        back         # so do SDL short names ("b" = east)
x                        play_pause
rightshoulder            none         # unbind a default
lefty-                   up           # axes take a +/- suffix
triggerright+            play_pause
label south B                         # force the footer label for the south button
label east  A
```

Bad lines are skipped with a warning in the log (line number included).

**Exotic controllers** — if SDL doesn't recognize your pad at all, drop a community [gamecontrollerdb.txt](https://github.com/mdqinc/SDL_GameControllerDB) into `%APPDATA%\240-MP`; it is loaded at startup before controllers are opened.

## Video decode tuning (mpv_video_args)

On Windows 240-MP launches mpv with `--hwdec=auto-safe`, which selects D3D11VA hardware decode on any reasonably modern GPU and falls back to software decode when unavailable. The video output stays on mpv's default (`gpu-next`), which renders through the D3D11 swapchain — crop/zoom always works.

**Overriding the decode flags**

If you need to tune for your hardware, add an `mpv_video_args` string under `"app"` in `config.json`. It accepts a space-separated list of mpv flags that replaces the flags 240-MP sets:

```json
{
  "app": {
    "mpv_video_args": "--hwdec=d3d11va --d3d11-adapter=1"
  }
}
```

This config is read at each playback event, so a change applies on the next playback (no rebuild or restart needed). Only set video-output/decode flags here; the app owns the rest (the IPC control channel, OSC, input). For other mpv preferences (deinterlace, cache, subtitle styling...) create a standard `%APPDATA%\mpv\mpv.conf` — mpv reads it automatically every launch, and everything the app doesn't set on the command line is yours to configure there.

## Debugging & logs

240-MP builds as a GUI-subsystem app, so there is no console by default. Logs are always written to:

```
%APPDATA%\240-MP\logs\240mp.log     (rotated to 240mp.prev.log at ~1 MB)
```

Run the exe from a terminal and the same log lines print there too (the app attaches to the parent console).

### mpv playback logs

During playback the app hands off to mpv as a subprocess (see [ARCHITECTURE.md → Playback Hand-off](ARCHITECTURE.md#playback-hand-off-mpvcontroller)). `MpvController` writes mpv's own output to `%TEMP%\240mp-mpv.log` — useful when a video won't play or transcoding misbehaves.

### Testing the playback hand-off without mpv

`tests\mock-mpv\` contains a scripted mpv stand-in that serves the `\\.\pipe\240mp-mpv` IPC pipe, streams position updates for ~8 s, then reports a natural end-of-file. Copy both files into `<repo>\mpv\` and the app will pick it up as "mpv"; delete the folder to go back to the real player. Its log lands in `%TEMP%\mock-mpv.log`.

### Qt / QML debugging knobs

```powershell
$env:QT_LOGGING_RULES = "qt.qml.*=true"   # verbose QML engine logging
$env:QML_IMPORT_TRACE = "1"               # trace QML import resolution
```

Set them before launching from the same terminal.

## GitHub Actions

### How to trigger a build

Releases are built automatically when you push a version tag:

```powershell
git tag v2026.07.12
git push origin v2026.07.12
```

Pre-release tags (`-rc`, `-beta`, `-alpha`) are published as GitHub pre-releases.

### What the workflow does

| Job | Runner | Output |
|---|---|---|
| `build-windows-x64` | `windows-latest` | `240-MP-<tag>-windows-x64.zip` |

The job installs Qt via the Qt CDN, downloads the SDL2 VC devel package and Qt's OpenSSL tool, builds with MSVC + Ninja, stages the install, runs `windeployqt` to embed the Qt runtime (plus SDL2 and OpenSSL DLLs), and zips the folder. mpv is not bundled — the release's `install.ps1` installs it via winget.

A final `release` job creates a GitHub Release with the zip, a `SHA256SUMS` file (verified by both `install.ps1` and the in-app updater), and `install.ps1` itself attached.
