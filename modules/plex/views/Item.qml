import QtQuick
import Components

FocusScope {
    id: detailRoot

    property var navParams: ({})

    signal navigateTo(string path, var params)
    signal goBack()

    property var item: navParams.item || {}
    property string libraryName: navParams.libraryName || ""

    // Loaded detail from backend
    property var detail: null

    // Focus rows: 0=play button, 1=audio, 2=subtitles
    property int focusRow: 0

    // True from when PLAY is pressed until we navigate to the Player (or error
    // out). Plex can take a few seconds to hand back a stream/transcode URL, so
    // we show a LOADING overlay instead of leaving the screen looking frozen.
    property bool isLaunching: false

    // Current stream selections (indices into stream lists)
    property int audioIdx: 0
    property int subtitleIdx: 0

    // Session ID for the current playback instance. Regenerated on every play
    // (see Keys.onReturnPressed): reusing one lets Plex hand back a stale
    // transcode session built with the previously selected audio/subtitle.
    property string sessionId: newSessionId()

    // Fanart background (module settings info_background / *_opacity)
    property bool infoBg: true
    property real infoBgOpacity: 0.3

    // Focus rows: 0 = play cluster, 1 = actions (WATCHED/TRACKED), 2 = audio,
    // 3 = subtitles. Column focus inside the play row: 0=PREV, 1=PLAY, 2=NEXT
    // (PREV/NEXT are episode-only). actionCol: 0=WATCHED, 1=TRACKED.
    property int  playCol: 1
    property int  actionCol: 0
    property bool episodeItem: (detail && detail.type === "episode") || item.type === "episode"
    property bool adjacentPending: false

    // Watched state (viewCount) and Continue Watching membership (viewOffset),
    // kept locally so the button labels flip without reloading the item.
    property bool watched: false
    property bool tracked: false

    function toggleWatched() {
        if (!detail) return
        watched = !watched
        if (watched) {
            plexBackend.mark_watched(detail.ratingKey)
            tracked = false   // marking watched removes it from Continue Watching
        } else {
            plexBackend.mark_unwatched(detail.ratingKey)
        }
    }

    function toggleTracked() {
        if (!detail) return
        tracked = !tracked
        if (tracked) {
            // Re-add to Continue Watching by sending a timeline update at the
            // saved offset (Plex has no explicit add endpoint).
            plexBackend.update_timeline(detail.ratingKey, detail.partKey, "paused",
                                        detail.viewOffset || 0, detail.duration || 0)
        } else {
            plexBackend.remove_from_continue_watching(detail.ratingKey)
        }
    }

    function requestAdjacent(direction) {
        if (adjacentPending || !detail || !detail.ratingKey) return
        adjacentPending = true
        plexBackend.load_adjacent_episode(detail.ratingKey, direction)
    }

    // Shared by the initial load and the PREV/NEXT swap: install a detail map
    // and re-derive the audio/subtitle selection indices from it.
    function applyDetail(d) {
        detail = d
        watched = (d.viewCount || 0) > 0
        tracked = (d.viewOffset || 0) > 0
        audioIdx = 0
        subtitleIdx = 0
        castIndex = 0
        if (d.audioStreams) {
            for (var i = 0; i < d.audioStreams.length; i++) {
                if (d.audioStreams[i].id === d.selectedAudioId) { audioIdx = i; break }
            }
        }
        if (d.subtitleStreams) {
            for (var j = 0; j < d.subtitleStreams.length; j++) {
                if (d.subtitleStreams[j].id === d.selectedSubtitleId) { subtitleIdx = j; break }
            }
        }
        // Theme song for this item (if enabled and one exists). play_theme
        // restarts cleanly, so a PREV/NEXT swap to another episode is fine.
        if (detailRoot.showThemes && d.theme)
            plexBackend.play_theme(d.theme, detailRoot.themeVolume)
        else
            plexBackend.stop_theme()
    }

    function newSessionId() {
        var chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        var id = ""
        for (var i = 0; i < 12; i++) id += chars[Math.floor(Math.random() * chars.length)]
        return id
    }

    function durationStr(ms) {
        if (!ms) return ""
        var totalMin = Math.floor(ms / 60000)
        var h = Math.floor(totalMin / 60)
        var m = totalMin % 60
        if (h > 0) return h + "HR:" + (m < 10 ? "0" : "") + m + "MIN"
        return m + "MIN"
    }

    Connections {
        target: plexBackend

        function onItemLoaded(d) {
            detailRoot.applyDetail(d)
        }

        function onRelatedReady(items) {
            detailRoot.relatedItems = items
            detailRoot.relatedIndex = 0
        }

        // PREV/NEXT resolved a sibling episode: swap this screen to it in
        // place (no navigation, so BACK still returns to the episode list).
        function onAdjacentEpisodeReady(direction, d) {
            if (!detailRoot.adjacentPending) return
            detailRoot.adjacentPending = false
            if (!d || !d.ratingKey) return   // no sibling that way — stay put
            detailRoot.item = {
                ratingKey: d.ratingKey,
                type: d.type || "episode",
                title: d.title || "",
                grandparentTitle: d.grandparentTitle || "",
                parentIndex: d.parentIndex,
                index: d.index,
                thumb: d.thumb || "",
                viewOffset: d.viewOffset || 0
            }
            detailRoot.applyDetail(d)
        }

        function onStreamUrlReady(url, plexToken) {
            if (!detailRoot.detail) return
            var d = detailRoot.detail
            var audioId = d.audioStreams && d.audioStreams[detailRoot.audioIdx]
                ? d.audioStreams[detailRoot.audioIdx].id : ""
            var subId = d.subtitleStreams && d.subtitleStreams[detailRoot.subtitleIdx]
                ? d.subtitleStreams[detailRoot.subtitleIdx].id : "0"
            var subUrl = (d.subtitleStreams && d.subtitleStreams[detailRoot.subtitleIdx])
                ? (d.subtitleStreams[detailRoot.subtitleIdx].subUrl || "") : ""

            var imageSubs = []
            if (d.subtitleStreams) {
                for (var k = 0; k < d.subtitleStreams.length; k++) {
                    if (d.subtitleStreams[k].imageSubtitle) imageSubs.push(d.subtitleStreams[k].id)
                }
            }

            // Full display title for the mpv OSC's top-left corner
            // (e.g. "SHOW - S1E2 - EPISODE TITLE"; movies use the title alone).
            var mediaTitle = d.title
            if (d.type === "episode") {
                var se = "S" + (d.parentIndex != null ? d.parentIndex : "?")
                       + "E" + (d.index != null ? d.index : "?")
                mediaTitle = (d.grandparentTitle ? d.grandparentTitle + " - " : "")
                           + se + " - " + d.title
            }

            detailRoot.navigateTo("Player.qml", {
                streamUrl: url,
                plexToken: plexToken,
                ratingKey: d.ratingKey,
                partKey: d.partKey,
                partId: d.partId,
                title: d.title,
                mediaTitle: mediaTitle,
                episodeNav: d.type === "episode",
                viewOffset: d.viewOffset || 0,
                duration: d.duration || 0,
                audioStreams: d.audioStreams || [],
                subtitleStreams: d.subtitleStreams || [],
                selectedAudioId: audioId,
                selectedSubtitleId: subId,
                selectedSubtitleUrl: subUrl,
                sessionId: detailRoot.sessionId,
                isTranscoding: d.forceTranscode || false,
                imageSubtitleIds: imageSubs
            })
        }

        // An extra (trailer/featurette) resolved to a stream — hand off to the
        // player with playback defaults (no track selection / resume for a clip).
        function onExtraStreamReady(params) {
            var p = {
                episodeNav: false,
                viewOffset: 0,
                audioStreams: [],
                subtitleStreams: [],
                selectedAudioId: "",
                selectedSubtitleId: "0",
                selectedSubtitleUrl: "",
                sessionId: detailRoot.sessionId,
                isTranscoding: false,
                imageSubtitleIds: []
            }
            for (var k in params) p[k] = params[k]
            detailRoot.navigateTo("Player.qml", p)
        }

        function onErrorOccurred(msg) {
            console.log("[Item] Error: " + msg)
            detailRoot.isLaunching = false
        }
    }

    // Show theme music (opt-in): play the item's theme while this info screen is
    // open. Read here, applied in applyDetail once the detail (with its theme
    // path) has loaded, and stopped on playback / when leaving the screen.
    property bool showThemes: false
    property int  themeVolume: 50

    // "More Like This": related titles, revealed only once the highlight reaches
    // the audio/subtitle rows so the play/options block keeps its clean look.
    property bool showRelated: false
    property var  relatedItems: []
    property int  relatedIndex: 0

    // "Cast & Extras": the item's cast (Role) plus any extras (trailers,
    // featurettes), revealed on the same scroll as More Like This. Sourced from
    // the loaded detail; informational for now (no per-card action).
    property var  castExtras: (detail && detail.castExtras) ? detail.castExtras : []
    property int  castIndex: 0

    // Real-time upscaler — a global app setting ("mpv_upscaler") cycled here in the
    // Playback Settings block. Applies to the next playback (Plex and Local Files).
    property var upscalers: [
        { id: "off",     label: "OFF" },
        { id: "artcnn",  label: "ARTCNN" },
        { id: "fsrcnnx", label: "FSRCNNX" },
        { id: "anime4k", label: "ANIME4K" },
        { id: "hq",      label: "HIGH QUALITY" }
    ]
    property int upscalerIdx: 0
    function cycleUpscaler(dir) {
        upscalerIdx = (upscalerIdx + dir + upscalers.length) % upscalers.length
        appCore.save_setting("", "mpv_upscaler", upscalers[upscalerIdx].id)
    }

    // Scroll the section stack so the section holding the current focusRow snaps
    // to the top of the content viewport: play/options (0-1) -> playback settings
    // audio/subtitle/upscaler (2-4) -> Cast & Extras (5) -> More Like This (6).
    property real sectionScroll: focusRow <= 1 ? 0
                               : focusRow <= 4 ? pbSettingsLabel.y
                               : focusRow === 5 ? castSection.y
                               : relatedSection.y

    Component.onCompleted: {
        if (item.ratingKey) plexBackend.load_item_detail(item.ratingKey)
        focusRow = 0

        var bg = appCore.get_setting(moduleRoot.moduleId, "info_background")
        infoBg = (bg === undefined || bg === null || bg === "")
                 ? true : (bg === true || bg === "ON")
        var op = parseInt(appCore.get_setting(moduleRoot.moduleId, "info_background_opacity"))
        if (op > 0) infoBgOpacity = op / 100

        // Toggle settings persist as a boolean (true/false), not "ON"/"OFF" —
        // accept both, matching how info_background is read above.
        var stv = appCore.get_setting(moduleRoot.moduleId, "show_themes")
        showThemes = (stv === true || stv === "ON")
        var tv = parseInt(appCore.get_setting(moduleRoot.moduleId, "theme_volume"))
        if (tv > 0) themeVolume = tv

        var up = (appCore.get_setting("", "mpv_upscaler") || "off").toString().toLowerCase()
        for (var ui = 0; ui < upscalers.length; ui++)
            if (upscalers[ui].id === up) { upscalerIdx = ui; break }

        // Start the theme immediately from the passed-in item (its theme path is
        // already known), so a theme playing on hover in browse carries over with
        // no restart — play_theme is idempotent. applyDetail re-asserts it once
        // the full detail arrives.
        if (showThemes && item.theme)
            plexBackend.play_theme(item.theme, themeVolume)

        var sr = appCore.get_setting(moduleRoot.moduleId, "show_related")
        showRelated = (sr === undefined || sr === null || sr === "") ? true
                    : (sr === true || sr === "ON")
        // Episodes have no "more like this" of their own — use the show's related.
        var relKey = (item.type === "episode" && item.grandparentRatingKey)
                     ? item.grandparentRatingKey : item.ratingKey
        if (showRelated && relKey) plexBackend.load_related(relKey)
    }

    // Deferred stop: navigating back to browse (which resumes the same theme on
    // hover) is seamless. Playback and themeless screens still stop it promptly
    // (stop_theme() is called before playback below).
    Component.onDestruction: plexBackend.stop_theme_deferred()

    focus: true

    // Rows: 0 play, 1 actions (always), 2 audio, 3 subtitles, 4 upscaler (always),
    // 5 cast & extras, 6 More Like This. A row is only reachable when it has
    // content, and Up/Down skip over any empty rows in between.
    function rowAvailable(r) {
        if (r <= 1) return true
        if (r === 2) return detail && detail.audioStreams && detail.audioStreams.length > 0
        if (r === 3) return detail && detail.subtitleStreams && detail.subtitleStreams.length > 1
        if (r === 4) return !!detail   // Upscaler — global playback setting
        if (r === 5) return detailRoot.castExtras.length > 0
        if (r === 6) return detailRoot.showRelated && detailRoot.relatedItems.length > 0
        return false
    }
    Keys.onUpPressed: {
        if (isLaunching) return
        for (var r = focusRow - 1; r >= 0; r--)
            if (rowAvailable(r)) { focusRow = r; break }
    }
    Keys.onDownPressed: {
        if (isLaunching || !detail) return
        for (var r = focusRow + 1; r <= 6; r++)
            if (rowAvailable(r)) { focusRow = r; break }
    }
    Keys.onLeftPressed: {
        if (isLaunching) return
        if (!detail) return
        if (focusRow === 0) {
            if (episodeItem && playCol > 0) playCol--
        } else if (focusRow === 1) {
            if (actionCol > 0) actionCol--
        } else if (focusRow === 2 && detail.audioStreams && detail.audioStreams.length > 1)
            audioIdx = (audioIdx - 1 + detail.audioStreams.length) % detail.audioStreams.length
        else if (focusRow === 3 && detail.subtitleStreams && detail.subtitleStreams.length > 1)
            subtitleIdx = (subtitleIdx - 1 + detail.subtitleStreams.length) % detail.subtitleStreams.length
        else if (focusRow === 4)
            detailRoot.cycleUpscaler(-1)
        else if (focusRow === 5 && detailRoot.castExtras.length > 0)
            detailRoot.castIndex = (detailRoot.castIndex - 1 + detailRoot.castExtras.length) % detailRoot.castExtras.length
        else if (focusRow === 6 && detailRoot.relatedItems.length > 0)
            detailRoot.relatedIndex = (detailRoot.relatedIndex - 1 + detailRoot.relatedItems.length) % detailRoot.relatedItems.length
    }
    Keys.onRightPressed: {
        if (isLaunching) return
        if (!detail) return
        if (focusRow === 0) {
            if (episodeItem && playCol < 2) playCol++
        } else if (focusRow === 1) {
            if (actionCol < 1) actionCol++
        } else if (focusRow === 2 && detail.audioStreams && detail.audioStreams.length > 1)
            audioIdx = (audioIdx + 1) % detail.audioStreams.length
        else if (focusRow === 3 && detail.subtitleStreams && detail.subtitleStreams.length > 1)
            subtitleIdx = (subtitleIdx + 1) % detail.subtitleStreams.length
        else if (focusRow === 4)
            detailRoot.cycleUpscaler(1)
        else if (focusRow === 5 && detailRoot.castExtras.length > 0)
            detailRoot.castIndex = (detailRoot.castIndex + 1) % detailRoot.castExtras.length
        else if (focusRow === 6 && detailRoot.relatedItems.length > 0)
            detailRoot.relatedIndex = (detailRoot.relatedIndex + 1) % detailRoot.relatedItems.length
    }
    Keys.onReturnPressed: {
        if (isLaunching) return
        if (focusRow === 1) {
            if (actionCol === 0) toggleWatched()
            else toggleTracked()
            return
        }
        if (focusRow === 6 && detailRoot.relatedItems.length > 0) {
            // Open the highlighted related title's info screen.
            detailRoot.navigateTo("Item.qml", { item: detailRoot.relatedItems[detailRoot.relatedIndex] })
            return
        }
        if (focusRow === 5 && detailRoot.castExtras.length > 0) {
            var card = detailRoot.castExtras[detailRoot.castIndex]
            if (card && card.kind === "extra" && card.ratingKey) {
                // Resolve and play the extra; loading overlay until it hands off.
                plexBackend.stop_theme()
                isLaunching = true
                sessionId = newSessionId()
                plexBackend.play_extra(card.ratingKey, sessionId)
            } else if (card && card.kind === "cast" && card.filter
                       && detail && detail.librarySectionID && detail.librarySectionID !== "0") {
                // Open the actor's filmography within this library.
                detailRoot.navigateTo("Items.qml", {
                    listType: "category_items",
                    sectionId: detail.librarySectionID,
                    categoryKey: card.filter,
                    title: card.title,
                    libraryName: card.title
                })
            }
            return
        }
        if (focusRow === 0 && detail && episodeItem && playCol !== 1) {
            // PREV/NEXT: swap this screen to the sibling episode in place.
            requestAdjacent(playCol === 0 ? -1 : 1)
            return
        }
        if (focusRow === 0 && detail) {
            // Stop the theme before handing off to the fullscreen player.
            plexBackend.stop_theme()
            // Show the loading overlay immediately; clears on navigate or error.
            isLaunching = true
            var audioId = detail.audioStreams && detail.audioStreams[audioIdx]
                ? detail.audioStreams[audioIdx].id : ""
            var subId = detail.subtitleStreams && detail.subtitleStreams[subtitleIdx]
                ? detail.subtitleStreams[subtitleIdx].id : "0"

            // Persist the picked tracks to Plex so they survive returning to
            // this screen, and so a transcode burns the streams the user chose
            // (the server selects from its stored default, not just inline
            // params). subtitleStreamID "0" disables subtitles.
            if (detail.partId) {
                if (audioId) plexBackend.set_audio_stream(audioId, detail.partId)
                plexBackend.set_subtitle_stream(subId, detail.partId)
            }

            // Fresh session per play so Plex builds a new transcode for this
            // exact selection instead of reusing the prior one.
            sessionId = newSessionId()

            if (detail.forceTranscode) {
                // Always transcode from the start so the full timeline is seekable.
                // The Player resumes by seeking mpv to viewOffset (see doStartPlayback),
                // which lets the user rewind past the resume point.
                plexBackend.request_transcode(detail.ratingKey, detail.partKey, sessionId, audioId, subId, 0)
            } else {
                plexBackend.build_stream_url(detail.ratingKey, detail.partKey, sessionId)
            }
        }
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

    // Fanart background — fit to height, full-bleed (aspect-preserving crop,
    // centered), dimmed by the info_background_opacity setting and overlaid
    // with CRT scanlines. z below every sibling so all content stacks above.
    // Opaque base beneath it so the fanart dims toward the theme surface color,
    // not the app background (which would otherwise bleed through the semi-
    // transparent fanart and tint it).
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
        source: (detailRoot.infoBg && detail && detail.art)
                ? plexBackend.image_url(detail.art, Math.round(root.sw), Math.round(root.sh))
                : ""
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
        subtitle: libraryName
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.125 //60
        anchors.leftMargin: root.sw * 0.125 //80
    }

    // Loading Indicator
    LoadingText {
        visible: !detail
        anchors.centerIn: parent
    }

    // Body
    Item {
        visible: detail !== null
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.25 //120
        anchors.leftMargin: root.sw * 0.115625 //74
        width: root.sw * 0.76875 //492
        height: root.sh * 0.525 //252
        clip: true

        // Section stack: the play/options block, the audio/subtitle settings,
        // and the More Like This row, stacked vertically and translated so the
        // section holding the current focusRow snaps to the top (see
        // sectionScroll). The parent Item clips the rest.
        Item {
            id: sectionStack
            width: parent.width
            y: -detailRoot.sectionScroll
            Behavior on y { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

        Row {
            id: itemDetails
            height: root.sh * 0.35 //168
            spacing: root.sw * 0.0375 //24

            // Play cluster (PREV/PLAY/NEXT) stacked over the WATCHED/TRACKED
            // action buttons. PREV/NEXT appear for episodes only and swap this
            // screen to the sibling episode; PLAY behaves exactly as before.
            Column {
                spacing: root.sh * 0.0125 //6

            Item {
                id: playCluster
                width: root.sw * 0.1875 //120
                height: root.sh * 0.1166667 //56

                Row {
                    anchors.fill: parent
                    spacing: root.sw * 0.0046875 //3

                    Rectangle {
                        id: prevButton
                        visible: detailRoot.episodeItem
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
                            text: "\u25C4"
                            color: prevButton.sel ? root.surfaceColor : root.primaryColor
                            font.family: root.globalFont
                            font.pixelSize: root.sh * 0.0416667 //20
                        }
                    }

                    Rectangle {
                        id: playButton
                        property bool sel: focusRow === 0 && (!detailRoot.episodeItem || playCol === 1)
                        color: sel ? root.accentColor : root.surfaceColor
                        border.color: sel ? root.accentColor : root.tertiaryColor
                        width: detailRoot.episodeItem ? root.sw * 0.1 : root.sw * 0.1875
                        height: parent.height
                        border.width: root.sh * 0.003125 //2

                        // Touch: first tap focuses the PLAY button, tapping it while
                        // focused activates it via a synthesized Enter.
                        MouseArea {
                            anchors.fill: parent
                            onClicked: {
                                if (playButton.sel) inputManager.touchKey("select")
                                else { focusRow = 0; playCol = 1 }
                            }
                        }

                        Text {
                            anchors.centerIn: parent
                            text: (detail && detail.viewOffset > 0) ? "RSUM \u25BA" : "PLAY \u25BA"
                            color: playButton.sel ? root.surfaceColor : root.primaryColor
                            font.family: root.globalFont
                            font.pixelSize: detailRoot.episodeItem ? root.sh * 0.0375 : root.sh * 0.05
                        }
                    }

                    Rectangle {
                        id: nextButton
                        visible: detailRoot.episodeItem
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
                            text: "\u25BA"
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
                    // Match the play cluster's total width (0.1875): two buttons split
                    // it with the same 3px gap; WATCHED takes it all when TRACKED hides.
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
                    // "Remove from Continue Watching" only applies to in-progress items.
                    visible: detail && detail.viewOffset > 0
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
            }

            Column {
                topPadding: root.sh * 0.0083333 //4
                // Narrower when the thumbnail is showing beside it.
                width: detailThumb.visible ? root.sw * 0.35 : root.sw * 0.54375
                spacing: root.sh * 0.0166667 //8

                //Name
                Text {
                    text: {
                        var base = (item.type === "episode" && item.grandparentTitle)
                                   ? item.grandparentTitle : item.title
                        return item.editionTitle ? base + " (" + item.editionTitle + ")" : base
                    }
                    color: root.primaryColor
                    font.family: root.globalFont
                    font.capitalization: Font.AllUppercase
                    elide: Text.ElideRight
                    width: parent.width
                    font.pixelSize: root.sh * 0.05 //24
                }

                // Year & Duration / Episode identifier
                Text {
                    text: {
                        if (!detail) return ""
                        if (item.type === "episode") {
                            var sNum = (item.parentIndex != null) ? item.parentIndex
                                       : ((detail.parentIndex != null) ? detail.parentIndex : "?")
                            var eNum = item.index || detail.index || "?"
                            return "S" + sNum + "E" + eNum + ": " + item.title
                        }
                        var parts = []
                        if (detail.year) parts.push(String(detail.year))
                        if (detail.duration) parts.push(durationStr(detail.duration))
                        return parts.join(" - ")
                    }
                    color: root.secondaryColor
                    font.family: root.globalFont
                    font.capitalization: Font.AllUppercase
                    elide: Text.ElideRight
                    width: parent.width
                    font.pixelSize: root.sh * 0.0333333 //16
                }

                // Summary
                Item {
                    id: summaryContainer
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: root.sh * 0.1375 //66
                    clip: true

                    Text {
                        id: summaryText
                        anchors.left: parent.left
                        anchors.right: parent.right
                        text: detail ? detail.summary : ""
                        color: root.primaryColor
                        font.family: root.globalFont
                        wrapMode: Text.WordWrap
                        font.pixelSize: root.sh * 0.0291667 //14
                        lineHeight: 1.3
                    }

                    SequentialAnimation {
                        running: detail !== null && summaryText.implicitHeight > summaryContainer.height
                        loops: Animation.Infinite
                        onRunningChanged: if (!running) summaryText.y = 0
                        PauseAnimation { duration: 3000 }
                        NumberAnimation {
                            target: summaryText; property: "y"
                            to: summaryContainer.height - summaryText.implicitHeight
                            duration: Math.abs(to) * 120
                        }
                        PauseAnimation { duration: 4000 }
                        PropertyAction { target: summaryText; property: "y"; value: 0 }
                    }
                }
            }

            // Thumbnail: 16:9 still for episodes, poster for movies — the box
            // fits either via PreserveAspectFit. Hidden until loaded so the
            // text-only layout stands on its own when there is no image.
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
                    source: (detail && detail.thumb)
                            ? plexBackend.image_url(detail.thumb,
                                                    Math.round(width), Math.round(height))
                            : ""
                }
            }
        }

        // Playback Settings
        Text {
            id: pbSettingsLabel
            text: "Playback Settings:"
            color: root.secondaryColor
            font.family: root.globalFont
            font.capitalization: Font.AllUppercase
            anchors.top: itemDetails.bottom
            anchors.topMargin: root.sh * 0.0145833 //7
            leftPadding: root.sw * 0.009375 //6
            rightPadding: root.sw * 0.009375 //6
            font.pixelSize: root.sh * 0.0291667 //14
        }

        // AUDIO row
        Item {
            id: audioRow
            visible: detail && detail.audioStreams && detail.audioStreams.length > 0
            anchors.top: pbSettingsLabel.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.topMargin: root.sh * 0.0145833 //7
            height: root.sh * 0.0583333 //28

            // Touch: first tap focuses the row; tapping the focused row cycles
            // its value forward, reusing the LEFT/RIGHT keyboard handlers.
            // Declared before the value Row so its arrows stack on top.
            MouseArea {
                anchors.fill: parent
                onClicked: {
                    if (focusRow === 2) inputManager.touchKey("right")
                    else focusRow = 2
                }
            }

            Rectangle {
                anchors.fill: parent
                color: focusRow === 2 ? root.accentColor : "transparent"
            }

            Text {
                text: "Audio"
                color: focusRow === 2 ? root.surfaceColor : root.primaryColor
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: root.sw * 0.009375 //6
                font.pixelSize: root.sh * 0.0416667 //20
            }

            Row {
                anchors.verticalCenter: parent.verticalCenter
                anchors.right: parent.right
                anchors.rightMargin: root.sw * 0.009375 //6
                spacing: root.sw * 0.00625 //4

                Text {
                    text: "\u25C4"
                    color: focusRow === 2 ? root.surfaceColor : root.tertiaryColor
                    font.family: root.globalFont
                    anchors.verticalCenter: parent.verticalCenter
                    font.pixelSize: root.sh * 0.0375 //18

                    // Tap \u25C4 to cycle backward (row must be focused first; a
                    // stray tap focuses it instead of changing it).
                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -root.sh * 0.0125
                        onClicked: {
                            if (focusRow === 2) inputManager.touchKey("left")
                            else focusRow = 2
                        }
                    }
                }
                Text {
                    text: (detail && detail.audioStreams && detail.audioStreams[audioIdx])
                          ? detail.audioStreams[audioIdx].displayTitle : ""
                    color: focusRow === 2 ? root.surfaceColor : root.primaryColor
                    font.family: root.globalFont
                    font.capitalization: Font.AllUppercase
                    anchors.verticalCenter: parent.verticalCenter
                    font.pixelSize:root.sh * 0.0416667 //20
                }
                Text {
                    text: "\u25BA"
                    color: focusRow === 2 ? root.surfaceColor : root.tertiaryColor
                    font.family: root.globalFont
                    anchors.verticalCenter: parent.verticalCenter
                    font.pixelSize: root.sh * 0.0375 //18

                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -root.sh * 0.0125
                        onClicked: {
                            if (focusRow === 2) inputManager.touchKey("right")
                            else focusRow = 2
                        }
                    }
                }
            }
        }

        // SUBTITLES row
        Item {
            id: subtitleRow
            visible: detail && detail.subtitleStreams && detail.subtitleStreams.length > 1
            anchors.top: audioRow.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: root.sh * 0.0583333 //28

            MouseArea {
                anchors.fill: parent
                onClicked: {
                    if (focusRow === 3) inputManager.touchKey("right")
                    else focusRow = 3
                }
            }

            Rectangle {
                anchors.fill: parent
                color: focusRow === 3 ? root.accentColor : "transparent"
            }

            Text {
                text: "Subtitles"
                color: focusRow === 3 ? root.surfaceColor : root.primaryColor
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: root.sw * 0.009375 //6
                font.pixelSize: root.sh * 0.0416667 //20
            }

            Row {
                anchors.verticalCenter: parent.verticalCenter
                anchors.right: parent.right
                anchors.rightMargin: root.sw * 0.009375 //6
                spacing: root.sw * 0.00625 //4

                Text {
                    text: "\u25C4"
                    color: focusRow === 3 ? root.surfaceColor : root.tertiaryColor
                    font.family: root.globalFont
                    anchors.verticalCenter: parent.verticalCenter
                    font.pixelSize: root.sh * 0.0375 //18

                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -root.sh * 0.0125
                        onClicked: {
                            if (focusRow === 3) inputManager.touchKey("left")
                            else focusRow = 3
                        }
                    }
                }
                Text {
                    text: (detail && detail.subtitleStreams && detail.subtitleStreams[subtitleIdx])
                          ? detail.subtitleStreams[subtitleIdx].displayTitle : ""
                    color: focusRow === 3 ? root.surfaceColor : root.primaryColor
                    font.family: root.globalFont
                    font.capitalization: Font.AllUppercase
                    anchors.verticalCenter: parent.verticalCenter
                    font.pixelSize:root.sh * 0.0416667 //20
                }
                Text {
                    text: "\u25BA"
                    color: focusRow === 3 ? root.surfaceColor : root.tertiaryColor
                    font.family: root.globalFont
                    anchors.verticalCenter: parent.verticalCenter
                    font.pixelSize: root.sh * 0.0375 //18

                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -root.sh * 0.0125
                        onClicked: {
                            if (focusRow === 3) inputManager.touchKey("right")
                            else focusRow = 3
                        }
                    }
                }
            }
        }

        // UPSCALER row — cycles the global "mpv_upscaler" setting (applied by the
        // player on the next playback). Part of the Playback Settings block.
        Item {
            id: upscalerRow
            anchors.top: subtitleRow.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: root.sh * 0.0583333 //28

            MouseArea {
                anchors.fill: parent
                onClicked: {
                    if (focusRow === 4) inputManager.touchKey("right")
                    else focusRow = 4
                }
            }

            Rectangle {
                anchors.fill: parent
                color: focusRow === 4 ? root.accentColor : "transparent"
            }

            Text {
                text: "Upscaler"
                color: focusRow === 4 ? root.surfaceColor : root.primaryColor
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: root.sw * 0.009375 //6
                font.pixelSize: root.sh * 0.0416667 //20
            }

            Row {
                anchors.verticalCenter: parent.verticalCenter
                anchors.right: parent.right
                anchors.rightMargin: root.sw * 0.009375 //6
                spacing: root.sw * 0.00625 //4

                Text {
                    text: "◄"
                    color: focusRow === 4 ? root.surfaceColor : root.tertiaryColor
                    font.family: root.globalFont
                    anchors.verticalCenter: parent.verticalCenter
                    font.pixelSize: root.sh * 0.0375 //18

                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -root.sh * 0.0125
                        onClicked: {
                            if (focusRow === 4) inputManager.touchKey("left")
                            else focusRow = 4
                        }
                    }
                }
                Text {
                    text: detailRoot.upscalers[detailRoot.upscalerIdx].label
                    color: focusRow === 4 ? root.surfaceColor : root.primaryColor
                    font.family: root.globalFont
                    font.capitalization: Font.AllUppercase
                    anchors.verticalCenter: parent.verticalCenter
                    font.pixelSize:root.sh * 0.0416667 //20
                }
                Text {
                    text: "►"
                    color: focusRow === 4 ? root.surfaceColor : root.tertiaryColor
                    font.family: root.globalFont
                    anchors.verticalCenter: parent.verticalCenter
                    font.pixelSize: root.sh * 0.0375 //18

                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -root.sh * 0.0125
                        onClicked: {
                            if (focusRow === 4) inputManager.touchKey("right")
                            else focusRow = 4
                        }
                    }
                }
            }
        }

        // SECTION: Cast & Extras — actor headshots (name + character) and any
        // extras (trailers/featurettes), same reveal-on-scroll as More Like This.
        // Informational for now: navigable to browse, no per-card action.
        Item {
            id: castSection
            visible: detailRoot.castExtras.length > 0
            anchors.top: upscalerRow.bottom
            anchors.topMargin: visible ? root.sh * 0.03 : 0
            anchors.left: parent.left
            anchors.right: parent.right
            height: visible ? (castLabel.height + root.sh * 0.0083333 + castList.height) : 0

            Text {
                id: castLabel
                text: "Cast & Extras"
                color: detailRoot.focusRow === 5 ? root.accentColor : root.secondaryColor
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                anchors.top: parent.top
                anchors.left: parent.left
                font.pixelSize: root.sh * 0.0375 //18
            }

            ListView {
                id: castList
                model: detailRoot.castExtras
                orientation: ListView.Horizontal
                anchors.top: castLabel.bottom
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
                    id: ceCard
                    property bool isExtra: modelData.kind === "extra"
                    height: castList.height
                    // Extras get a 16:9 thumbnail (landscape); cast a 2:3 headshot
                    // (portrait), so the two kinds read differently at a glance.
                    width: (castList.height * 0.66) * (isExtra ? (16 / 9) : (2 / 3))
                    property bool sel: detailRoot.focusRow === 5 && detailRoot.castIndex === index

                    Column {
                        anchors.fill: parent
                        spacing: root.sh * 0.0083333

                        Rectangle {
                            id: cBox
                            width: parent.width
                            height: castList.height * 0.66   // image; text below
                            color: "transparent"
                            border.color: sel ? root.accentColor : root.tertiaryColor
                            border.width: sel ? Math.max(2, Math.floor(root.sh * 0.00625)) : 1

                            Image {
                                id: cImg
                                anchors.fill: parent
                                anchors.margins: cBox.border.width
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                source: modelData.image
                                        ? plexBackend.image_url(modelData.image, Math.round(cBox.width), Math.round(cBox.height))
                                        : ""
                            }
                            // Imageless / broken cards: a play glyph for extras, initial for cast.
                            Text {
                                visible: !modelData.image || cImg.status === Image.Error
                                anchors.centerIn: parent
                                text: modelData.kind === "extra" ? "▶" : (modelData.title || "?").charAt(0)
                                color: root.secondaryColor
                                font.family: root.globalFont
                                font.capitalization: Font.AllUppercase
                                font.pixelSize: root.sh * 0.05
                            }
                        }
                        Text {
                            width: parent.width
                            text: modelData.title || ""
                            color: sel ? root.accentColor : root.primaryColor
                            font.family: root.globalFont
                            font.capitalization: Font.AllUppercase
                            elide: Text.ElideRight
                            maximumLineCount: 1
                            font.pixelSize: root.sh * 0.0233333 //~11
                        }
                        Text {
                            width: parent.width
                            text: modelData.subtitle || ""
                            color: root.tertiaryColor
                            font.family: root.globalFont
                            font.capitalization: Font.AllUppercase
                            elide: Text.ElideRight
                            maximumLineCount: 1
                            font.pixelSize: root.sh * 0.02 //~10
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: {
                            if (detailRoot.focusRow === 5 && detailRoot.castIndex === index)
                                inputManager.touchKey("select")
                            else { detailRoot.focusRow = 5; detailRoot.castIndex = index }
                        }
                    }
                }
            }
        }

        // SECTION: More Like This — a full-size boxart row (matching the browse /
        // Continue Watching cover grid) below the audio/subtitle settings.
        Item {
            id: relatedSection
            visible: detailRoot.showRelated && detailRoot.relatedItems.length > 0
            anchors.top: castSection.bottom
            anchors.topMargin: root.sh * 0.03
            anchors.left: parent.left
            anchors.right: parent.right
            height: relatedLabel.height + root.sh * 0.0083333 + relatedList.height

            Text {
                id: relatedLabel
                text: "More Like This"
                color: detailRoot.focusRow === 6 ? root.accentColor : root.secondaryColor
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                anchors.top: parent.top
                anchors.left: parent.left
                font.pixelSize: root.sh * 0.0375 //18
            }

            ListView {
                id: relatedList
                model: detailRoot.relatedItems
                orientation: ListView.Horizontal
                anchors.top: relatedLabel.bottom
                anchors.topMargin: root.sh * 0.0083333
                anchors.left: parent.left
                anchors.right: parent.right
                height: root.sh * 0.245   // matches the cover-grid poster height
                spacing: root.sw * 0.0125
                clip: true
                interactive: false
                currentIndex: detailRoot.relatedIndex
                onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)

                delegate: Item {
                    height: relatedList.height
                    width: height * (2 / 3)   // portrait poster, like the cover grid

                    Rectangle {
                        id: relBox
                        anchors.fill: parent
                        color: "transparent"
                        border.color: (detailRoot.focusRow === 6 && detailRoot.relatedIndex === index)
                                      ? root.accentColor : root.tertiaryColor
                        border.width: (detailRoot.focusRow === 6 && detailRoot.relatedIndex === index)
                                      ? Math.max(2, Math.floor(root.sh * 0.00625)) : 1

                        Image {
                            anchors.fill: parent
                            anchors.margins: relBox.border.width
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            source: modelData.poster
                                    ? plexBackend.image_url(modelData.poster, Math.round(relatedList.height * 2 / 3), Math.round(relatedList.height))
                                    : ""
                        }
                        Text {
                            visible: !modelData.poster
                            anchors.fill: parent
                            anchors.margins: root.sw * 0.0078125
                            text: modelData.title || ""
                            color: root.secondaryColor
                            font.family: root.globalFont
                            font.capitalization: Font.AllUppercase
                            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                            elide: Text.ElideRight
                            font.pixelSize: root.sh * 0.025 //12
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: {
                            if (detailRoot.focusRow === 6 && detailRoot.relatedIndex === index)
                                inputManager.touchKey("select")
                            else { detailRoot.focusRow = 6; detailRoot.relatedIndex = index }
                        }
                    }
                }
            }
        }
        }   // sectionStack

    }

    // Footer
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

    // Launch overlay — covers the detail screen while Plex prepares the stream
    // so a slow server doesn't make the app look frozen after pressing PLAY.
    Rectangle {
        anchors.fill: parent
        color: root.surfaceColor
        visible: isLaunching
        z: 100

        LoadingText {
            anchors.centerIn: parent
        }

        Text {
            text: root.hints.back + ":CANCEL"
            color: root.tertiaryColor
            font.family: root.globalFont
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: root.sh * 0.1041667 //50
            font.pixelSize: root.sh * 0.0333333 //16
        }
    }
}
