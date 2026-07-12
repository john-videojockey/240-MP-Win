# 240-MP Architecture

240-MP is a retro VCR-style media app built with **C++ Qt6 + QML** — this repository targets **Windows 10/11 x64** (the [upstream project](https://github.com/anthonycaccese/240-MP) covers Raspberry Pi and macOS). This is the reference for working on 240-MP's code (whether you're adding a new module or changing an existing one). 

If you just want to install or build the app, see [INSTALL.md](INSTALL.md) and [BUILDING.md](BUILDING.md). 

If you want to contribute, please start with [CONTRIBUTING.md](CONTRIBUTING.md).

## Philosophy

Think of 240-MP as a **browsing shell** that hands off to **purpose-built tools**.

- The app shell handles browsing, auth, and settings
- **Modules** are self-contained media integrations (Local Files, Plex, Ambient Mode, etc...) that the shell discovers and loads at startup.
- When a user picks something to play, the shell hands off to a dedicated fullscreen tool and resumes when that tool exits. For video, that tool is **mpv**, launched as a subprocess by `MpvController`. mpv is installed separately (`winget install shinchiro.mpv`, or bundled in `<app folder>\mpv\`).  240-MP does not link against libmpv.

The guiding idea: **browse structured content, then hand off to the right tool for the job** rather than bundling everything into one binary.

## Project Structure

```
240-mp/
  src/                              # C++ source
    main.cpp                        # app entry point — engine setup, context properties, registerModule calls
    AppCore.h / AppCore.cpp         # app shell: module registry, config r/w, settings routing
    modules/                        # per-module C++ backends
      local_files/
        LocalFilesBackend.h/.cpp
      plex/
        PlexBackend.h/.cpp          # good reference backend implementation
      ...
    player/
      MpvController.h/.cpp          # mpv subprocess controller: QProcess launch + IPC socket
  modules/                          # QML + assets per module (discovered at startup)
    plex/
      manifest.json                 # module identity and settings shape
      assets/images/logo.svg
      views/
        Root.qml                    # module router (required)
        ...
    local_files/
    ...
  views/                            # app-level QML
    ModuleList.qml
    Settings.qml
    ...
    Components/                     # shared QML components (AppBar, qmldir)
  Main.qml                          # app root
  CMakeLists.txt
```

There are three modules today: `local_files`, `plex`, and `ambient_mode`. `plex` is a helpful reference when building something new as it covers a more complex use case (connecting to a 3rd party API with auth)

## Anatomy of a Module

A module has up to three parts:

| Part | Location | Required? |
|---|---|---|
| `manifest.json` | `modules/<name>/manifest.json` | **Yes** — read by `AppCore` at startup |
| QML views | `modules/<name>/views/` (entry point `Root.qml`) | **Yes** |
| C++ backend | `src/modules/<name>/<Name>Backend.h/.cpp` | Optional |

`AppCore` scans `modules/*/manifest.json` at startup. A module that needs **no backend** (pure QML) requires **no C++ changes at all** — drop in the folder and it's discovered. A module that needs a backend adds one `registerModule(...)` call in `main.cpp` (see [AppCore](#appcore--the-app-shell)).

```
modules/<name>/
  manifest.json             # identity + settings
  assets/images/logo.svg    # logo for the module / single color `#ffffff` to enable color schemes to re-color
  views/
    Root.qml                # module router (entry point)
    Items.qml               # list view
    Detail.qml              # detail/leaf view
```

## manifest.json Reference

Loaded at startup by `AppCore` — the single source of truth for a module's identity and settings. No C++ changes are needed to add or modify settings.

```json
{
  "id": "com.240mp.<name>",
  "name": "<DISPLAY NAME>",
  "icon": "assets/images/logo.svg",
  "entry_point_qml": "views/Root.qml",
  "settings": [ ... ]
}
```

### Setting types

| `type` | Description | Extra fields |
|---|---|---|
| `toggle` | ON/OFF toggle | `default: "ON"` or `"OFF"` |
| `list_single` | Single-select list | `options_source`, `options_slot`, `apply_slot` |
| `multiselect_submenu` | Multi-select list via submenu | `options_source`, `options_slot` |
| `directory_browser` | Keyboard-navigable directory picker | `default` (path string, may be empty) |
| `action` | Button that calls a backend slot | `action_slot` |

Additional fields any setting may carry:

- `key` — the config key written under `modules.<id>.<key>` in `config.json`. Supports dot-notation.
- `label` — display text in Settings.
- `requires_auth` — if `true`, the setting is only shown when the module reports an authenticated state via `get_module_auth_state(moduleId)`. Used by Plex to hide server/user/library settings until sign-in.

### Dynamic options and apply slots

- For `list_single` / `multiselect_submenu` with `"options_source": "dynamic"`, the backend slot named by `options_slot` must emit `dynamicOptionsReady(key, [{id, label}])`. `AppCore` re-emits it to QML with the module ID prepended.
- For `list_single` with `apply_slot`, that slot is called automatically (routed through `invoke_module_action`) when the user changes the value.

A real example (Plex) — note `requires_auth`, dynamic options, and apply slots:

```json
{
  "key": "server_machine_id",
  "label": "Server",
  "type": "list_single",
  "options_source": "dynamic",
  "options_slot": "getServers",
  "apply_slot": "applyCurrentServerSetting",
  "requires_auth": true
}
```

## AppCore — the App Shell

`AppCore` (`src/AppCore.h/.cpp`) is the shell. It's exposed to all QML as the context property **`appCore`**.

**Global context properties** (available in all QML): `appCore`, `mpvController`, plus one per module backend (`localFilesBackend`, `plexBackend`, `ambientModeBackend`, …). Backend names are assigned by the `registerModule` call in `main.cpp`.

### Q_INVOKABLE slots used by QML

| Slot | Purpose |
|---|---|
| `scan_for_modules()` | Emits `modulesLoaded` with enabled modules |
| `get_settings()` | Returns entire `config.json` as a map |
| `get_setting(moduleId, key)` | Returns a single setting value |
| `save_setting(moduleId, key, value)` | Writes to `config.json`; supports dot-notation keys |
| `get_module_info(moduleId)` | Returns `{name, icon}` for a module |
| `get_module_settings_schema(moduleId)` | Returns the module's settings array |
| `invoke_module_action(moduleId, slotName)` | Routes to the registered backend via `QMetaObject::invokeMethod` |
| `get_module_auth_state(moduleId)` | Returns the module's auth state (for `requires_auth` settings) |
| `getCustomColorScheme()` | Returns the user's custom color scheme |
| `listDirectories(path)` / `parentDirectory(path)` / `homePath()` | Helpers for `directory_browser` |

### Signals

`modulesLoaded`, `appSettingChanged`, `moduleSettingChanged(moduleId, key, value)`, `dynamicOptionsReady(moduleId, key, options)`, `moduleAuthStateChanged(moduleId)`.

### registerModule — wiring a backend in

Backends are wired in from `main.cpp` with a single call:

```cpp
YourBackend yourBackend(appRoot, dataRoot);   // construct with whatever args the ctor needs

appCore.registerModule("com.240mp.<name>", "yourBackend", &yourBackend, ctx);
```

`registerModule(moduleId, contextProperty, backend, ctx)` does everything: it stores the backend for `invoke_module_action` routing, exposes it to QML under `contextProperty`, and connects the backend's optional signals/slots **by introspection** — each is wired only if the backend actually declares it, so there are no per-capability lambdas:

| Backend member (if declared) | Auto-connected to |
|---|---|
| signal `dynamicOptionsReady(QString, QVariant)` | re-emitted as `appCore.dynamicOptionsReady(moduleId, key, options)` |
| signal `authStateChanged()` | re-emitted as `appCore.moduleAuthStateChanged(moduleId)` |
| slot `onSettingChanged(QString, QString, QVariant)` | `appCore.moduleSettingChanged(moduleId, key, value)` |

The module ID lives in exactly one place per module — this call. Declare these members with the exact signatures above and `registerModule` wires them with no other changes to `main.cpp`.

## Playback Hand-off (MpvController)

The current MPV implementation is a good reference implementation of the "browse & hand-off" philosophy. When a module decides to play a video, it hands off to **mpv** rather than rendering video itself. All of that lives in `MpvController` (`src/player/MpvController.h/.cpp`), exposed to QML as the context property **`mpvController`**.

### How the hand-off works

1. **Launch** — `loadAndPlay(url, startSeconds, audioTrack, subTrack, ...)` starts mpv as a `QProcess`. Playback parameters are passed as mpv command-line flags: `--start=<sec>` (resume offset), `--playlist-start=<n>`, `--loop-playlist=inf`, and so on. mpv is found on `PATH` — the app never links libmpv.
2. **Control channel** — mpv is started with `--input-ipc-server=<pipe>` (the Windows named pipe `\\.\pipe\240mp-mpv`). `MpvController` connects to it with a `QLocalSocket` (which speaks named pipes natively on Windows) and sends JSON commands via `sendCommand(QJsonArray)`. `seekTo()` and `sendKey()` (which sends mpv a `keypress` command) go over this channel — that's how the USB remote / keyboard drives mpv's OSC while it's fullscreen.
3. **State back to QML** — `MpvController` issues `observe_property` for `time-pos`, `duration`, and `playlist-pos`, and re-publishes them as `Q_PROPERTY`s + the `positionChanged` / `durationChanged` / `playlistPosChanged` signals. A watchdog timer logs a warning if no `time-pos` event arrives for ~10 s (freeze detection).
4. **Exit** — when mpv quits, `MpvController` emits a single signal, **`playbackEnded(finalPos, finalDur, reason)`**, where `reason` is one of:
    - `"eof"` — the file played to its natural end. What happens next is the module's call: most just return to the menu.  For example: Plex may autoplay the next episode (based on the user's autoplay setting, and fall back to a normal return when there is no next episode, e.g. a movie or the last episode of a season).
    - `"stopped"` — the user quit/stopped before the end (also the safe default for a crash/kill with no end-file event). Record the resume position and return.
    - `"failed"` — mpv exited with code 2 (file couldn't be played). A module may attempt recovery first.  For example: Plex retries with transcoding — otherwise it just returns.

    **The baseline for every module to keep in mind:** by the time `playbackEnded` fires, mpv has already exited, so a handler that returns without either calling `goBack()` or starting fresh playback (`loadAndPlay`, e.g. in an autoplay/retry scenario) will leave the now-defunct Player view focused over a dead subprocess which will cause the app to freeze. So please handle the one signal, then branch on `reason` only where you have special behavior, and make sure no branch falls through.

### Video decode flags

Upstream carries an elaborate per-Raspberry-Pi decode-profile system (reading `/proc/device-tree/model`, choosing DRM planes per board). None of that exists on Windows; `appendVideoArgs()` collapses to one line:

| Target | Video flags |
|---|---|
| Windows 10/11 x64 | `--hwdec=auto-safe` |

`auto-safe` selects **D3D11VA** hardware decode on any reasonably modern GPU (falling back to software decode when unavailable), and the video output stays on mpv's default (`gpu-next`), which renders through the D3D11 swapchain. Because frames always pass through the scaler on this path, crop/zoom (`--panscan`, the OSC CROP button) works everywhere — the Pi 3's smoothness-vs-crop trade-off (and its `smooth_playback` setting) doesn't apply and is hidden in Settings via `hasSmoothPlaybackTradeoff()` returning `false`.

Advanced users can override the flags with the app-level `mpv_video_args` setting in `config.json` (a space-separated flag string under `"app"`, e.g. `"--hwdec=d3d11va --d3d11-adapter=1"` to pin a GPU); it is read at each launch, so changes apply on the next playback without a rebuild.

### How mpv flags are layered (the precedence cascade)

Every flag mpv receives belongs to one of a few layers, and the model that keeps them straight is a single precedence cascade where each layer can only override what the layers above it didn't nail down:

I think of it like this:
```
app constants → 
  app per-playback → 
    device decode (user-overridable in config) → 
      %APPDATA%\mpv\mpv.conf
```

| Layer | Examples | Owner | Where |
|---|---|---|---|
| **App constants** | `--input-ipc-server`, `--input-conf`, `--osc`, `--script`, `--log-file` | App only | command-line |
| **App per-playback** | `--start`, `--aid`, `--sub-file`, `--http-header-fields` (stream URL, tokens) | App only | command-line |
| **Device decode** | `--hwdec` | App default; user may override via `mpv_video_args` | command-line |
| **User prefs** | `deinterlace`, `cache`, `sub-scale`, profiles | User | `mpv.conf` |

- The first three layers are app-owned and the first two are load-bearing because they wire the IPC control channel and the input/OSC bridge. Changing them would break functionality in the app, not just playback, so they are never user-overridable. The 3rd layer (*device decode*) allows a direct user path to override video decode settings if per device tweaks are needed.
- And all app layers are command-line, so they all win over `mpv.conf`. The app passes no `--no-config`, so mpv reads `%APPDATA%\mpv\mpv.conf` on launch, which means users can add anything the app doesn't set explicitly directly in their mpv config.

### Custom OSC (Lua)

The on-screen controls mpv shows during playback are custom Lua scripts in `scripts/` (`mpv-osc.lua` for normal playback, `ambient-osc.lua` for Ambient Mode), loaded via mpv's `--script=` flag. Options are passed in with `--script-opts=` (e.g. `transcode-offset=<sec>`). The remote's key events reach these scripts through the `keypress` IPC bridge described above.

`mpv-osc.lua` is also mouse/touch-driven (Plex-app style): the controls appear on pointer movement or a tap and hide after 3 s of stillness or a tap outside them. It draws a title line (from `--force-media-title`, passed per-playback by the module), a click-to-seek bar, and `|<` / `PLAY|PAUSE` / `>|` / `AUDIO` / `SUBTITLE` / `CROP` / `STOP` buttons. One `layout()` function computes every rectangle for both drawing and click hit-testing so they can't drift apart. Touch taps arrive as a cursor move immediately followed by a click, so a click within 0.4 s of the controls appearing is consumed as part of the reveal gesture — controls only take input from a separate, later tap. `>|` runs `playlist-next` when an mpv playlist is loaded; otherwise, when the app opted in with `--script-opts-append=episode-nav=1`, it sends the `episode-nav` client-message, which `MpvController` re-emits as `episodeNavRequested` — the Plex Player answers it by swapping to the next episode in place (same machinery as autoplay). `|<` restarts the current item. The keyboard/remote flow (UP/DOWN opens, arrows + ENTER navigate, 5 s timeout) is unchanged.

### The screen hand-off on Windows

The window manager does the heavy lifting: mpv opens its own fullscreen window over the app's borderless fullscreen window and takes OS focus; when mpv exits, focus falls back to the app. (Upstream's Raspberry Pi build needs an elaborate KMS/DRM + virtual-terminal hand-off here because there is no display server on RPi Lite — all of that machinery was dropped from this port.) While mpv holds focus the Qt window can't receive key events, so gamepad input reaches mpv through `InputManager`'s IPC bridge instead — see [Input](#input-inputmanager).

### Adding a different hand-off target

The longer-term vision is to hand off to *other* purpose-built tools (e.g. RetroArch), not just mpv. `MpvController` is the template for that: launch the external tool as a `QProcess`, drive it over whatever control channel it offers, and surface progress/exit back to QML via signals.

## Input (InputManager)

All input arrives in QML as **ordinary key events** — views bind `Keys.onPressed` / `Keys.onUpPressed` / etc. and never know which physical device produced the event. Keyboards and keyboard-emulating USB remotes deliver real key events natively; **USB game controllers** are translated by `InputManager` (`src/input/InputManager.h/.cpp`, exposed to QML as the context property **`inputManager`**). **Touch/mouse taps** ride the same rail: view delegates carry small `MouseArea`s that either move the list highlight directly or call `inputManager.touchKey("select"/"back"/…)`, which posts the corresponding synthesized key — so a tap runs exactly the keyboard handler it mirrors (two-tap pattern: first tap highlights, second tap activates). A floating **◄ BACK** chip in `Main.qml` provides the Escape equivalent everywhere.

**Please don't add gamepad-specific handling to a view** — if a view handles the right keyboard keys then with this setup it will also handle gamepads.

### How it works

1. **SDL2 GameController** — `SDL_Init(SDL_INIT_GAMECONTROLLER)` only (no video subsystem). On Windows SDL wraps XInput and DirectInput behind one API, which is why the port kept SDL2 instead of switching to Windows.Gaming.Input (that would silently drop older DirectInput pads). A 16 ms `QTimer` on the main thread polls SDL events: hotplug (`CONTROLLERDEVICEADDED/REMOVED`), buttons, and axes. SDL's built-in controller database normalizes most pads to a standard layout, so defaults "should" work out of the box. The `SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS` hint keeps controller input flowing while mpv's window holds OS focus during playback.
2. **Buttons → actions → key events** — each SDL input maps to one of seven named actions below, and each action synthesizes one Qt key. Button identities are **positional** (using an Xbox reference layout — `SDL_HINT_GAMECONTROLLER_USE_BUTTON_LABELS` is forced off so Nintendo-type pads behave the same): `a` is always the south face button and input.cfg accepts `south`/`east`/`west`/`north` aliases to try to make it easier to wrap my head around =)

   | Action | Qt key | Default binding |
   |---|---|---|
   | `up` / `down` / `left` / `right` | arrows | D-pad, left stick, LB/RB (left/right) |
   | `select` | Return | A |
   | `back` | Escape/Backspace | B, Select |
   | `play_pause` | Space | Start |

3. **Delivery** — while the Qt window is **active**, synthesized `QKeyEvent`s are posted to the root QQuickWindow and reach the QML `activeFocusItem` like real key presses. When the window is **inactive** (fullscreen mpv holds OS focus during playback) a QQuickWindow has no `activeFocusItem`, so `InputManager` instead emits `mpvKeyRequested(key)`, which `main.cpp` connects to `MpvController::sendKey`. That drives mpv directly over IPC with the same key names — the net result is that gamepads drive mpv identically to the keyboard whether the app or mpv owns the screen. Held directions auto-repeat (400 ms delay, 100 ms interval) so lists and ff/rw feel like keyboard repeat.
4. **User overrides** — `$DATA_ROOT/input.cfg` (`<input> <action>` per line, `#` comments, merged over defaults, live-reloaded via `QFileSystemWatcher`). An optional `$DATA_ROOT/gamecontrollerdb.txt` can add SDL mappings for exotic pads. Check out grammar and examples in [BUILDING.md → Gamepad input](BUILDING.md#gamepad-input-inputcfg). The app-level `controller_input` setting (Settings → Controller Input, wired in `main.cpp` via `appSettingChanged` → `setControllerInputEnabled`) ignores all button/axis events while Off — hotplug tracking keeps running so re-enabling is immediate, and keyboard input is untouched.
5. **Adaptive footers** — `inputManager` exposes `lastInputDevice` (`"keyboard"` | `"gamepad"`, tracked via an app-wide event filter that ignores the synthesized events by their magic `nativeScanCode`) and a `hints` map (`back`, `select`, `navigate`, `change`, `browse`, `play_pause`). Main.qml mirrors it as **`root.hints`**, and footer hint labels bind to that — e.g. `root.hints.back + ":BACK"` renders `[ESC]:BACK` while the keyboard is active and `[B]:BACK` after a controller press, reflecting the live mapping. Views should bind to `root.hints.*` (similar to how we handle `root.sh`), **not** `inputManager.hints.*` because id-resolved `root.*` will stay valid when swappig views.  If you don't when the module Loader swaps views, the dying view's context properties will resolve to null and bindings on them will throw TypeErrors during teardown. Face-button labels are translated to what's printed on the **last-touched** controller via `SDL_GameControllerGetType` (Nintendo swaps A/B & X/Y; PlayStation shows X/O/SQ/TR), and `label <button> <text>` lines in input.cfg override them for pads that misreport their type. New views with footers should now use `root.hints.*`, and not hardcoded `[ESC]`/`[ENTER]` strings like I had in my previous implementation.

## C++ Backend Patterns

Backends are `QObject` subclasses registered via `registerModule(...)` before the engine loads.
Please review `PlexBackend` as a reference implementation.

- All HTTP via `QNetworkAccessManager` — async, on the main thread, no worker threads needed.
- Results returned to QML via signals.
- Auth/state persisted to JSON files in the data dir.
- `Q_INVOKABLE` for slots called from QML; `signals:` for callbacks to QML.
- For dynamic settings dropdowns, emit `dynamicOptionsReady(key, [{id, label}])` — auto-connected; `AppCore` re-emits with the module ID prepended.
- For auth-gated modules, emit `authStateChanged()` on sign-in/out — auto-connected and re-emitted as `moduleAuthStateChanged(moduleId)`.
- To react to your own settings changing, add a slot `onSettingChanged(moduleId, key, value)` — auto-connected to `moduleSettingChanged`.
- A backend resolves its own configured paths in its constructor — e.g. `LocalFilesBackend` / `AmbientModeBackend` read `media_directory` from `config.json` (defaulting to `dataRoot/media` / `dataRoot/ambient`). `main.cpp` does not touch module paths.

## QML View Patterns

### Root.qml — module router

Every module requires `Root.qml` as its entry point. It owns the internal nav stack and handles exiting back to the module list.

```qml
import QtQuick

FocusScope {
    id: moduleRoot

    signal goBack()

    property var navParams: ({})

    // must match your manifest id
    property var _moduleInfo: appCore ? appCore.get_module_info("com.240mp.<name>") : ({})
    property string moduleName: _moduleInfo.name || ""
    property string moduleIcon: _moduleInfo.icon || ""

    property var navStack: []
    property var currentParams: ({})

    function navigateTo(viewPath, params, fromState) {
        var resolved = Qt.resolvedUrl(viewPath)
        navStack.push({ source: internalLoader.source, params: currentParams, listState: fromState || {} })
        currentParams = params || {}
        internalLoader.setSource(resolved, { "navParams": params || {} })
    }

    function navigateBack() {
        if (navStack.length === 0) {
            moduleRoot.goBack()
            return
        }
        var prev = navStack.pop()
        if (!prev.source || prev.source.toString() === "") {
            moduleRoot.goBack()
            return
        }
        var restored = Object.assign({}, prev.params)
        restored.navListState = prev.listState || {}
        currentParams = restored
        internalLoader.setSource(prev.source, { "navParams": restored })
    }

    Loader {
        id: internalLoader
        anchors.fill: parent
        focus: true
        onLoaded: { if (item) item.forceActiveFocus() }

        Connections {
            target: internalLoader.item
            ignoreUnknownSignals: true
            function onNavigateTo(path, params, listState) { moduleRoot.navigateTo(path, params, listState) }
            function onGoBack() { moduleRoot.navigateBack() }
        }
    }

    Component.onCompleted: navigateTo("Items.qml", {})
}
```

**Rules:**
- `id` is always `moduleRoot`.
- `moduleName` / `moduleIcon` always come from `appCore.get_module_info(...)` — never hardcoded.
- `goBack()` is the only signal that leaves the module — child views never emit it directly.
- `navigateBack` merges `navListState` back into params on pop so list views can restore position.
- For auth flows that need `replaceWith` (navigate without pushing to the stack), please see the Plex module as a reference.

### Items.qml — list view

```qml
import QtQuick
import Components

FocusScope {
    id: itemsRoot

    property var navParams: ({})
    property var navListState: navParams.navListState || ({})

    signal navigateTo(string path, var params, var listState)
    signal goBack()

    focus: true
    Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace) {
            goBack()
            event.accepted = true
        }
    }

    AppBar {
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.125
        anchors.leftMargin: root.sw * 0.125
        iconSource: moduleRoot.moduleIcon
        title: moduleRoot.moduleName
    }

    ListView {
        id: itemList
        anchors.topMargin: root.sh * 0.25
        anchors.leftMargin: root.sw * 0.115625

        // restore list position on back-navigate
        Component.onCompleted: {
            var restore = navListState.currentIndex !== undefined ? navListState.currentIndex : 0
            currentIndex = Math.min(restore, Math.max(0, count - 1))
            positionViewAtIndex(currentIndex, ListView.Contain)
        }

        Keys.onReturnPressed: {
            navigateTo("Detail.qml", { item: model[currentIndex] }, { currentIndex: currentIndex })
        }
    }
}
```

### Detail.qml — leaf view

```qml
import QtQuick
import Components

FocusScope {
    id: detailRoot

    property var navParams: ({})

    signal goBack()

    focus: true
    Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace) {
            goBack()
            event.accepted = true
        }
    }

    AppBar {
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.125
        anchors.leftMargin: root.sw * 0.125
        iconSource: moduleRoot.moduleIcon
        title: moduleRoot.moduleName
        subtitle: navParams.item || ""
    }
}
```

**View rules:**
- Always declare `property var navParams: ({})` — the router passes params via `Loader.setSource`.
- List views also declare `property var navListState: navParams.navListState || ({})` and restore position in `Component.onCompleted`.
- `navigateTo` always takes 3 args: `(path, params, listState)` — pass `{ currentIndex: listView.currentIndex }` as listState when pushing to a detail view.
- Leaf views only need `signal goBack()` — no `navigateTo`.
- Use `root.sh` / `root.sw` for all margins and sizes — never hardcoded pixels. This keeps layouts responsive across CRT (240p/480i, watch overscan) and HDMI/LCD.
- Access shared state via `moduleRoot.moduleName`, `moduleRoot.moduleIcon`.
- Navigate via signals — never call router functions directly.

## Components (WIP)

Shared QML components live in `views/Components/` (registered via `qmldir`, imported as `import Components`).

### AppBar (`views/Components/AppBar.qml`)

| Property | Type | Description |
|---|---|---|
| `iconSource` | `url` | Module icon — use `moduleRoot.moduleIcon` |
| `title` | `string` | Module name — use `moduleRoot.moduleName` |
| `subtitle` | `string` | Optional context label (hidden when empty) |

The icon is automatically colorized to the app accent color

## Config Storage

User configuration is stored in `config.json` in the app's data directory:

```json
{
  "app": { "color_scheme": "Video 1" },
  "modules": {
    "com.240mp.plex": { "enabled": true, "server_machine_id": "...", ... }
  }
}
```

Each module's settings live under `modules.<id>`. Use `save_setting` / `get_setting` (which support dot-notation keys) rather than writing the file directly. The data directory (`%APPDATA%\240-MP`) is created on first run and is separate from the app itself, so rebuilding or updating never wipes user settings. See [BUILDING.md](BUILDING.md#configuration).
