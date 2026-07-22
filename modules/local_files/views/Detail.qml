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
    // True when the current file is a show episode: PREV/NEXT then span the whole
    // series (across seasons) and finishing one advances to the next.
    property bool isSeries: false

    // Cast & Extras cards (nfo actors + playable bonus videos), fetched on load.
    property var castExtras: []
    property int castIndex: 0
    // Reveal-on-scroll: the body holds still until focus reaches Cast & Extras
    // (row 6), then shifts up to bring that row into view (like the Plex screen).
    property real sectionScroll: focusRow < 7 ? 0 : castSection.y

    // Focus rows: 0 = watchlist toggle, 1 = play cluster (PREV/PLAY/NEXT via
    // playCol), 2 = actions (WATCHED / TRACKED via actionCol), 3 = audio,
    // 4 = subtitles, 5 = volume, 6 = upscaler, 7 = cast & extras. Focus opens on
    // PLAY (row 1).
    property int focusRow: 1
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
    // show's season folder), so choices are remembered per movie/show. Shared by
    // the upscaler and the volume gain.
    function titleKey() {
        var p = String((current && current.path) || "")
        var cut = Math.max(p.lastIndexOf('/'), p.lastIndexOf('\\'))
        return "file:" + (cut > 0 ? p.substring(0, cut) : p)
    }
    function cycleUpscaler(dir) {
        upscalerIdx = (upscalerIdx + dir + upscalers.length) % upscalers.length
        var id = upscalers[upscalerIdx].id
        appCore.save_map_setting("", "upscaler_overrides", titleKey(), id)   // remember per title
        appCore.save_setting("", "mpv_upscaler_active", id)                  // apply to next play
    }

    // Per-title volume gain (dB, default 0), remembered per movie/show like the
    // upscaler. Applied to the next playback via mpv --volume-gain.
    property int volumeDb: 0
    function volumeLabel() { return (volumeDb > 0 ? "+" : "") + volumeDb + " dB" }
    function cycleVolume(dir) {
        volumeDb = Math.max(-20, Math.min(12, volumeDb + dir))
        appCore.save_map_setting("", "volume_overrides", titleKey(), String(volumeDb))
        appCore.save_setting("", "mpv_volume_gain_active", String(volumeDb))
    }

    // Per-show audio/subtitle language, probed from the file with ffprobe and
    // remembered per movie/show like the other options. Selection is by language
    // so it carries across episodes (mpv picks the matching track each time).
    // lang "" = Default (mpv / the global settings choose); "off" (subs) = disabled.
    property var audioLangs: []   // [{lang,label}] present in the current file
    property var subLangs: []
    property var audioOptions: [{ lang: "", label: "DEFAULT" }].concat(audioLangs)
    property var subOptions: [{ lang: "", label: "DEFAULT" }, { lang: "off", label: "OFF" }].concat(subLangs)
    property int audioIdx: 0
    property int subIdx: 0
    function audioLabel() { return (audioOptions[audioIdx] || {}).label || "DEFAULT" }
    function subLabel()   { return (subOptions[subIdx] || {}).label || "DEFAULT" }
    function cycleAudio(dir) {
        if (audioOptions.length < 2) return
        audioIdx = (audioIdx + dir + audioOptions.length) % audioOptions.length
        appCore.save_map_setting("", "audio_lang_overrides", titleKey(), audioOptions[audioIdx].lang)
        appCore.save_setting("", "mpv_alang_active", audioOptions[audioIdx].lang)
    }
    function cycleSub(dir) {
        if (subOptions.length < 2) return
        subIdx = (subIdx + dir + subOptions.length) % subOptions.length
        appCore.save_map_setting("", "sub_lang_overrides", titleKey(), subOptions[subIdx].lang)
        appCore.save_setting("", "mpv_sub_choice_active", subOptions[subIdx].lang)
    }
    function probeCurrent() {
        if (current && current.path) localFilesBackend.probe_tracks(String(current.path))
    }
    // Resolve the per-show language overrides against the probed options and publish
    // the active values for the player. "" (audio) / "" (subs) mean "no override".
    function resolveTrackSelection() {
        var ao = appCore.get_map_setting("", "audio_lang_overrides", titleKey())
        audioIdx = 0
        for (var i = 0; i < audioOptions.length; i++)
            if (audioOptions[i].lang === ao) { audioIdx = i; break }
        var so = appCore.get_map_setting("", "sub_lang_overrides", titleKey())
        subIdx = 0
        for (var j = 0; j < subOptions.length; j++)
            if (subOptions[j].lang === so) { subIdx = j; break }
        appCore.save_setting("", "mpv_alang_active", audioOptions[audioIdx].lang)
        appCore.save_setting("", "mpv_sub_choice_active", subOptions[subIdx].lang)
    }

    Connections {
        target: localFilesBackend
        function onTracksReady(path, tracks) {
            if (String(path) !== String((current && current.path) || "")) return
            audioLangs = (tracks && tracks.audio) ? tracks.audio : []
            subLangs   = (tracks && tracks.subtitle) ? tracks.subtitle : []
            resolveTrackSelection()
        }
        // A generated extra thumbnail arrived — drop it onto its card. Reassigning
        // the array refreshes the delegates; castIndex is a separate property, so
        // the current selection is preserved.
        function onExtraThumbReady(path, url) {
            var list = detailRoot.castExtras
            for (var i = 0; i < list.length; i++) {
                if (list[i].kind === "extra" && list[i].path === path && !list[i].image) {
                    list[i].image = url
                    detailRoot.castExtras = list.slice()
                    return
                }
            }
        }
    }

    // Saved resume position for the current video (drives the RSUM label)
    property int savedPos: 0
    // Watched flag, and Continue Watching membership (in progress + not removed)
    property bool watched: false
    property bool tracked: false
    property bool onWatchlist: false

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
        probeCurrent()   // re-probe the new episode's tracks (selection carries by lang)
    }

    function refreshSaved() {
        var saved = localFilesBackend.getSavedPosition(current.path || "")
        savedPos = saved.pos || 0
        watched = saved.watched === true
        // In Continue Watching = has resume progress and not manually removed.
        tracked = savedPos > 0 && saved.tracked !== false
        onWatchlist = saved.watchlisted === true
    }

    function toggleWatched() {
        watched = !watched
        localFilesBackend.set_watched(current.path, watched)
        if (watched) { savedPos = 0; tracked = false }  // marking watched leaves CW
    }

    function toggleWatchlist() {
        if (!current || !current.path) return
        onWatchlist = !onWatchlist
        localFilesBackend.set_watchlisted(String(current.path), onWatchlist)
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
            siblingIndex: videoIndices.indexOf(index),
            isSeries: isSeries
        }, { currentIndex: index })
    }

    // Play a bonus video (trailer/featurette/…) straight from Cast & Extras — a
    // one-off with no siblings, so it never advances into the episode rotation.
    function playExtra(path, name) {
        navigateTo("Player.qml", {
            filePath: path,
            title: name,
            mediaTitle: name,
            siblings: [],
            siblingIndex: -1,
            isSeries: false
        }, { currentIndex: index })
    }

    Component.onCompleted: {
        // For a show episode, swap the PREV/NEXT list to the entire series (every
        // season), so it spans season boundaries and works even when we arrived
        // from Continue Watching (which hands over a mixed list). A movie keeps the
        // folder listing it was opened with. Bootstraps from current.path alone, so
        // the Player can repoint us to the next episode with just its path.
        var series = localFilesBackend.series_episodes(current.path || "")
        if (series && series.isSeries === true && series.episodes && series.episodes.length > 0) {
            items = series.episodes
            index = series.index
            isSeries = true
        }
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
        castExtras = localFilesBackend.get_cast_extras(current.path || "")
        localFilesBackend.generate_extra_thumbs(castExtras)   // fill in missing extra art

        var bg = appCore.get_setting(moduleRoot.moduleId, "info_background")
        infoBg = (bg === undefined || bg === null || bg === "")
                 ? true : (bg === true || bg === "ON")
        var op = parseInt(appCore.get_setting(moduleRoot.moduleId, "info_background_opacity"))
        if (op > 0) infoBgOpacity = op / 100

        // Per-title override if set, else the global default. Publish it as the
        // active value so playing straight from here uses this title's upscaler.
        var ovr = appCore.get_map_setting("", "upscaler_overrides", titleKey())
        var up = ((ovr && ovr !== "") ? ovr
                  : (appCore.get_setting("", "mpv_upscaler") || "off")).toString().toLowerCase()
        for (var ui = 0; ui < upscalers.length; ui++)
            if (upscalers[ui].id === up) { upscalerIdx = ui; break }
        appCore.save_setting("", "mpv_upscaler_active", upscalers[upscalerIdx].id)

        // Per-title volume gain (dB), published as the active value for playback.
        var vovr = appCore.get_map_setting("", "volume_overrides", titleKey())
        volumeDb = (vovr && vovr !== "") ? parseInt(vovr) : 0
        appCore.save_setting("", "mpv_volume_gain_active", String(volumeDb))

        // Reset audio/sub overrides to "no override" until the probe resolves them,
        // then probe the file for its languages.
        appCore.save_setting("", "mpv_alang_active", "")
        appCore.save_setting("", "mpv_sub_choice_active", "")
        probeCurrent()
    }

    focus: true

    // Rows: 0 play, 1 actions, 2 audio (>1 lang), 3 subtitles (any), 4 volume,
    // 5 upscaler, 6 cast & extras. Audio/subtitle appear only when the probe found
    // tracks; cast & extras only when present. Up/Down skip empty rows.
    function rowAvailable(r) {
        if (r <= 2) return true   // watchlist, play cluster, actions (always)
        if (r === 3) return audioLangs.length > 1
        if (r === 4) return subLangs.length > 0
        if (r === 5) return true   // volume
        if (r === 6) return true   // upscaler
        if (r === 7) return detailRoot.castExtras.length > 0   // cast & extras
        return false
    }
    Keys.onUpPressed: {
        for (var r = focusRow - 1; r >= 0; r--) if (rowAvailable(r)) { focusRow = r; break }
    }
    Keys.onDownPressed: {
        for (var r = focusRow + 1; r <= 7; r++) if (rowAvailable(r)) { focusRow = r; break }
    }
    Keys.onLeftPressed: {
        if (focusRow === 1) { if (hasSiblings && playCol > 0) playCol-- }
        else if (focusRow === 2) { if (actionCol > 0) actionCol-- }
        else if (focusRow === 3) detailRoot.cycleAudio(-1)
        else if (focusRow === 4) detailRoot.cycleSub(-1)
        else if (focusRow === 5) detailRoot.cycleVolume(-1)
        else if (focusRow === 6) detailRoot.cycleUpscaler(-1)
        else if (focusRow === 7 && detailRoot.castExtras.length > 0)
            detailRoot.castIndex = (detailRoot.castIndex - 1 + detailRoot.castExtras.length) % detailRoot.castExtras.length
    }
    Keys.onRightPressed: {
        if (focusRow === 1) { if (hasSiblings && playCol < 2) playCol++ }
        else if (focusRow === 2) { if (actionCol < 1) actionCol++ }
        else if (focusRow === 3) detailRoot.cycleAudio(1)
        else if (focusRow === 4) detailRoot.cycleSub(1)
        else if (focusRow === 5) detailRoot.cycleVolume(1)
        else if (focusRow === 6) detailRoot.cycleUpscaler(1)
        else if (focusRow === 7 && detailRoot.castExtras.length > 0)
            detailRoot.castIndex = (detailRoot.castIndex + 1) % detailRoot.castExtras.length
    }
    Keys.onReturnPressed: {
        if (focusRow === 0) { detailRoot.toggleWatchlist(); return }
        if (focusRow === 2) {
            if (actionCol === 0) toggleWatched()
            else toggleTracked()
            return
        }
        if (focusRow === 3) { detailRoot.cycleAudio(1); return }
        if (focusRow === 4) { detailRoot.cycleSub(1); return }
        if (focusRow === 5) { detailRoot.cycleVolume(1); return }
        if (focusRow === 6) { detailRoot.cycleUpscaler(1); return }
        if (focusRow === 7 && detailRoot.castExtras.length > 0) {
            // Extras play; cast cards are informational.
            var card = detailRoot.castExtras[detailRoot.castIndex]
            if (card && card.kind === "extra" && card.path)
                detailRoot.playExtra(card.path, card.title)
            return
        }
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

        // Content wrapper: holds still until focus reaches Cast & Extras (row 6),
        // then shifts up (y) to reveal it. The clipping Item above hides overflow.
        Item {
            id: contentWrap
            anchors.left: parent.left
            anchors.right: parent.right
            y: -detailRoot.sectionScroll
            Behavior on y { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

        Row {
            id: topRow
            anchors.top: parent.top
            anchors.left: parent.left
            height: root.sh * 0.31
            spacing: root.sw * 0.0375 //24

            // Play cluster + action buttons, stacked. WATCHED / TRACKED sit
            // directly below PREV/PLAY/NEXT (same footprint as the Plex one).
            Column {
                spacing: root.sh * 0.0125 //6

                // Watchlist toggle (row 0), above the play cluster — mirrors the
                // Plex info screen. The bookmark fills when it's on the watchlist.
                Rectangle {
                    id: watchlistBtn
                    property bool sel: focusRow === 0
                    width: root.sw * 0.1875
                    height: root.sh * 0.05
                    color: sel ? root.accentColor : root.surfaceColor
                    border.color: sel ? root.accentColor : root.tertiaryColor
                    border.width: root.sh * 0.003125 //2

                    MouseArea {
                        anchors.fill: parent
                        onClicked: { if (watchlistBtn.sel) detailRoot.toggleWatchlist(); else focusRow = 0 }
                    }
                    Row {
                        anchors.centerIn: parent
                        spacing: root.sw * 0.00625
                        Canvas {
                            id: bookmark
                            anchors.verticalCenter: parent.verticalCenter
                            width: root.sh * 0.018
                            height: root.sh * 0.024
                            property bool filled: detailRoot.onWatchlist
                            property color col: watchlistBtn.sel ? root.surfaceColor : root.primaryColor
                            onFilledChanged: requestPaint()
                            onColChanged: requestPaint()
                            onWidthChanged: requestPaint()
                            onHeightChanged: requestPaint()
                            onPaint: {
                                var ctx = getContext("2d"); ctx.reset()
                                var w = width, h = height
                                var lw = Math.max(1.5, w * 0.16)
                                var notch = h * 0.26
                                var x0 = lw / 2, y0 = lw / 2, x1 = w - lw / 2, y1 = h - lw / 2
                                ctx.beginPath()
                                ctx.moveTo(x0, y0); ctx.lineTo(x1, y0); ctx.lineTo(x1, y1)
                                ctx.lineTo(w / 2, y1 - notch); ctx.lineTo(x0, y1); ctx.closePath()
                                if (filled) { ctx.fillStyle = col; ctx.fill() }
                                else { ctx.strokeStyle = col; ctx.lineWidth = lw
                                       ctx.lineJoin = "round"; ctx.stroke() }
                            }
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "WATCHLIST"
                            color: watchlistBtn.sel ? root.surfaceColor : root.primaryColor
                            font.family: root.globalFont
                            font.pixelSize: root.sh * 0.025 //12
                        }
                    }
                }

                Item {
                    width: root.sw * 0.1875 //120
                    height: root.sh * 0.1166667 //56

                    Row {
                        anchors.fill: parent
                        spacing: root.sw * 0.0046875 //3

                        Rectangle {
                            id: prevButton
                            visible: detailRoot.hasSiblings
                            property bool sel: focusRow === 1 && playCol === 0
                            color: sel ? root.accentColor : root.surfaceColor
                            border.color: sel ? root.accentColor : root.tertiaryColor
                            width: root.sw * 0.0375 //24
                            height: parent.height
                            border.width: root.sh * 0.003125 //2

                            MouseArea {
                                anchors.fill: parent
                                onClicked: {
                                    if (prevButton.sel) inputManager.touchKey("select")
                                    else { focusRow = 1; playCol = 0 }
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
                            property bool sel: focusRow === 1 && (!detailRoot.hasSiblings || playCol === 1)
                            color: sel ? root.accentColor : root.surfaceColor
                            border.color: sel ? root.accentColor : root.tertiaryColor
                            // Fill the rest of the 0.1875 cluster so PREV+PLAY+NEXT
                            // total exactly matches the WATCHED/TRACKED row below.
                            width: detailRoot.hasSiblings
                                   ? root.sw * 0.1875 - 2 * (root.sw * 0.0375 + root.sw * 0.0046875)
                                   : root.sw * 0.1875
                            height: parent.height
                            border.width: root.sh * 0.003125 //2

                            MouseArea {
                                anchors.fill: parent
                                onClicked: {
                                    if (playButton.sel) inputManager.touchKey("select")
                                    else { focusRow = 1; playCol = 1 }
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
                            property bool sel: focusRow === 1 && playCol === 2
                            color: sel ? root.accentColor : root.surfaceColor
                            border.color: sel ? root.accentColor : root.tertiaryColor
                            width: root.sw * 0.0375 //24
                            height: parent.height
                            border.width: root.sh * 0.003125 //2

                            MouseArea {
                                anchors.fill: parent
                                onClicked: {
                                    if (nextButton.sel) inputManager.touchKey("select")
                                    else { focusRow = 1; playCol = 2 }
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
                        property bool sel: focusRow === 2 && actionCol === 0
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
                                else { focusRow = 2; actionCol = 0 }
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
                        property bool sel: focusRow === 2 && actionCol === 1
                        color: sel ? root.accentColor : root.surfaceColor
                        border.color: sel ? root.accentColor : root.tertiaryColor
                        width: (root.sw * 0.1875 - root.sw * 0.0046875) / 2
                        height: root.sh * 0.05
                        border.width: root.sh * 0.003125 //2

                        MouseArea {
                            anchors.fill: parent
                            onClicked: {
                                if (trackedBtn.sel) inputManager.touchKey("select")
                                else { focusRow = 2; actionCol = 1 }
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
                height: root.sh * 0.28
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

        // Playback settings — full-width rows (label + ◄ value ►), the same
        // presentation as the Plex info screen, below the play/metadata area.
        Column {
            id: settingsCol
            anchors.top: topRow.bottom
            anchors.topMargin: root.sh * 0.0125
            anchors.left: parent.left
            anchors.right: parent.right

            // AUDIO (row 2)
            Item {
                width: parent.width
                visible: detailRoot.audioLangs.length > 1
                height: visible ? root.sh * 0.048 : 0
                Rectangle { anchors.fill: parent; color: focusRow === 3 ? root.accentColor : "transparent" }
                MouseArea { anchors.fill: parent
                    onClicked: { if (focusRow === 3) detailRoot.cycleAudio(1); else focusRow = 3 } }
                Text {
                    text: "Audio"; color: focusRow === 3 ? root.surfaceColor : root.primaryColor
                    font.family: root.globalFont; font.capitalization: Font.AllUppercase
                    anchors.left: parent.left; anchors.leftMargin: root.sw * 0.009375
                    anchors.verticalCenter: parent.verticalCenter; font.pixelSize: root.sh * 0.0375
                }
                Row {
                    anchors.right: parent.right; anchors.rightMargin: root.sw * 0.009375
                    anchors.verticalCenter: parent.verticalCenter; spacing: root.sw * 0.00625
                    Text { text: "◄"; color: focusRow === 3 ? root.surfaceColor : root.tertiaryColor
                        font.family: root.globalFont; anchors.verticalCenter: parent.verticalCenter; font.pixelSize: root.sh * 0.0333333 }
                    Text { text: detailRoot.audioLabel(); color: focusRow === 3 ? root.surfaceColor : root.primaryColor
                        font.family: root.globalFont; font.capitalization: Font.AllUppercase; anchors.verticalCenter: parent.verticalCenter; font.pixelSize: root.sh * 0.0375 }
                    Text { text: "►"; color: focusRow === 3 ? root.surfaceColor : root.tertiaryColor
                        font.family: root.globalFont; anchors.verticalCenter: parent.verticalCenter; font.pixelSize: root.sh * 0.0333333 }
                }
            }

            // SUBTITLES (row 3)
            Item {
                width: parent.width
                visible: detailRoot.subLangs.length > 0
                height: visible ? root.sh * 0.048 : 0
                Rectangle { anchors.fill: parent; color: focusRow === 4 ? root.accentColor : "transparent" }
                MouseArea { anchors.fill: parent
                    onClicked: { if (focusRow === 4) detailRoot.cycleSub(1); else focusRow = 4 } }
                Text {
                    text: "Subtitles"; color: focusRow === 4 ? root.surfaceColor : root.primaryColor
                    font.family: root.globalFont; font.capitalization: Font.AllUppercase
                    anchors.left: parent.left; anchors.leftMargin: root.sw * 0.009375
                    anchors.verticalCenter: parent.verticalCenter; font.pixelSize: root.sh * 0.0375
                }
                Row {
                    anchors.right: parent.right; anchors.rightMargin: root.sw * 0.009375
                    anchors.verticalCenter: parent.verticalCenter; spacing: root.sw * 0.00625
                    Text { text: "◄"; color: focusRow === 4 ? root.surfaceColor : root.tertiaryColor
                        font.family: root.globalFont; anchors.verticalCenter: parent.verticalCenter; font.pixelSize: root.sh * 0.0333333 }
                    Text { text: detailRoot.subLabel(); color: focusRow === 4 ? root.surfaceColor : root.primaryColor
                        font.family: root.globalFont; font.capitalization: Font.AllUppercase; anchors.verticalCenter: parent.verticalCenter; font.pixelSize: root.sh * 0.0375 }
                    Text { text: "►"; color: focusRow === 4 ? root.surfaceColor : root.tertiaryColor
                        font.family: root.globalFont; anchors.verticalCenter: parent.verticalCenter; font.pixelSize: root.sh * 0.0333333 }
                }
            }

            // VOLUME (row 4)
            Item {
                width: parent.width
                height: root.sh * 0.048
                Rectangle { anchors.fill: parent; color: focusRow === 5 ? root.accentColor : "transparent" }
                MouseArea { anchors.fill: parent
                    onClicked: { if (focusRow === 5) detailRoot.cycleVolume(1); else focusRow = 5 } }
                Text {
                    text: "Volume"; color: focusRow === 5 ? root.surfaceColor : root.primaryColor
                    font.family: root.globalFont; font.capitalization: Font.AllUppercase
                    anchors.left: parent.left; anchors.leftMargin: root.sw * 0.009375
                    anchors.verticalCenter: parent.verticalCenter; font.pixelSize: root.sh * 0.0375
                }
                Row {
                    anchors.right: parent.right; anchors.rightMargin: root.sw * 0.009375
                    anchors.verticalCenter: parent.verticalCenter; spacing: root.sw * 0.00625
                    Text { text: "◄"; color: focusRow === 5 ? root.surfaceColor : root.tertiaryColor
                        font.family: root.globalFont; anchors.verticalCenter: parent.verticalCenter; font.pixelSize: root.sh * 0.0333333 }
                    Text { text: detailRoot.volumeLabel(); color: focusRow === 5 ? root.surfaceColor : root.primaryColor
                        font.family: root.globalFont; font.capitalization: Font.AllUppercase; anchors.verticalCenter: parent.verticalCenter; font.pixelSize: root.sh * 0.0375 }
                    Text { text: "►"; color: focusRow === 5 ? root.surfaceColor : root.tertiaryColor
                        font.family: root.globalFont; anchors.verticalCenter: parent.verticalCenter; font.pixelSize: root.sh * 0.0333333 }
                }
            }

            // UPSCALER (row 5)
            Item {
                width: parent.width
                height: root.sh * 0.048
                Rectangle { anchors.fill: parent; color: focusRow === 6 ? root.accentColor : "transparent" }
                MouseArea { anchors.fill: parent
                    onClicked: { if (focusRow === 6) detailRoot.cycleUpscaler(1); else focusRow = 6 } }
                Text {
                    text: "Upscaler"; color: focusRow === 6 ? root.surfaceColor : root.primaryColor
                    font.family: root.globalFont; font.capitalization: Font.AllUppercase
                    anchors.left: parent.left; anchors.leftMargin: root.sw * 0.009375
                    anchors.verticalCenter: parent.verticalCenter; font.pixelSize: root.sh * 0.0375
                }
                Row {
                    anchors.right: parent.right; anchors.rightMargin: root.sw * 0.009375
                    anchors.verticalCenter: parent.verticalCenter; spacing: root.sw * 0.00625
                    Text { text: "◄"; color: focusRow === 6 ? root.surfaceColor : root.tertiaryColor
                        font.family: root.globalFont; anchors.verticalCenter: parent.verticalCenter; font.pixelSize: root.sh * 0.0333333 }
                    Text { text: detailRoot.upscalers[detailRoot.upscalerIdx].label; color: focusRow === 6 ? root.surfaceColor : root.primaryColor
                        font.family: root.globalFont; font.capitalization: Font.AllUppercase; anchors.verticalCenter: parent.verticalCenter; font.pixelSize: root.sh * 0.0375 }
                    Text { text: "►"; color: focusRow === 6 ? root.surfaceColor : root.tertiaryColor
                        font.family: root.globalFont; anchors.verticalCenter: parent.verticalCenter; font.pixelSize: root.sh * 0.0333333 }
                }
            }
        }

        // SECTION: Cast & Extras — nfo actors (portrait headshots) and playable
        // bonus videos (landscape), revealed by scrolling down past the settings.
        Item {
            id: castSection
            visible: detailRoot.castExtras.length > 0
            anchors.top: settingsCol.bottom
            anchors.topMargin: visible ? root.sh * 0.03 : 0
            anchors.left: parent.left
            anchors.right: parent.right
            height: visible ? (ceLabel.height + root.sh * 0.0083333 + ceList.height) : 0

            Text {
                id: ceLabel
                text: "Cast & Extras"
                color: detailRoot.focusRow === 7 ? root.accentColor : root.secondaryColor
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                anchors.top: parent.top
                anchors.left: parent.left
                font.pixelSize: root.sh * 0.0375
            }

            ListView {
                id: ceList
                model: detailRoot.castExtras
                orientation: ListView.Horizontal
                anchors.top: ceLabel.bottom
                anchors.topMargin: root.sh * 0.0083333
                anchors.left: parent.left
                anchors.right: parent.right
                height: root.sh * 0.245
                spacing: root.sw * 0.0125
                clip: true
                interactive: true
                flickableDirection: Flickable.HorizontalFlick
                currentIndex: detailRoot.castIndex
                onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)

                delegate: Item {
                    property bool isExtra: modelData.kind === "extra"
                    height: ceList.height
                    // Extras get a 16:9 thumbnail, cast a 2:3 headshot, so the two
                    // read differently at a glance.
                    width: (ceList.height * 0.66) * (isExtra ? (16 / 9) : (2 / 3))
                    property bool sel: detailRoot.focusRow === 7 && detailRoot.castIndex === index

                    Column {
                        anchors.fill: parent
                        spacing: root.sh * 0.0083333

                        Rectangle {
                            id: ceBox
                            width: parent.width
                            height: ceList.height * 0.66
                            color: "transparent"
                            border.color: sel ? root.accentColor : root.tertiaryColor
                            border.width: sel ? Math.max(2, Math.floor(root.sh * 0.00625)) : 1

                            Image {
                                id: ceImg
                                anchors.fill: parent
                                anchors.margins: ceBox.border.width
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                source: modelData.image || ""
                            }
                            // Imageless/broken card: a play glyph for extras, an
                            // initial for cast.
                            Text {
                                visible: !modelData.image || ceImg.status === Image.Error
                                anchors.centerIn: parent
                                text: modelData.kind === "extra" ? "▶" : (modelData.title || "?").charAt(0)
                                color: root.secondaryColor
                                font.family: root.globalFont
                                font.capitalization: Font.AllUppercase
                                font.pixelSize: root.sh * 0.05
                            }
                        }
                        MarqueeText {
                            width: parent.width
                            text: modelData.title || ""
                            color: sel ? root.accentColor : root.primaryColor
                            pixelSize: root.sh * 0.0233333
                            active: sel   // scroll the full name while highlighted
                        }
                        MarqueeText {
                            width: parent.width
                            text: modelData.subtitle || ""
                            color: root.tertiaryColor
                            pixelSize: root.sh * 0.02
                            active: sel
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: {
                            if (detailRoot.focusRow === 7 && detailRoot.castIndex === index)
                                inputManager.touchKey("select")
                            else { detailRoot.focusRow = 7; detailRoot.castIndex = index }
                        }
                    }
                }
            }
        }
        }
    }

    // Footer
    Text {
        text: root.hints.back + ":BACK " + root.hints.navigate + ":NAVIGATE "
              + (detailRoot.focusRow === 1 && detailRoot.hasSiblings ? root.hints.change + ":PREV/NEXT " : "")
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
