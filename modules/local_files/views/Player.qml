import QtQuick

FocusScope {
    id: playerRoot

    property var navParams: ({})

    signal goBack()

    property string filePath:    navParams.filePath || ""
    property string itemTitle:   navParams.title    || ""
    // Display title for the mpv OSC, and the folder's sibling videos so the
    // OSC's |< / >| can step through them (passed by Detail.qml; absent when
    // playing playlists/images straight from the list).
    property string mediaTitle:   navParams.mediaTitle || navParams.title || ""
    property var    siblings:     navParams.siblings || []
    property int    siblingIndex: navParams.siblingIndex !== undefined ? navParams.siblingIndex : -1

    property bool   overlayVisible:      false
    property int    savedPositionMs:     0
    property int    savedPlaylistPos:    -1
    property int    choiceIndex:         0
    property bool   loopOn:              false
    property bool   shuffleOn:           false
    property string resumeSetting:       "ask"
    property string subtitleMode:        "forced"
    property var    subtitleLangs:       []
    property int    imageDurationSec:    5

    // True when playback is images (a standalone image, or a playlist that contains
    // at least one image). Gates the slideshow-redraw mpv script — see MpvController.
    property bool   imageContent:        false

    // mpv subtitle-track flag derived from subtitleMode: 0 = on, -1 = forced only, -2 = off.
    property int    subFlag:             (subtitleMode == "on") ? 0 : ((subtitleMode == "forced") ? -1 : -2)

    // Track last non-null values during playback for robust save on exit
    property int    lastKnownPositionMs:  0
    property int    lastKnownDurationMs:  0
    property int    lastKnownPlaylistPos: -1

    // Playlist resume correction: --start=T is global so every subsequent
    // video in the playlist would also start at T. We track which playlist
    // position was resumed from and seek to 0 on the first position event
    // after each advancement past that point.
    property int    resumedFromPlaylistPos: -1
    property bool   needsSeekToZero:        false

    focus: true

    Keys.onPressed: function(event) {
        if (overlayVisible) {
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                goBack()
                event.accepted = true
            } else if (event.key === Qt.Key_Up) {
                choiceIndex = 0
                event.accepted = true
            } else if (event.key === Qt.Key_Down) {
                choiceIndex = 1
                event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                var startMs    = choiceIndex === 0 ? savedPositionMs  : 0
                var startPlPos = choiceIndex === 0 ? savedPlaylistPos : -1
                if (choiceIndex === 0 && startPlPos >= 0)
                    resumedFromPlaylistPos = startPlPos
                overlayVisible = false
                mpvController.loadAndPlay(filePath, startMs / 1000.0, 0, subFlag, [], subtitleLangs, loopOn, startPlPos, 0.0, "", false, "", false, [], imageDurationSec, imageContent, playerExtraArgs())
                event.accepted = true
            }
        } else {
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Back) {
                mpvController.sendKey("ESC")
                event.accepted = true
            } else if (event.key === Qt.Key_Backspace) {
                mpvController.sendKey("BS")
                event.accepted = true
            } else if (event.key === Qt.Key_Up) {
                mpvController.sendKey("UP")
                event.accepted = true
            } else if (event.key === Qt.Key_Down) {
                mpvController.sendKey("DOWN")
                event.accepted = true
            } else if (event.key === Qt.Key_Left) {
                mpvController.sendKey("LEFT")
                event.accepted = true
            } else if (event.key === Qt.Key_Right) {
                mpvController.sendKey("RIGHT")
                event.accepted = true
            } else if (event.key === Qt.Key_Space) {
                mpvController.sendKey("SPACE")
                event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                mpvController.sendKey("ENTER")
                event.accepted = true
            }
        }
    }

    // Per-playback mpv extras: OSC title, and the |< / >| buttons when the
    // folder has sibling videos to step through.
    function playerExtraArgs() {
        var args = []
        if (mediaTitle) args.push("--force-media-title=" + mediaTitle)
        if (siblings.length > 1) args.push("--script-opts-append=episode-nav=1")
        return args
    }

    // Save-or-clear the resume position for the current single file (mirrors
    // onPlaybackEnded's rules) — used before swapping to a sibling.
    function saveCurrentPosition() {
        var pos = lastKnownPositionMs
        var dur = lastKnownDurationMs
        if (isPlaylist(filePath) || isImage(filePath)) return
        if (dur > 0 && pos >= dur * 0.95)
            localFilesBackend.clearPosition(filePath)
        else if (pos > 5000)
            localFilesBackend.savePosition(filePath, pos, -1, dur)
    }

    Connections {
        target: mpvController

        // The OSC's |< / >| with sibling videos: save the current position,
        // swap the player context, and start the sibling from the beginning.
        // loadAndPlay replaces the running mpv.
        function onEpisodeNavRequested(direction) {
            if (siblings.length < 2 || siblingIndex < 0) return
            var next = siblingIndex + (direction === "next" ? 1 : -1)
            if (next < 0 || next >= siblings.length) return
            saveCurrentPosition()
            siblingIndex = next
            filePath   = siblings[next].path
            itemTitle  = siblings[next].name
            mediaTitle = siblings[next].mediaTitle || siblings[next].name
            lastKnownPositionMs  = 0
            lastKnownDurationMs  = 0
            lastKnownPlaylistPos = -1
            mpvController.loadAndPlay(filePath, 0.0, 0, subFlag, [], subtitleLangs, loopOn, -1, 0.0, "", false, "", false, [], imageDurationSec, imageContent, playerExtraArgs())
        }

        function onPositionChanged(ms) {
            if (ms > 0) {
                if (needsSeekToZero) {
                    needsSeekToZero = false
                    mpvController.seekTo(0)
                    return
                }
                playerRoot.lastKnownPositionMs = ms
            }
        }
        function onDurationChanged(ms) {
            if (ms > 0) playerRoot.lastKnownDurationMs = ms
        }
        function onPlaylistPosChanged(pos) {
            if (pos >= 0) {
                if (resumedFromPlaylistPos >= 0 && pos > resumedFromPlaylistPos)
                    needsSeekToZero = true
                playerRoot.lastKnownPlaylistPos = pos
                playerRoot.lastKnownPositionMs  = 0
            }
        }

        // mpv exited for any reason ("eof"/"stopped"/"failed"). Local Files has no
        // autoplay-next or transcode-retry, so every exit is handled the same way:
        // save/clear the resume position and return to the menu. Handling the single
        // playbackEnded signal here is what keeps the app from freezing on a natural
        // end-of-file (the original bug was a missing per-reason handler).
        function onPlaybackEnded(finalPositionMs, finalDurationMs, reason) {
            var pos   = lastKnownPositionMs  || finalPositionMs
            var dur   = lastKnownDurationMs  || finalDurationMs
            var plPos = lastKnownPlaylistPos

            if (isPlaylist(filePath)) {
                // Always save playlist state — skip completion detection
                if (pos > 0 || plPos >= 0)
                    localFilesBackend.savePosition(filePath, pos, plPos, dur)
            } else if (!isImage(filePath)) {
                // Single file: clear if near completion, save otherwise.
                // Images carry no resume position, so they never write history.
                if (dur > 0 && pos >= dur * 0.95)
                    localFilesBackend.clearPosition(filePath)
                else if (pos > 5000)
                    localFilesBackend.savePosition(filePath, pos, -1, dur)
            }
            goBack()
        }
    }

    Component.onCompleted: {
        if (filePath === "") return
        loopOn        = !!appCore.get_setting(moduleRoot.moduleId, "loop_playback")
        shuffleOn     = !!appCore.get_setting(moduleRoot.moduleId, "shuffle_playback")
        // Some fancy logic to honor the old boolean setting until it gets updated to the new format
        var autoSubs  = appCore.get_setting(moduleRoot.moduleId, "auto_subtitles")
        subtitleMode  = (typeof autoSubs === "boolean") ? ((autoSubs === true) ? "on" : "forced") : (autoSubs || "forced")
        resumeSetting = appCore.get_setting(moduleRoot.moduleId, "resume_playback") || "ask"
        var imgDur = parseFloat(appCore.get_setting(moduleRoot.moduleId, "image_duration"))
        imageDurationSec = isNaN(imgDur) ? 5 : imgDur

        imageContent = isImage(filePath) ||
                       (isPlaylist(filePath) && localFilesBackend.playlistContainsImages(filePath))

        // Leaving this as an array since MPV - like most players - expects a *list* of languages
        // to progressively fall back to until a sub track is found. If we ever switch back to
        // selecting a list in Settings, the change to support them all will be considerably simpler.
        // "-" is the value we store for "Any" (i.e. no preference) thats also the manifest default and
        // "Any" option's id. If the user never opened this setting, then get_setting returns nothing,
        // so it will fall back to "-" too. With this, "haven't picked one" will behave the same as "Any":
        // the check below adds nothing to the list and MPV is launched without a --slang preference.
        var subLangString = appCore.get_setting(moduleRoot.moduleId, "sub_lang") || "-"
        subtitleLangs = []
        if (subLangString !== "-") {
            subtitleLangs.push(subLangString)
        }

        // Shuffle wins: a shuffled playlist starts fresh & random; resume position
        // (a sequential item index) is meaningless once order is randomized.
        if (shuffleOn && isPlaylist(filePath)) {
            mpvController.loadAndPlay(filePath, 0.0, 0, subFlag, [], subtitleLangs, loopOn, -1, 0.0, "", false, "", true, [], imageDurationSec, imageContent, playerExtraArgs())
            return
        }

        // A standalone image has no meaningful playback position, so it bypasses
        // resume entirely (no saved-position lookup, no "RESUME PLAYBACK?" overlay).
        // Images inside a playlist still resume via the playlist's item index below.
        if (!isPlaylist(filePath) && isImage(filePath)) {
            mpvController.loadAndPlay(filePath, 0.0, 0, subFlag, [], subtitleLangs, loopOn, -1, 0.0, "", false, "", false, [], imageDurationSec, imageContent, playerExtraArgs())
            return
        }

        if (resumeSetting === "no") {
            mpvController.loadAndPlay(filePath, 0.0, 0, subFlag, [], subtitleLangs, loopOn, -1, 0.0, "", false, "", false, [], imageDurationSec, imageContent, playerExtraArgs())
            return
        }

        var saved    = localFilesBackend.getSavedPosition(filePath)
        var savedPos = saved.pos   || 0
        var savedPl  = (saved.plPos !== undefined && saved.plPos !== null) ? saved.plPos : -1

        if (resumeSetting === "yes") {
            if (savedPos > 0 && savedPl >= 0)
                resumedFromPlaylistPos = savedPl
            mpvController.loadAndPlay(filePath, savedPos > 0 ? savedPos / 1000.0 : 0.0,
                                      0, subFlag, [], subtitleLangs, loopOn, savedPos > 0 ? savedPl : -1, 0.0, "", false, "", false, [], imageDurationSec, imageContent, playerExtraArgs())
        } else {
            if (savedPos > 0) {
                savedPositionMs  = savedPos
                savedPlaylistPos = savedPl
                overlayVisible   = true
            } else {
                mpvController.loadAndPlay(filePath, 0.0, 0, subFlag, [], subtitleLangs, loopOn, -1, 0.0, "", false, "", false, [], imageDurationSec, imageContent, playerExtraArgs())
            }
        }
    }

    Rectangle {
        anchors.fill: parent
        color: "black"
    }

    Rectangle {
        anchors.fill: parent
        color: root.surfaceColor
        visible: overlayVisible

        Rectangle {
            id: dialogRect
            color: root.surfaceColor
            anchors.centerIn: parent
            width: root.sw * 0.76875 //492
            height: root.sh * 0.2833333 //136

            Column {
                id: dialogColumn
                anchors.fill: parent
                spacing: root.sh * 0.05 //24

                Text {
                    text: "RESUME PLAYBACK?"
                    color: root.secondaryColor
                    font.family: root.globalFont
                    font.pixelSize: root.sh * 0.0333333 //16
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                Column {
                    Repeater {
                        model: [
                            savedPlaylistPos >= 0
                                ? "Resume video " + (savedPlaylistPos + 1) + " at " + formatTime(savedPositionMs)
                                : "Resume from " + formatTime(savedPositionMs),
                            "Start from the beginning"
                        ]
                        delegate: Item {
                            width: dialogColumn.width
                            height: root.sh * 0.0583333 //28

                            Rectangle {
                                anchors.fill: delegateText
                                color: root.accentColor
                                visible: index === choiceIndex
                            }

                            Text {
                                id: delegateText
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: modelData
                                color: index === choiceIndex ? root.surfaceColor : root.primaryColor
                                font.family: root.globalFont
                                font.capitalization: Font.AllUppercase
                                topPadding: root.sh * 0.0041667 //2
                                leftPadding: root.sw * 0.009375 //6
                                rightPadding: root.sw * 0.009375 //6
                                bottomPadding: root.sh * 0.00625 //3
                                font.pixelSize: root.sh * 0.0416667 //20
                            }

                            // Touch: tap selects the option, tapping the selected
                            // option confirms it via a synthesized Enter.
                            MouseArea {
                                anchors.fill: parent
                                onClicked: {
                                    if (choiceIndex === index) inputManager.touchKey("select")
                                    else choiceIndex = index
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

    function isPlaylist(path) {
        return localFilesBackend.isPlaylist(path)
    }

    function isImage(path) {
        return localFilesBackend.isImage(path)
    }

    function formatTime(ms) {
        var s   = Math.floor(ms / 1000)
        var h   = Math.floor(s / 3600)
        var m   = Math.floor((s % 3600) / 60)
        var sec = s % 60
        if (h > 0)
            return h + ":" + pad(m) + ":" + pad(sec)
        return m + ":" + pad(sec)
    }

    function pad(n) { return n < 10 ? "0" + n : "" + n }
}
