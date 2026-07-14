import QtQuick
import QtQuick.Controls
import QtQuick.Window

Window {
    id: root
    // Borderless window covering the whole screen — the Windows equivalent of
    // the kiosk-style fullscreen the app uses everywhere. mpv opens its own
    // fullscreen window on top of this one during playback. The minimize hint
    // lets the taskbar button and the on-screen chip minimize it despite the
    // missing title bar.
    flags: Qt.FramelessWindowHint | Qt.Window | Qt.WindowMinimizeButtonHint
    x:      Screen.virtualX
    y:      Screen.virtualY
    width:  Screen.width
    height: Screen.height
    visible: true
    color: root.surfaceColor

    // --- Color Schemes ---
    readonly property var themes: ({
        "Video 1": {
            "primary": "#FFFFFF",
            "secondary": "#C2BFE4",
            "tertiary": "#8480C9",
            "surface": "#0A0094",
            "accent": "#AECFFF"
        },
        "Late Night": {
            "primary": "#FFFFFF",
            "secondary": "#A1A1A1",
            "tertiary": "#444444",
            "surface": "#000000",
            "accent": "#FFD900"
        },
        "Synthwave": {
            "primary": "#FFFFFF",
            "secondary": "#D48BFF",
            "tertiary": "#7836B5",
            "surface": "#12012B",
            "accent": "#00E5FF"
        },
        "Terminal": {
            "primary": "#4AF626",
            "secondary": "#32A81B",
            "tertiary": "#1A590E",
            "surface": "#000000",
            "accent": "#4AF626"
        },
        "T-120": {
            "primary": "#000000",
            "secondary": "#818181",
            "tertiary": "#df9c27",
            "surface": "#FAF5E8",
            "accent": "#EE442F"
        },
        "Amber": {
            "primary": "#FFB000",
            "secondary": "#B37B00",
            "tertiary": "#B37B00",
            "surface": "#000000",
            "accent": "#FFEE11"
        },
        "Kinescope": {
            "primary": "#FFFFFF",
            "secondary": "#9E9E9E",
            "tertiary": "#424242",
            "surface": "#121212",
            "accent": "#FFFFFF"
        },
        "SMPTE ECR 1-1978": {  // 75% max 0xFF == 0xBF, 40% max 0xFF == 0x66, 7.5% max 0xFF == 0x13; 75/7.5 targets per https://en.wikipedia.org/wiki/SMPTE_color_bars#Analog_NTSC - mixed with 40% in "off channels" to both wash out and improve contrast
            "primary": "#BFBFBF",
            "secondary": "#66BF66",
            "tertiary": "#6666BF",
            "surface": "#131313",
            "accent": "#BF6666"
        }
    })
    property var allThemes: themes  // may gain a "Custom" entry on startup
    property string currentTheme: "Video 1"
    property string primaryColor:   (allThemes[currentTheme] || allThemes["Video 1"]).primary
    property string secondaryColor: (allThemes[currentTheme] || allThemes["Video 1"]).secondary
    property string tertiaryColor:  (allThemes[currentTheme] || allThemes["Video 1"]).tertiary
    property string surfaceColor:   (allThemes[currentTheme] || allThemes["Video 1"]).surface
    property string accentColor:    (allThemes[currentTheme] || allThemes["Video 1"]).accent

    readonly property real sw: width
    readonly property real sh: height

    Connections {
        target: appCore
        function onAppSettingChanged(key, value) {
            if (key === "color_scheme") {
                root.currentTheme = value
            } else if (key === "screensaver_timeout") {
                var sec = parseInt(value)
                if (sec > 0) {
                    idleTracker.threshold = sec
                    idleTracker.enabled = true
                } else {  // "OFF"
                    idleTracker.enabled = false
                    if (screenSaverActive) screenSaverActive = false
                }
            }
        }
    }

    Component.onCompleted: {
        var cfg = appCore.get_settings()

        var cThemes = appCore.getCustomColorSchemes()
        if (Object.keys(cThemes).length > 0) {
            var t = Object.assign({}, themes, root.allThemes)
            for (var cTheme in cThemes) {
                if (Object.keys(cThemes[cTheme]).length === 5) {
                    t[cTheme] = cThemes[cTheme]
                }
            }
            root.allThemes = t
        }

        var custom = appCore.getCustomColorScheme()
        if (Object.keys(custom).length === 5) {
            var t = Object.assign({}, themes, root.allThemes)
            t["Custom"] = custom
            root.allThemes = t
        }

        var savedTheme = (cfg.app && cfg.app.color_scheme) || "Video 1"
        if (savedTheme === "Custom" && !root.allThemes["Custom"]) {
            appCore.save_setting("", "color_scheme", "Video 1")
            savedTheme = "Video 1"
        }
        root.currentTheme = savedTheme

        // Screensaver: the tracker starts disabled; this is the single place the
        // saved setting is applied (live changes land in onAppSettingChanged above,
        // mirroring color_scheme). parseInt("OFF") is NaN, so OFF stays disabled.
        var ssSec = parseInt(cfg.app && cfg.app.screensaver_timeout)
        if (ssSec > 0) {
            idleTracker.threshold = ssSec
            idleTracker.enabled = true
        }
    }
    
    FontLoader {
        id: font; source: "assets/fonts/VCR_OSD_MONO_1.001.ttf"
    }
    property string globalFont: font.name;

    // --- INPUT / APP INFO MIRRORS ---
    // Views must bind these via `root.*`, never the appCore/inputManager
    // context properties directly: when the module Loader swaps views, the
    // dying view's context properties resolve to null and any binding on them
    // throws a TypeError during teardown. id-resolved `root.*` stays valid
    // (root lives as long as the app), so these mirrors are teardown-safe.
    // The null guards absorb the same nulling here at app shutdown, when the
    // engine invalidates the root context itself.
    readonly property var hints: inputManager ? inputManager.hints : ({})
    readonly property string appVersion: appCore ? appCore.appVersion : ""

    // --- SCREEN SAVER STATE ---
    property bool screenSaverActive: false

    // --- APP-LEVEL NAV STACK ---
    property var appNavStack: []
    property var appCurrentParams: ({})
    property bool _startupNavigated: false

    // --- MPV PLAYBACK TRACKING ---
    // Block the screen saver while mpv is playing so it never flashes during or
    // immediately after playback. The core guard is in IdleTracker (mpvActive
    // property), which also resets the idle timer on transitions.
    //
    // Window marriage: mpv plays in its own fullscreen window, married to this
    // one at the Win32 level (MpvController/win_utils) so they share one taskbar
    // button and this window OWNS mpv's — which means this window must stay in a
    // normal (non-minimized) state behind mpv during playback; minimizing it here
    // would hide the owned player too. When a "minimize" is sent to mpv (it holds
    // OS focus) it reports window-minimized, and MpvController relays it as
    // onPlayerMinimizeRequested so we minimize the pair together via the owner.
    Connections {
        target: mpvController
        // idleTracker guards: these fire on mpv teardown too (e.g. Alt+F4 during
        // playback), when the context property is already null — id-resolved
        // root.* stays valid, but idleTracker.* would throw. Short-circuit on it.
        function onPositionChanged(ms) {
            if (ms > 0 && idleTracker && !idleTracker.mpvActive) {
                idleTracker.mpvActive = true
                idleTracker.resetActivity()
            }
        }
        function onPlaybackEnded(finalPositionMs, finalDurationMs, reason) {
            if (idleTracker) {
                idleTracker.mpvActive = false
                idleTracker.resetActivity()
            }
            // If the pair was left minimized when playback ended, restore the
            // menu and re-take OS focus so input routes back to QML.
            if (root.visibility === Window.Minimized)
                root.showNormal()
            root.raise()
            root.requestActivate()
        }
        // mpv was minimized (global minimize hotkey, etc.) — minimize the owner
        // so the whole composed window drops as one; the single taskbar button
        // restores both (onVisibilityChanged below brings the video back on top).
        function onPlayerMinimizeRequested() {
            if (idleTracker && idleTracker.mpvActive)
                root.showMinimized()
        }
    }

    // ---- Fullscreen geometry self-heal ----
    // The window's size/position are bound to Screen.* (top of file), but a
    // window-system resize — a display-mode change (a fullscreen game, monitor
    // sleep/wake, resolution switch) or an unusual minimize/restore — can break
    // those QML bindings and strand the window at 0x0: still "visible" and
    // pumping messages, but with nothing to render, which looks exactly like a
    // freeze/hang (and, mid-playback, leaves the owned mpv window unhidden — the
    // "split" symptom). These re-apply the fullscreen geometry imperatively so
    // the window can always recover; the guard keeps it from fighting a
    // deliberate minimize (a non-zero size in the Minimized visibility state).
    function _ensureFullscreen() {
        if (root.visibility === Window.Minimized || root.visibility === Window.Hidden)
            return
        if (root.x      !== Screen.virtualX) root.x = Screen.virtualX
        if (root.y      !== Screen.virtualY) root.y = Screen.virtualY
        if (root.width  !== Screen.width)    root.width = Screen.width
        if (root.height !== Screen.height)   root.height = Screen.height
    }

    // A display-mode change moves the Screen dimensions; re-apply so the window
    // tracks them even after its original Screen.* bindings have been broken.
    Screen.onWidthChanged:  root._ensureFullscreen()
    Screen.onHeightChanged: root._ensureFullscreen()

    // Last-resort watchdog for a total (0x0) collapse that no event caught. Acts
    // only on a zero-size *shown* window, so it can never disturb a legitimate
    // minimize (which is a non-zero size in the Minimized visibility state).
    Timer {
        interval: 2000; repeat: true; running: true
        onTriggered: {
            if (root.visibility === Window.Windowed
                    && (root.width <= 0 || root.height <= 0))
                root._ensureFullscreen()
        }
    }

    // Restoring the single taskbar button un-minimizes this owner window; heal the
    // geometry (in case the restore came back collapsed) and, while a video is
    // playing, bring mpv's window back on top with focus so the video returns
    // rather than the menu sitting in front of it. root.visibility is checked
    // first (id-resolved, teardown-safe); the context props are guarded because
    // this also fires as the window hides during app shutdown.
    onVisibilityChanged: {
        if (root.visibility === Window.Windowed)
            root._ensureFullscreen()
        // Keep the mpv window in lockstep with this (owner) window during
        // playback: minimize it with us and bring it back on restore, so the two
        // never split even if the owned-window marriage failed to take.
        if (idleTracker && mpvController && idleTracker.mpvActive) {
            if (root.visibility === Window.Windowed)
                mpvController.raisePlayer()
            else if (root.visibility === Window.Minimized)
                mpvController.minimizePlayer()
        }
    }

    // --- MODULE LOADER ---
    Loader {
        id: moduleLoader;
        anchors.fill: parent;
        focus: true;
        source: "views/ModuleList.qml";

        Keys.onPressed: (event) => {
            if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_Q) {
                Qt.quit()
            }
        }

        onLoaded: {
            item.forceActiveFocus()
            if (!root._startupNavigated) {
                root._startupNavigated = true
                var entryPoint = appCore.startupModuleEntryPoint()
                if (entryPoint) {
                    root.appNavStack.push({
                        source: moduleLoader.source,
                        params: root.appCurrentParams,
                        listState: {}
                    })
                    moduleLoader.setSource(entryPoint, { "navParams": {} })
                }
            }
        }

        Connections {
            target: moduleLoader.item
            ignoreUnknownSignals: true

            function onNavigateTo(path, params, listState) {
                root.appNavStack.push({ source: moduleLoader.source, params: root.appCurrentParams, listState: listState || {} })
                root.appCurrentParams = params || {}
                moduleLoader.setSource(path, { "navParams": params || {} })
            }

            function onGoBack() {
                if (root.appNavStack.length === 0) return
                var prev = root.appNavStack.pop()
                root.appCurrentParams = prev.params
                moduleLoader.setSource(prev.source, { "navParams": prev.params, "navListState": prev.listState || {} })
            }

        }
    }

    // --- TOUCH BACK + MINIMIZE BUTTONS ---
    // Floating Escape equivalent so touch users can always navigate back
    // (on the module list, where the footer documents back as Settings, it
    // opens Settings — same as the physical key). Views keep handling the
    // resulting key event exactly as if a keyboard or remote sent it.
    Rectangle {
        id: backChip
        visible: !screenSaverActive
        z: 100
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.topMargin: root.sh * 0.125 //60
        anchors.rightMargin: root.sw * 0.115625 //74
        width: backChipLabel.implicitWidth + root.sw * 0.025 //16
        height: root.sh * 0.0583333 //28
        color: "transparent"
        border.color: root.tertiaryColor
        border.width: Math.max(1, Math.floor(root.sh * 0.003125)) //2

        Text {
            id: backChipLabel
            anchors.centerIn: parent
            text: "◄ BACK"
            color: root.tertiaryColor
            font.family: root.globalFont
            font.pixelSize: root.sh * 0.0333333 //16
        }

        MouseArea {
            anchors.fill: parent
            anchors.margins: -root.sh * 0.0166667 // generous touch target
            onClicked: inputManager.touchKey("back")
        }
    }

    // Minimize chip beside BACK — the window is borderless, so this (and the
    // taskbar button) stand in for the missing title-bar control.
    Rectangle {
        visible: !screenSaverActive
        z: 100
        anchors.verticalCenter: backChip.verticalCenter
        anchors.right: backChip.left
        anchors.rightMargin: root.sw * 0.0125 //8
        width: height
        height: backChip.height
        color: "transparent"
        border.color: root.tertiaryColor
        border.width: Math.max(1, Math.floor(root.sh * 0.003125)) //2

        Text {
            anchors.centerIn: parent
            text: "_"
            color: root.tertiaryColor
            font.family: root.globalFont
            font.pixelSize: root.sh * 0.0333333 //16
        }

        MouseArea {
            anchors.fill: parent
            anchors.margins: -root.sh * 0.0166667
            onClicked: root.showMinimized()
        }
    }

    // --- SCREEN SAVER (Idle Tracker integration) ---
    Connections {
        target: idleTracker
        function onActiveChanged() {
            // Only show on active → true; never hide here — the overlay's
            // key handler owns dismissal, preventing the C++ event filter's
            // synchronous reset from stealing the key from QML.
            if (idleTracker.active && idleTracker.enabled) {
                if (!screenSaverActive) {
                    var usableW = screenSaverOverlay.width - bounceLogo.width
                    var usableH = screenSaverOverlay.height - bounceLogo.height
                    bounceLogo.x = Math.random() * (usableW > 0 ? usableW : 1)
                    bounceLogo.y = Math.random() * (usableH > 0 ? usableH : 1)
                    bounceLogo.vx = (Math.random() > 0.5 ? 1 : -1) * (1 + Math.random() * 1.5)
                    bounceLogo.vy = (Math.random() > 0.5 ? 1 : -1) * (1 + Math.random() * 1.5)
                    screenSaverActive = true
                    screenSaverOverlay.forceActiveFocus()
                }
            }
        }
    }

    Item {
        id: screenSaverOverlay
        anchors.fill: parent
        visible: screenSaverActive
        z: 9999
        focus: visible

        // Solid black background — no transparency so it serves as a true
        // CRT burn-in prevention black frame between the logo bounces.
        Rectangle {
            anchors.fill: parent
            color: "#000000"
        }

        // Bouncing logo — classic DVD player screen saver
        Image {
            id: bounceLogo
            source: "assets/images/logo.svg"
            sourceSize.width: root.sw * 0.05
            sourceSize.height: root.sw * 0.05
            fillMode: Image.PreserveAspectFit
            antialiasing: true

            property real vx: 0
            property real vy: 0

            // Physics tick at ~60 fps while the overlay is visible
            Timer {
                interval: 16
                repeat: true
                running: screenSaverActive
                onTriggered: {
                    bounceLogo.x += bounceLogo.vx
                    bounceLogo.y += bounceLogo.vy

                    if (bounceLogo.x + bounceLogo.width > screenSaverOverlay.width) {
                        bounceLogo.x = screenSaverOverlay.width - bounceLogo.width
                        bounceLogo.vx = -Math.abs(bounceLogo.vx)
                    } else if (bounceLogo.x < 0) {
                        bounceLogo.x = 0
                        bounceLogo.vx = Math.abs(bounceLogo.vx)
                    }

                    if (bounceLogo.y + bounceLogo.height > screenSaverOverlay.height) {
                        bounceLogo.y = screenSaverOverlay.height - bounceLogo.height
                        bounceLogo.vy = -Math.abs(bounceLogo.vy)
                    } else if (bounceLogo.y < 0) {
                        bounceLogo.y = 0
                        bounceLogo.vy = Math.abs(bounceLogo.vy)
                    }
                }
            }
        }

        // A tap dismisses the screen saver just like a keypress; the MouseArea
        // swallows the tap so nothing underneath is activated by it.
        MouseArea {
            anchors.fill: parent
            onClicked: {
                screenSaverActive = false
                moduleLoader.forceActiveFocus()
            }
        }

        // Capture any keypress to dismiss — consumes the event so the
        // underlying view never sees it, preventing accidental navigation.
        // Ctrl+Q still quits (moduleLoader's handler is a sibling, so it
        // can't see keys focused here — handle the chord directly).
        Keys.onPressed: (event) => {
            event.accepted = true
            if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_Q) {
                Qt.quit()
                return
            }
            screenSaverActive = false
            moduleLoader.forceActiveFocus()
        }
    }
}
