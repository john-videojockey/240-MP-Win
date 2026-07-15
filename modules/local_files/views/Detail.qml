import QtQuick
import Components

// Local Files info screen — parity with the Plex detail view. Shows the
// scraper artwork/metadata (poster/fanart images, .nfo title/year/plot) the
// backend attached to the item, with PLAY/RSUM plus PREV/NEXT to step through
// the sibling videos of the same folder without going back to the list.
FocusScope {
    id: detailRoot

    property var navParams: ({})

    signal navigateTo(string path, var params, var listState)
    signal goBack()

    property var items: navParams.items || []
    property int index: navParams.index || 0
    property string folderName: navParams.folderName || ""

    property var current: items[index] || ({})

    // Indices of the folder's playable videos (folders/images/playlists are
    // not part of the PREV/NEXT rotation).
    property var videoIndices: []
    property bool hasSiblings: videoIndices.length > 1

    // Focus rows: 0 = play cluster (PREV/PLAY/NEXT via playCol), 1 = actions
    // (WATCHED / TRACKED via actionCol), 2 = upscaler.
    property int focusRow: 0
    // 0=PREV, 1=PLAY, 2=NEXT (PREV/NEXT only exist with siblings)
    property int playCol: 1
    property int actionCol: 0

    // Real-time upscaler — a global app setting ("mpv_upscaler") cycled here, the
    // same control as the Plex info screen. Applies to the next playback.
    property var upscalers: [
        { id: "off",     label: "OFF" },
        { id: "artcnn",  label: "ARTCNN" },
        { id: "fsrcnnx", label: "FSRCNNX" },
        { id: "anime4k", label: "ANIME4K" },
        { id: "hq",      label: "HIGH QUALITY" }
    ]
    property int upscalerIdx: 0
    // Per-title key: the current video's parent folder (a movie folder, or a
    // show's season folder), so the choice is remembered per movie/show.
    function upscalerKey() {
        var p = String((current && current.path) || "")
        var cut = Math.max(p.lastIndexOf('/'), p.lastIndexOf('\\'))
        return "file:" + (cut > 0 ? p.substring(0, cut) : p)
    }
    function cycleUpscaler(dir) {
        upscalerIdx = (upscalerIdx + dir + upscalers.length) % upscalers.length
        var id = upscalers[upscalerIdx].id
        appCore.save_map_setting("", "upscaler_overrides", upscalerKey(), id)   // remember per title
        appCore.save_setting("", "mpv_upscaler_active", id)                     // apply to next play
    }

    // Saved resume position for the current video (drives the RSUM label)
    property int savedPos: 0
    // Watched flag, and Continue Watching membership (in progress + not removed)
    property bool watched: false
    property bool tracked: false

    // Fanart background (module settings shared with the browse view)
    property bool infoBg: true
    property real infoBgOpacity: 0.3

    function displayTitle(it) {
        if (!it) return ""
        return it.title || it.name || ""
    }

    // "S1E2 - 2007 - 45MIN" — whichever fields the nfo provided
    function subLine(it) {
        if (!it) return ""
        var parts = []
        if (it.episode > 0)
            parts.push("S" + (it.season > 0 ? it.season : "?") + "E" + it.episode)
        if (it.year) parts.push(String(it.year))
        if (it.runtime > 0) parts.push(it.runtime + "MIN")
        return parts.join(" - ")
    }

    // Full title for the mpv OSC — Plex-style "SHOW - S1E2 - TITLE" for
    // episodes when the nfo provides the pieces, else the display title.
    function mediaTitleFor(it) {
        var t = displayTitle(it)
        if (it && it.episode > 0) {
            var show = it.showTitle || folderName
            var se = "S" + (it.season > 0 ? it.season : "?") + "E" + it.episode
            return (show ? show + " - " : "") + se + " - " + t
        }
        return t
    }

    function stepTo(direction) {
        var pos = videoIndices.indexOf(index)
        if (pos < 0) return
        var next = pos + direction
        if (next < 0 || next >= videoIndices.length) return
        index = videoIndices[next]
        refreshSaved()
    }

    function refreshSaved() {
        var saved = localFilesBackend.getSavedPosition(current.path || "")
        savedPos = saved.pos || 0
        watched = saved.watched === true
        // In Continue Watching = has resume progress and not manually removed.
        tracked = savedPos > 0 && saved.tracked !== false
    }

    function toggleWatched() {
        watched = !watched
        localFilesBackend.set_watched(current.path, watched)
        if (watched) { savedPos = 0; tracked = false }  // marking watched leaves CW
    }

    function toggleTracked() {
        // Only meaningful when there is progress to keep in/out of CW.
        if (savedPos <= 0) return
        tracked = !tracked
        localFilesBackend.set_tracked(current.path, tracked)
    }

    // Sibling descriptors handed to the Player so the mpv OSC's |< / >| can
    // step through the same rotation during playback.
    function siblingList() {
        var out = []
        for (var i = 0; i < videoIndices.length; i++) {
            var it = items[videoIndices[i]]
            out.push({ path: it.path, name: it.name, mediaTitle: mediaTitleFor(it) })
        }
        return out
    }

    function play() {
        navigateTo("Player.qml", {
            filePath: current.path,
            title: current.name,
            mediaTitle: mediaTitleFor(current),
            siblings: siblingList(),
            siblingIndex: videoIndices.indexOf(index)
        }, { currentIndex: index })
    }

    Component.onCompleted: {
        var vids = []
        for (var i = 0; i < items.length; i++) {
            var it = items[i]
            if (it && !it.isFolder
                && !localFilesBackend.isImage(it.path)
                && !localFilesBackend.isPlaylist(it.path))
                vids.push(i)
        }
        videoIndices = vids
        refreshSaved()

        var bg = appCore.get_setting(moduleRoot.moduleId, "info_background")
        infoBg = (bg === undefined || bg === null || bg === "")
                 ? true : (bg === true || bg === "ON")
        var op = parseInt(appCore.get_setting(moduleRoot.moduleId, "info_background_opacity"))
        if (op > 0) infoBgOpacity = op / 100

        // Per-title override if set, else the global default. Publish it as the
        // active value so playing straight from here uses this title's upscaler.
        var ovr = appCore.get_map_setting("", "upscaler_overrides", upscalerKey())
        var up = ((ovr && ovr !== "") ? ovr
                  : (appCore.get_setting("", "mpv_upscaler") || "off")).toString().toLowerCase()
        for (var ui = 0; ui < upscalers.length; ui++)
            if (upscalers[ui].id === up) { upscalerIdx = ui; break }
        appCore.save_setting("", "mpv_upscaler_active", upscalers[upscalerIdx].id)
    }

    focus: true

    Keys.onUpPressed: if (focusRow > 0) focusRow--
    Keys.onDownPressed: if (focusRow < 2) focusRow++
    Keys.onLeftPressed: {
        if (focusRow === 0) { if (hasSiblings && playCol > 0) playCol-- }
        else if (focusRow === 1) { if (actionCol > 0) actionCol-- }
        else if (focusRow === 2) detailRoot.cycleUpscaler(-1)
    }
    Keys.onRightPressed: {
        if (focusRow === 0) { if (hasSiblings && playCol < 2) playCol++ }
        else if (focusRow === 1) { if (actionCol < 1) actionCol++ }
        else if (focusRow === 2) detailRoot.cycleUpscaler(1)
    }
    Keys.onReturnPressed: {
        if (focusRow === 1) {
            if (actionCol === 0) toggleWatched()
            else toggleTracked()
            return
        }
        if (focusRow === 2) { detailRoot.cycleUpscaler(1); return }
        if (hasSiblings && playCol === 0) stepTo(-1)
        else if (hasSiblings && playCol === 2) stepTo(1)
        else play()
    }
    Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
            goBack()
            event.accepted = true
        }
    }

    // ---
    // UI
    // ---

    // Fanart background + scanlines — same treatment as the Plex info screen.
    // Opaque base so the fanart dims toward the theme color, not the app
    // background bleeding through the semi-transparent fanart.
    Rectangle {
        anchors.fill: parent
        z: -2
        visible: fanart.visible
        color: root.surfaceColor
    }
    Image {
        id: fanart
        anchors.fill: parent
        z: -1
        visible: detailRoot.infoBg && status === Image.Ready
        opacity: detailRoot.infoBgOpacity
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        source: (detailRoot.infoBg && current.art) ? current.art : ""
    }
    Image {
        anchors.fill: parent
        z: -1
        visible: fanart.visible
        fillMode: Image.Tile
        source: "../../../assets/images/scanlines.png"
        opacity: 0.6
    }

    // Header
    AppBar {
        iconSource: moduleRoot.moduleIcon
        title: moduleRoot.moduleName
        subtitle: folderName
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.125 //60
        anchors.leftMargin: root.sw * 0.125 //80
    }

    // Body
    Item {
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.25 //120
        anchors.leftMargin: root.sw * 0.115625 //74
        width: root.sw * 0.76875 //492
        height: root.sh * 0.525 //252
        clip: true

        Row {
            height: root.sh * 0.35 //168
            spacing: root.sw * 0.0375 //24

            // Play cluster + action buttons, stacked. WATCHED / TRACKED sit
            // directly below PREV/PLAY/NEXT (same footprint as the Plex one).
            Column {
                spacing: root.sh * 0.0125 //6

                Item {
                    width: root.sw * 0.1875 //120
                    height: root.sh * 0.1166667 //56

                    Row {
                        anchors.fill: parent
                        spacing: root.sw * 0.0046875 //3

                        Rectangle {
                            id: prevButton
                            visible: detailRoot.hasSiblings
                            property bool sel: focusRow === 0 && playCol === 0
                            color: sel ? root.accentColor : root.surfaceColor
                            border.color: sel ? root.accentColor : root.tertiaryColor
                            width: root.sw * 0.0375 //24
                            height: parent.height
                            border.width: root.sh * 0.003125 //2

                            MouseArea {
                                anchors.fill: parent
                                onClicked: {
                                    if (prevButton.sel) inputManager.touchKey("select")
                                    else { focusRow = 0; playCol = 0 }
                                }
                            }

                            Text {
                                anchors.centerIn: parent
                                text: "◄"
                                color: prevButton.sel ? root.surfaceColor : root.primaryColor
                                font.family: root.globalFont
                                font.pixelSize: root.sh * 0.0416667 //20
                            }
                        }

                        Rectangle {
                            id: playButton
                            property bool sel: focusRow === 0 && (!detailRoot.hasSiblings || playCol === 1)
                            color: sel ? root.accentColor : root.surfaceColor
                            border.color: sel ? root.accentColor : root.tertiaryColor
                            width: detailRoot.hasSiblings ? root.sw * 0.1 : root.sw * 0.1875
                            height: parent.height
                            border.width: root.sh * 0.003125 //2

                            MouseArea {
                                anchors.fill: parent
                                onClicked: {
                                    if (playButton.sel) inputManager.touchKey("select")
                                    else { focusRow = 0; playCol = 1 }
                                }
                            }

                            Text {
                                anchors.centerIn: parent
                                text: detailRoot.savedPos > 0 ? "RSUM ►" : "PLAY ►"
                                color: playButton.sel ? root.surfaceColor : root.primaryColor
                                font.family: root.globalFont
                                font.pixelSize: detailRoot.hasSiblings ? root.sh * 0.0375 : root.sh * 0.05
                            }
                        }

                        Rectangle {
                            id: nextButton
                            visible: detailRoot.hasSiblings
                            property bool sel: focusRow === 0 && playCol === 2
                            color: sel ? root.accentColor : root.surfaceColor
                            border.color: sel ? root.accentColor : root.tertiaryColor
                            width: root.sw * 0.0375 //24
                            height: parent.height
                            border.width: root.sh * 0.003125 //2

                            MouseArea {
                                anchors.fill: parent
                                onClicked: {
                                    if (nextButton.sel) inputManager.touchKey("select")
                                    else { focusRow = 0; playCol = 2 }
                                }
                            }

                            Text {
                                anchors.centerIn: parent
                                text: "►"
                                color: nextButton.sel ? root.surfaceColor : root.primaryColor
                                font.family: root.globalFont
                                font.pixelSize: root.sh * 0.0416667 //20
                            }
                        }
                    }
                }

                // Actions: WATCHED / UNWATCHED and TRACKED / UNTRACKED.
                Row {
                    spacing: root.sw * 0.0046875 //3

                    Rectangle {
                        id: watchedBtn
                        property bool sel: focusRow === 1 && actionCol === 0
                        color: sel ? root.accentColor : root.surfaceColor
                        border.color: sel ? root.accentColor : root.tertiaryColor
                        // Match the play cluster's total width (0.1875): two buttons
                        // split it with the same 3px gap; WATCHED takes it all when
                        // TRACKED is hidden.
                        width: trackedBtn.visible ? (root.sw * 0.1875 - root.sw * 0.0046875) / 2
                                                  : root.sw * 0.1875
                        height: root.sh * 0.05
                        border.width: root.sh * 0.003125 //2

                        MouseArea {
                            anchors.fill: parent
                            onClicked: {
                                if (watchedBtn.sel) inputManager.touchKey("select")
                                else { focusRow = 1; actionCol = 0 }
                            }
                        }

                        Text {
                            anchors.centerIn: parent
                            text: detailRoot.watched ? "WATCHED" : "UNWATCHED"
                            color: watchedBtn.sel ? root.surfaceColor : root.primaryColor
                            font.family: root.globalFont
                            font.pixelSize: root.sh * 0.025 //12
                        }
                    }

                    Rectangle {
                        id: trackedBtn
                        // Only relevant when there is progress to keep in/out of CW.
                        visible: detailRoot.savedPos > 0
                        property bool sel: focusRow === 1 && actionCol === 1
                        color: sel ? root.accentColor : root.surfaceColor
                        border.color: sel ? root.accentColor : root.tertiaryColor
                        width: (root.sw * 0.1875 - root.sw * 0.0046875) / 2
                        height: root.sh * 0.05
                        border.width: root.sh * 0.003125 //2

                        MouseArea {
                            anchors.fill: parent
                            onClicked: {
                                if (trackedBtn.sel) inputManager.touchKey("select")
                                else { focusRow = 1; actionCol = 1 }
                            }
                        }

                        Text {
                            anchors.centerIn: parent
                            text: detailRoot.tracked ? "TRACKED" : "UNTRACKED"
                            color: trackedBtn.sel ? root.surfaceColor : root.primaryColor
                            font.family: root.globalFont
                            font.pixelSize: root.sh * 0.025 //12
                        }
                    }
                }

                // Upscaler: cycles the global "mpv_upscaler" setting (applies to
                // the next playback). Focus row 2 — the same control as Plex info.
                Column {
                    spacing: root.sh * 0.0041667 //2
                    topPadding: root.sh * 0.0083333 //4

                    Text {
                        text: "UPSCALER"
                        color: root.tertiaryColor
                        font.family: root.globalFont
                        font.pixelSize: root.sh * 0.0208333 //10
                    }
                    Rectangle {
                        id: upscalerBtn
                        property bool sel: focusRow === 2
                        color: sel ? root.accentColor : root.surfaceColor
                        border.color: sel ? root.accentColor : root.tertiaryColor
                        width: root.sw * 0.1875
                        height: root.sh * 0.05
                        border.width: root.sh * 0.003125 //2

                        MouseArea {
                            anchors.fill: parent
                            onClicked: {
                                if (upscalerBtn.sel) detailRoot.cycleUpscaler(1)
                                else focusRow = 2
                            }
                        }
                        Text {
                            anchors.centerIn: parent
                            text: "◄ " + detailRoot.upscalers[detailRoot.upscalerIdx].label + " ►"
                            color: upscalerBtn.sel ? root.surfaceColor : root.primaryColor
                            font.family: root.globalFont
                            font.pixelSize: root.sh * 0.025 //12
                        }
                    }
                }
            }

            Column {
                topPadding: root.sh * 0.0083333 //4
                width: detailThumb.visible ? root.sw * 0.35 : root.sw * 0.54375
                spacing: root.sh * 0.0166667 //8

                // Title (nfo title, else filename)
                Text {
                    text: detailRoot.displayTitle(detailRoot.current)
                    color: root.primaryColor
                    font.family: root.globalFont
                    font.capitalization: Font.AllUppercase
                    elide: Text.ElideRight
                    width: parent.width
                    font.pixelSize: root.sh * 0.05 //24
                }

                // S#E# / year / runtime
                Text {
                    visible: text !== ""
                    text: detailRoot.subLine(detailRoot.current)
                    color: root.secondaryColor
                    font.family: root.globalFont
                    font.capitalization: Font.AllUppercase
                    elide: Text.ElideRight
                    width: parent.width
                    font.pixelSize: root.sh * 0.0333333 //16
                }

                // Plot (auto-scrolls when it overflows, like the Plex summary)
                Item {
                    id: plotContainer
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: root.sh * 0.1375 //66
                    clip: true

                    Text {
                        id: plotText
                        anchors.left: parent.left
                        anchors.right: parent.right
                        text: detailRoot.current.plot || ""
                        color: root.primaryColor
                        font.family: root.globalFont
                        wrapMode: Text.WordWrap
                        font.pixelSize: root.sh * 0.0291667 //14
                        lineHeight: 1.3
                    }

                    SequentialAnimation {
                        running: plotText.text !== "" && plotText.implicitHeight > plotContainer.height
                        loops: Animation.Infinite
                        onRunningChanged: if (!running) plotText.y = 0
                        PauseAnimation { duration: 3000 }
                        NumberAnimation {
                            target: plotText; property: "y"
                            to: plotContainer.height - plotText.implicitHeight
                            duration: Math.abs(to) * 120
                        }
                        PauseAnimation { duration: 4000 }
                        PropertyAction { target: plotText; property: "y"; value: 0 }
                    }
                }
            }

            // Poster / episode thumb
            Item {
                id: detailThumb
                width: root.sw * 0.155
                height: root.sh * 0.32
                visible: thumbImage.status === Image.Ready

                Image {
                    id: thumbImage
                    anchors.top: parent.top
                    anchors.left: parent.left
                    width: parent.width
                    height: parent.height
                    fillMode: Image.PreserveAspectFit
                    horizontalAlignment: Image.AlignLeft
                    verticalAlignment: Image.AlignTop
                    asynchronous: true
                    source: detailRoot.current.thumb || ""
                }
            }
        }
    }

    // Footer
    Text {
        text: root.hints.back + ":BACK " + root.hints.navigate + ":NAVIGATE "
              + (detailRoot.focusRow === 0 && detailRoot.hasSiblings ? root.hints.change + ":PREV/NEXT " : "")
              + root.hints.select + ":SELECT"
        color: root.tertiaryColor
        font.family: root.globalFont
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.bottomMargin: root.sh * 0.1041667 //50
        anchors.leftMargin: root.sw * 0.125 //80
        font.pixelSize: root.sh * 0.0333333 //16
    }
}
