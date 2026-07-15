import QtQuick
import Components

FocusScope {
    id: settingsRoot

    signal navigateTo(string path, var params, var listState)
    signal goBack()

    property var navParams: ({})
    property var navListState: ({})

    property var appSettings: ({})
    property var installedModules: []

    // Flat model: mix of section headers and rows
    property var settingsItems: []

    property bool quitOverlayVisible: false
    property int quitChoiceIndex: 0

    // Quit overlay choices. Under the autostart service (headless RPi) the quit menu has an
    // "Exit to Terminal" option that drops to a tty1 login without powering off; that
    // option is not needed on macOS/Desktop or when run by hand, so it's yes/no for that case.
    property bool autostartSession: false
    property var quitOptions: settingsRoot.autostartSession
        ? [{ label: "Power Off",        action: "quit"     },
           { label: "Exit to Terminal", action: "terminal" },
           { label: "Cancel",           action: "cancel"   }]
        : [{ label: "Yes", action: "quit" },
           { label: "No",  action: "cancel" }]

    function buildModel() {
        var cfg = appCore.get_settings()
        appSettings = cfg.app || {}
        installedModules = appCore.get_installed_modules()
        autostartSession = appCore.isAutostartSession()

        var items = []

        // APPLICATION section
        var colorOpts = ["Video 1","Late Night","Synthwave","Terminal","T-120","Amber","Kinescope","SMPTE ECR 1-1978"]
        // Adding a new approach to add multiple custom themes at once
        var cThemes = appCore.getCustomColorSchemes()
        if (Object.keys(cThemes).length > 0) {
            for (var cTheme in cThemes) {
                if (!colorOpts.includes(cTheme) && Object.keys(cThemes[cTheme]).length === 5) colorOpts.push(cTheme)
            }
        }
        // Still support the single-theme approach
        var custom = appCore.getCustomColorScheme()
        if (!colorOpts.includes("Custom") && Object.keys(custom).length === 5) colorOpts.push("Custom")
        items.push({
            type: "list_single",
            key: "color_scheme",
            label: "Color Scheme",
            options: colorOpts,
            value: appSettings["color_scheme"] || "Video 1",
            description: "Choose your prefered color scheme\nPlease see the wiki for details on adding a custom one",
            moduleId: ""
        })

        // Start on Module — pick a module to auto-launch into on startup.
        // Only present enabled modules as options so disabled ones won't display.
        // The setting is keyed by module id and the picker shows the display name
        // If the stored id isn't an enabled module, the display falls back to None.
        var moduleOpts = ["None"] // display labels
        var moduleVals = ["None"] // stored values (module ids)
        var startupId = appSettings["startup_module"] || "None"
        var startupValue = "None"
        for (var mi = 0; mi < installedModules.length; mi++) {
            if (!installedModules[mi].enabled) continue
            moduleOpts.push(installedModules[mi].name)
            moduleVals.push(installedModules[mi].id)
            if (installedModules[mi].id === startupId) startupValue = installedModules[mi].name
        }
        items.push({
            type: "list_single",
            key: "startup_module",
            label: "Start on Module",
            options: moduleOpts,
            values: moduleVals,
            value: startupValue,
            description: "Directly launch into a specific module on startup",
            moduleId: ""
        })

        // Smooth Playback — only shown on devices whose smooth decode path can't
        // crop/zoom (the Pi 3 overlay path). Default ON; turning it off restores the
        // crop-capable video output. Takes effect on the next video.
        if (mpvController.hasSmoothPlaybackTradeoff()) {
            items.push({
                type: "list_single",
                key: "smooth_playback",
                label: "1080p Playback",
                options: ["On", "Off"],
                value: appSettings["smooth_playback"] || "On",
                description: "[ON] Enable 1080p content playback, crop will not function\n[OFF] Enable crop, 1080p content playback will stutter",
                moduleId: ""
            })
        }

        // Auto Crop — default crop (panscan) state for every video. Off by default;
        // crop can still be toggled live during playback via the mpv OSC.
        items.push({
            type: "list_single",
            key: "auto_crop",
            label: "Auto Crop",
            options: ["Off", "On"],
            value: appSettings["auto_crop"] || "Off",
            description: "[ON] Video starts cropped to fill screen\n[OFF] Video starts at its original aspect ratio",
            moduleId: ""
        })

        // Controller Input — ignore game controllers entirely while Off (a pad
        // with a stuck/drifting input can otherwise navigate on its own).
        // Keyboard input always works, so this can't lock the user out.
        items.push({
            type: "list_single",
            key: "controller_input",
            label: "Controller Input",
            options: ["On", "Off"],
            value: appSettings["controller_input"] || "On",
            description: "[ON] Navigate with game controllers\n[OFF] Ignore all game controller input (keyboard still works)",
            moduleId: ""
        })

        // Seek Amount — seconds jumped by the player's << / >> buttons and by
        // LEFT/RIGHT on the seek bar. Applies from the next playback.
        items.push({
            type: "list_single",
            key: "seek_seconds",
            label: "Seek Amount",
            options: ["5", "10", "15", "30", "60"],
            value: appSettings["seek_seconds"] || "10",
            description: "Seconds jumped per seek during playback (buttons and arrow keys)",
            moduleId: ""
        })

        // Default Upscaler — the real-time upscaler used for any title that has no
        // per-show/movie override (those are set from a title's info screen).
        // Display shows a label; the lowercase id is what gets stored.
        var upIds = ["off", "artcnn", "fsrcnnx", "anime4k", "hq"]
        var upLabels = ["Off", "ArtCNN", "FSRCNNX", "Anime4K", "High Quality"]
        var upCur = upIds.indexOf((appSettings["mpv_upscaler"] || "off").toString().toLowerCase())
        if (upCur < 0) upCur = 0
        items.push({
            type: "list_single",
            key: "mpv_upscaler",
            label: "Default Upscaler",
            options: upLabels,
            values: upIds,
            value: upLabels[upCur],
            description: "Real-time upscaler for titles without a per-show override. ArtCNN is a good all-rounder; Anime4K suits SD/grainy anime.",
            moduleId: ""
        })

        // SCREEN SAVER section — single control: OFF disables, a number sets the
        // timeout for both menu idle and playback pause (handled inside mpv).
        items.push({
            type: "list_single",
            key: "screensaver_timeout",
            label: "Screen Saver",
            options: ["OFF", "30", "60", "120"],
            value: appSettings["screensaver_timeout"] || "OFF",
            description: "Prevent CRT burn-in after seconds of inactivity or pause",
            moduleId: ""
        })

        // Background — an image or animated GIF behind the menus (file picker).
        // Scanline + tint controls only appear once a background is chosen.
        var bgPath = appSettings["app_background"] || ""
        var bgName = bgPath ? bgPath.replace(/\\/g, "/").split("/").pop() : "None"
        items.push({
            type: "file_browser",
            key: "app_background",
            label: "Background",
            value: bgName,
            path: bgPath,
            description: "Set an image or animated GIF as the menu background.",
            moduleId: ""
        })
        if (bgPath !== "") {
            items.push({
                type: "list_single",
                key: "app_background_scanlines",
                label: "Background Scanlines",
                options: ["On", "Off"],
                value: appSettings["app_background_scanlines"] || "On",
                description: "Overlay CRT-style scanlines on the background.",
                moduleId: ""
            })
            items.push({
                type: "list_single",
                key: "app_background_tint",
                label: "Background Tint",
                options: ["0%", "20%", "40%", "60%", "80%"],
                value: appSettings["app_background_tint"] || "40%",
                description: "Tint the background toward the theme color so menus stay legible.",
                moduleId: ""
            })
        }

        // MODULES section — only show modules with has_settings
        var hasModuleSettings = false
        for (var i = 0; i < installedModules.length; i++) {
            if (installedModules[i].has_settings) { hasModuleSettings = true; break }
        }

        if (hasModuleSettings) {
            items.push({ type: "section", label: "Modules" })
            for (var j = 0; j < installedModules.length; j++) {
                var m = installedModules[j]
                if (m.has_settings) {
                    items.push({ type: "submenu", label: m.name, moduleId: m.id })
                }
            }
        }

        // SYSTEM section
        items.push({ type: "section", label: "Application" })
        items.push({
            type: "submenu",
            key: "software_update",
            label: "Update 240-MP",
            moduleId: ""
        })
        items.push({ type: "quit", label: "Quit 240-MP" })

        settingsItems = items

        // Restore saved position, or default to first selectable row
        if (navListState.currentIndex !== undefined) {
            settingsList.currentIndex = Math.min(navListState.currentIndex, items.length - 1)
        } else {
            for (var k = 0; k < items.length; k++) {
                if (items[k].type !== "section") {
                    settingsList.currentIndex = k
                    break
                }
            }
        }
        settingsList.positionViewAtIndex(settingsList.currentIndex, ListView.Contain)
    }

    function firstSelectableAfter(idx) {
        for (var i = idx + 1; i < settingsItems.length; i++) {
            if (settingsItems[i].type !== "section") return i
        }
        return settingsList.currentIndex
    }

    function firstSelectableBefore(idx) {
        for (var i = idx - 1; i >= 0; i--) {
            if (settingsItems[i].type !== "section") return i
        }
        return settingsList.currentIndex
    }

    Component.onCompleted: buildModel()

    // Header
    AppBar {
        iconSource: "../../assets/images/settings.svg"
        title: "Settings"
        subtitle: root.appVersion
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.125 //60
        anchors.leftMargin: root.sw * 0.125 //80
    }

    ListView {
        id: settingsList
        model: settingsItems
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.25 //120
        anchors.leftMargin: root.sw * 0.115625 //74
        width: root.sw * 0.76875 //492
        height: root.sh * 0.525 //252
        clip: true
        focus: true

        Keys.onUpPressed: {
            var prev = settingsRoot.firstSelectableBefore(currentIndex)
            if (prev !== currentIndex) currentIndex = prev
        }
        Keys.onDownPressed: {
            var next = settingsRoot.firstSelectableAfter(currentIndex)
            if (next !== currentIndex) currentIndex = next
        }

        Keys.onLeftPressed: {
            var row = settingsItems[currentIndex]
            if (row && row.type === "list_single") {
                var opts = row.options
                var idx = opts.indexOf(row.value)
                var newIdx = (idx - 1 + opts.length) % opts.length
                var newVal = opts[newIdx]
                // Display the label; persist the parallel value when one exists.
                var savedVal = row.values ? row.values[newIdx] : newVal
                var updated = settingsItems.slice()
                updated[currentIndex] = Object.assign({}, row, { value: newVal })
                var savedIndex = currentIndex
                settingsItems = updated
                currentIndex = savedIndex
                appCore.save_setting(row.moduleId, row.key, savedVal)
            }
        }

        Keys.onRightPressed: {
            var row = settingsItems[currentIndex]
            if (row && row.type === "list_single") {
                var opts = row.options
                var idx = opts.indexOf(row.value)
                var newIdx = (idx + 1) % opts.length
                var newVal = opts[newIdx]
                // Display the label; persist the parallel value when one exists.
                var savedVal = row.values ? row.values[newIdx] : newVal
                var updated = settingsItems.slice()
                updated[currentIndex] = Object.assign({}, row, { value: newVal })
                var savedIndex = currentIndex
                settingsItems = updated
                currentIndex = savedIndex
                appCore.save_setting(row.moduleId, row.key, savedVal)
            }
        }

        Keys.onReturnPressed: {
            var row = settingsItems[currentIndex]
            if (row && row.type === "submenu") {
                if (row.key === "software_update")
                    settingsRoot.navigateTo("views/Update.qml", {}, { currentIndex: settingsList.currentIndex })
                else
                    settingsRoot.navigateTo("views/ModuleSettings.qml", { moduleId: row.moduleId }, { currentIndex: settingsList.currentIndex })
            } else if (row && row.type === "file_browser") {
                settingsRoot.navigateTo("views/DirectoryBrowser.qml", {
                    moduleId: "",
                    settingKey: row.key,
                    currentPath: row.path ? appCore.parentDirectory(row.path) : appCore.homePath(),
                    fileExtensions: "jpg,jpeg,png,gif,webp,bmp",
                    noneLabel: "<NO BACKGROUND>"
                }, { currentIndex: settingsList.currentIndex })
            } else if (row && row.type === "quit") {
                settingsRoot.quitChoiceIndex = 0
                settingsRoot.quitOverlayVisible = true
            }
        }

        Keys.onPressed: function(event) {
            // PgUp/PgDown page by one screenful; if paging lands on a
            // non-selectable section header, nudge to the nearest real row.
            if (event.key === Qt.Key_PageDown) {
                NavUtil.page(settingsList, 1)
                if (settingsItems[currentIndex] && settingsItems[currentIndex].type === "section")
                    currentIndex = settingsRoot.firstSelectableAfter(currentIndex)
                event.accepted = true
                return
            }
            if (event.key === Qt.Key_PageUp) {
                NavUtil.page(settingsList, -1)
                if (settingsItems[currentIndex] && settingsItems[currentIndex].type === "section")
                    currentIndex = settingsRoot.firstSelectableBefore(currentIndex)
                event.accepted = true
                return
            }
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                settingsRoot.goBack()
                event.accepted = true
            }
        }

        delegate: Item {
            width: settingsList.width
            height: root.sh * 0.0583333 //28

            // --- SECTION LABEL ---
            Text {
                visible: modelData.type == "section"
                text: modelData.label || ""
                color: root.secondaryColor
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                anchors.verticalCenter: parent.verticalCenter
                topPadding: root.sh * 0.0020833 //1
                leftPadding: root.sw * 0.009375 //6
                rightPadding: root.sw * 0.009375 //6
                font.pixelSize: root.sh * 0.0291667 //14
            }

            // --- SELECTABLE ROW ---
            Rectangle {
                visible: modelData.type !== "section"
                anchors.fill: parent
                color: settingsList.currentIndex === index ? root.accentColor : "transparent"

                // Touch: first tap focuses the row; tapping the focused row
                // activates it (cycles a list_single forward, opens a submenu,
                // etc.) via a synthesized key, reusing the keyboard handlers.
                // Declared before the value Row so its arrows stack on top.
                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        if (settingsList.currentIndex !== index) {
                            settingsList.currentIndex = index
                            return
                        }
                        inputManager.touchKey(modelData.type === "list_single" ? "right" : "select")
                    }
                }

                // Label
                Text {
                    text: modelData.label || ""
                    color: settingsList.currentIndex === index ? root.surfaceColor : root.primaryColor
                    font.family: root.globalFont
                    font.capitalization: Font.AllUppercase
                    anchors.verticalCenter: parent.verticalCenter
                    x: 0
                    topPadding: root.sh * 0.0041667 //2
                    leftPadding: root.sw * 0.009375 //6
                    rightPadding: root.sw * 0.009375 //6
                    bottomPadding: root.sh * 0.00625 //3
                    font.pixelSize: root.sh * 0.05 //24
                }

                // Value / arrow indicator
                Row {
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.right: parent.right
                    anchors.rightMargin: root.sw * 0.009375 //6
                    spacing: root.sw * 0.00625 //4

                    Text {
                        visible: modelData.type === "list_single"
                        text: "\u25C4"
                        color: settingsList.currentIndex === index ? root.surfaceColor : root.tertiaryColor
                        font.family: root.globalFont
                        anchors.verticalCenter: parent.verticalCenter
                        topPadding: root.sh * 0.0041667 //2
                        bottomPadding: root.sh * 0.00625 //3
                        font.pixelSize: root.sh * 0.0375 //18

                        // Tap \u25C4 to cycle the value backward (row must be focused
                        // first; a stray tap focuses it instead of changing it).
                        MouseArea {
                            anchors.fill: parent
                            anchors.margins: -root.sh * 0.0125
                            onClicked: {
                                if (settingsList.currentIndex === index) inputManager.touchKey("left")
                                else settingsList.currentIndex = index
                            }
                        }
                    }
                    Text {
                        visible: modelData.type === "list_single" || modelData.type === "file_browser"
                        text: modelData.value || ""
                        color: settingsList.currentIndex === index ? root.surfaceColor : root.primaryColor
                        font.family: root.globalFont
                        font.capitalization: Font.AllUppercase
                        anchors.verticalCenter: parent.verticalCenter
                        topPadding: root.sh * 0.0041667 //2
                        leftPadding: root.sw * 0.009375 //6
                        rightPadding: root.sw * 0.009375 //6
                        bottomPadding: root.sh * 0.00625 //3
                        font.pixelSize:root.sh * 0.05 //24
                    }
                    Text {
                        visible: modelData.type === "submenu" || modelData.type === "list_single" || modelData.type === "file_browser"
                        text: "\u25BA"
                        color: settingsList.currentIndex === index ? root.surfaceColor : root.tertiaryColor
                        font.family: root.globalFont
                        anchors.verticalCenter: parent.verticalCenter
                        topPadding: root.sh * 0.0041667 //2
                        bottomPadding: root.sh * 0.00625 //3
                        font.pixelSize: root.sh * 0.0375 //18
                    }
                }
            }
        }
    }

    // --- HELP TEXT --- (shown when a focused row has a description)
    Rectangle {
        id: rowHelpBackground
        property var currentRow: settingsRoot.settingsItems[settingsList.currentIndex]
        visible: !!(currentRow && currentRow.description)
        property color baseColor: root.primaryColor
        color: Qt.rgba(baseColor.r, baseColor.g, baseColor.b, 0.2)
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.bottomMargin: root.sh * 0.1583333 //76
        anchors.leftMargin: root.sw * 0.125 //80
        width: root.sw * 0.75 //480
        height: root.sh * 0.0583333 //28
        clip: true
        Text {
            id: rowHelp
            text: (rowHelpBackground.currentRow && rowHelpBackground.currentRow.description) || ""
            color: root.primaryColor
            font.family: root.globalFont
            font.pixelSize: root.sh * 0.0291667 //14
            wrapMode: Text.WordWrap
            anchors.fill: parent
            anchors.margins: root.sw * 0.0125 //6
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }

    // --- FOOTER ---
    Text {
        id: footer
        text: root.hints.back + ":BACK " + root.hints.navigate + ":NAVIGATE " + root.hints.change + ":CHANGE " + root.hints.select + ":SELECT"
        color: root.tertiaryColor
        font.family: root.globalFont
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.bottomMargin: root.sh * 0.1041667 //50
        anchors.leftMargin: root.sw * 0.125 //80
        font.pixelSize: root.sh * 0.0333333 //16
    }

    // --- QUIT CONFIRMATION OVERLAY ---
    Rectangle {
        anchors.fill: parent
        color: root.surfaceColor
        visible: quitOverlayVisible
        focus: quitOverlayVisible

        Keys.onUpPressed:   { quitChoiceIndex = Math.max(0, quitChoiceIndex - 1) }
        Keys.onDownPressed: { quitChoiceIndex = Math.min(quitOptions.length - 1, quitChoiceIndex + 1) }
        Keys.onReturnPressed: {
            var act = quitOptions[quitChoiceIndex].action
            if (act === "quit")          Qt.quit()
            else if (act === "terminal") Qt.exit(10)   // matches EXIT_STATUS check in 240mp-stop
            else { quitOverlayVisible = false; settingsList.forceActiveFocus() }
        }
        Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                quitOverlayVisible = false
                settingsList.forceActiveFocus()
                event.accepted = true
            }
        }

        Rectangle {
            color: root.surfaceColor
            anchors.centerIn: parent
            width: root.sw * 0.76875   //492
            height: root.sh * 0.2833333 //136

            Column {
                id: quitDialogColumn
                anchors.fill: parent
                spacing: root.sh * 0.05 //24

                Text {
                    text: "REALLY QUIT?"
                    color: root.secondaryColor
                    font.family: root.globalFont
                    font.pixelSize: root.sh * 0.0333333 //16
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                Column {
                    Repeater {
                        model: quitOptions
                        delegate: Item {
                            width: quitDialogColumn.width
                            height: root.sh * 0.0583333 //28

                            Rectangle {
                                anchors.fill: quitOptionText
                                color: root.accentColor
                                visible: index === quitChoiceIndex
                            }

                            Text {
                                id: quitOptionText
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: modelData.label
                                color: index === quitChoiceIndex ? root.surfaceColor : root.primaryColor
                                font.family: root.globalFont
                                font.capitalization: Font.AllUppercase
                                topPadding: root.sh * 0.0041667 //2
                                leftPadding: root.sw * 0.009375 //6
                                rightPadding: root.sw * 0.009375 //6
                                bottomPadding: root.sh * 0.00625 //3
                                font.pixelSize: root.sh * 0.05 //24
                            }

                            MouseArea {
                                anchors.fill: parent
                                onClicked: {
                                    if (quitChoiceIndex === index) inputManager.touchKey("select")
                                    else quitChoiceIndex = index
                                }
                            }
                        }
                    }
                }

                Text {
                    text: root.hints.back + ":BACK " + root.hints.navigate + ":NAVIGATE " + root.hints.select + ":SELECT"
                    color: root.tertiaryColor
                    font.family: root.globalFont
                    font.pixelSize: root.sh * 0.0333333 //16
                    anchors.horizontalCenter: parent.horizontalCenter
                }
            }
        }
    }
}
