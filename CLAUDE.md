# 240-MP for Windows — Development Guidelines

240-MP is a retro VHS-style media app built with C++ Qt6 + QML. **This repository is the Windows port** of [anthonycaccese/240-MP](https://github.com/anthonycaccese/240-MP) (which targets Raspberry Pi and macOS). Modules are self-contained media integrations (Plex, Local Files, Ambient Mode, etc.) that the app shell discovers and loads at startup.

**Playback engine**: 240-MP launches **mpv** as a subprocess for video playback (`winget install shinchiro.mpv`, or drop mpv.exe into `<app folder>\mpv\`). The app handles all browsing, auth, and settings; when a video is selected it hands off to mpv fullscreen via `MpvController` (JSON IPC over the `\\.\pipe\240mp-mpv` named pipe), then resumes when mpv exits.

---

## Build & Run (Windows x64)

```powershell
# One command — configures (if needed), builds, and runs:
.\scripts\run-local.ps1

# Or by hand (see BUILDING.md for dependency setup):
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release `
    -DCMAKE_PREFIX_PATH="C:\Qt\6.10.3\msvc2022_64;C:\Qt\SDL2\SDL2-2.32.10" `
    -DOPENSSL_ROOT_DIR="C:\Qt\Tools\OpenSSLv3\Win_x64"
cmake --build build
$env:APP_ROOT = (Get-Location); .\build\240mp.exe
```

The app is a GUI-subsystem executable: logs always go to `%APPDATA%\240-MP\logs\240mp.log`, and additionally to the parent console **only when `MP240_CONSOLE=1`** is set (opt-in, so a launcher spawned from a shell doesn't get the logs dumped into that session; `run-local.ps1` sets it). `Ctrl+Q` quits.

---

## Where things live

This file stays intentionally lean. The detailed documentation is single-sourced elsewhere — read the relevant doc before working in an area rather than relying on memory:

| If you need… | Read |
|---|---|
| Architecture, module anatomy, `manifest.json` setting types, `AppCore` / `registerModule`, C++ backend patterns, input/gamepad handling (`InputManager`), QML view/navigation patterns, Components, config shape | **[ARCHITECTURE.md](ARCHITECTURE.md)** |
| How to contribute, project principles, best-practices checklist, adding/changing a module, testing, coding style | **[CONTRIBUTING.md](CONTRIBUTING.md)** |
| Building & running on Windows, CI/release workflow, config/data directory paths | **[BUILDING.md](BUILDING.md)** |
| End-user install (install.ps1, manual zip install, autostart) | **[INSTALL.md](INSTALL.md)** |

---

## Key facts to keep in mind

- **Modules are discovered from `modules/*/manifest.json`** at startup — a pure-QML module needs no C++ changes. A module with a backend adds **one** `registerModule(...)` call in `src/main.cpp`; that call is the single place the module ID is stated. (Details: [ARCHITECTURE.md → AppCore](ARCHITECTURE.md#appcore--the-app-shell).)
- **`registerModule` wires optional backend signals/slots by introspection** (`dynamicOptionsReady`, `authStateChanged`, `onSettingChanged`) — declare them with the exact signatures and no `main.cpp` changes are needed.
- **Every module's QML entry point is `Root.qml`** (the router). Views are `FocusScope`s that pass state via `navParams` and communicate via `navigateTo` / `goBack` signals. Size everything with `root.sh` / `root.sw`, never hardcoded pixels.
- **`PlexBackend` is the reference implementation** for backends.
- **Config** is `config.json` in `%APPDATA%\240-MP`; module settings live under `modules.<id>`. Use `save_setting` / `get_setting` (dot-notation supported), not direct file writes.
- **Gamepad input is centralized in `src/input/InputManager`** (SDL2) and arrives in QML as ordinary synthesized key events — never add gamepad-specific handling to views; if a view handles the right keys it handles gamepads. Footer hint labels bind to `root.hints.*` (adapts keyboard↔gamepad), never hardcoded `[ESC]`/`[ENTER]` strings and never `inputManager.hints.*` directly — context-property bindings throw TypeErrors when the view Loader tears down; id-resolved `root.*` is teardown-safe. (Details: [ARCHITECTURE.md → Input](ARCHITECTURE.md#input-inputmanager).)
- **Windows platform glue lives in `src/win_utils.cpp`** (file/console logging, display keep-awake, mpv/yt-dlp PATH discovery) — one call each from `main()`; keep new platform-specific code there, not scattered through backends.
- **`tests/mock-mpv/`** is a scripted mpv stand-in (named-pipe JSON IPC) — copy its two files into `<repo>\mpv\` to exercise the playback hand-off without a real mpv install; delete the folder afterwards.
