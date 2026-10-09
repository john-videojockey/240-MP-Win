import QtQuick
import QtQuick.Window
import Components
import "TrackPicks.js" as TrackPicks

FocusScope {
    id: playerRoot

    property var navParams: ({})

    signal navigateTo(string path, var params)
    signal goBack()
    // Emitted when autoplay advances in place, so Root can repoint the BACK
    // target to the now-playing episode's detail instead of the original one.
    signal updateBackItem(var item)

    property string streamUrl:    navParams.streamUrl    || ""
    property string plexToken:    navParams.plexToken    || ""
    property string ratingKey:    navParams.ratingKey    || ""
    property string partKey:      navParams.partKey      || ""
    property string partId:       navParams.partId       || ""
    property string sessionId:    navParams.sessionId    || ""
    property int    viewOffset:   navParams.viewOffset   || 0
    property string itemTitle:    navParams.title        || ""
    // Display title for the mpv OSC ("SHOW - S1E2 - TITLE"); falls back to the
    // bare item title. episodeNav unlocks the OSC's |< / >| episode buttons.
    property string mediaTitle:   navParams.mediaTitle   || navParams.title || ""
    property bool   episodeNav:   navParams.episodeNav   || false
    property var    audioStreams:     navParams.audioStreams     || []
    property var    subtitleStreams:  navParams.subtitleStreams  || []
    property int    audioIdx:    0
    property int    subtitleIdx: 0
    property bool   isTranscoding:    navParams.isTranscoding    || false
    property var    imageSubtitleIds: navParams.imageSubtitleIds || []
    property string selectedAudioId:    navParams.selectedAudioId    || ""
    property string selectedSubtitleId: navParams.selectedSubtitleId || "0"
    // Per-show key ("plex:<showKey>") the audio/subtitle choices are remembered under
    // (TrackPicks.js); empty for a clip such as a trailer.
    property string titleKey:     navParams.titleKey     || ""

    property bool stoppedReported:    false
    property bool playbackStarted:    false
    property bool overlayVisible:     false
    property int  choiceIndex:        0
    property string resumeSetting:    "ask"
    property bool pendingRetryTranscode: false

    // Autoplay-next-episode. When enabled, a natural end-of-file advances to the
    // next episode in the same season, carrying over the audio/subtitle language.
    property bool   autoplayNext:       false
    property bool   pendingNextEpisode: false
    // Set when the OSC's >| button asked for the next episode (mpv is still
    // playing); a no-next-episode answer then just keeps playing instead of
    // exiting like the end-of-file autoplay path does.
    property bool   nextViaButton:      false
    // Set when an episode finished (eof) but autoplay is OFF: rather than play the
    // next one, repoint BACK to it so exiting lands on the next episode's info
    // screen instead of re-showing the one just watched.
    property bool   landOnNextInfo:     false
    property string carryAudioLang:     ""        // language code of the chosen audio track
    property string carrySubLang:       "__off__" // language code, or "__off__" when subtitles are off

    // Pause-suspend: once a stream has been paused for pauseGraceMs, tear it down
    // to release the server's stream slot (a paused Plex session still counts
    // against the simultaneous-stream limit), hold the last frame, and reload at
    // the same position on resume. `suspended` = mpv is gone and the held frame is
    // shown awaiting resume; `resuming` = the stream is being rebuilt until its
    // first frame is back; `pendingResume` routes the rebuilt URL back to mpv.
    property bool   idleModeEnabled:   true   // Plex setting "idle_mode"
    readonly property int pauseGraceMs: 60000
    property bool   suspended:         false
    property bool   resuming:          false
    property bool   pendingResume:     false
    property int    suspendedOffsetMs: 0
    property int    suspendedCropState: -1  // mpvController.cropState at release; -1 = unknown
    property string heldFrameUrl:      ""
    property string _pendingShot:      ""   // grab in flight until the file is written

    // Skip Intro (Plex intro markers). intro_skip is Off / Auto / Button.
    property var    segments:         []
    property var    activeSegment:    null
    property bool   skipPromptShown:  false
    property bool   introAutoSkipped: false
    property string introSkipSetting: "Off"
    property bool   markersFetched:   false

    property int lastKnownPositionMs: 0
    property int lastKnownDurationMs: 0

    function findActiveSegment(ms) {
        for (var i = 0; i < segments.length; i++)
            if (ms >= segments[i].startMs && ms < segments[i].endMs) return segments[i]
        return null
    }
    function resetSkipState() {
        segments = []
        activeSegment = null
        skipPromptShown = false
        introAutoSkipped = false
        markersFetched = false
        mpvController.clearOsdPrompt()
    }

    focus: true

    Keys.onPressed: function(event) {
        if (playerRoot.suspended) {
            // mpv is gone; this view owns the keys. Back exits (stop was already
            // reported); Play/Select/media-play resume by reloading the stream.
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                goBack()
            } else if (event.key === Qt.Key_Space || event.key === Qt.Key_Return
                       || event.key === Qt.Key_Enter || event.key === Qt.Key_MediaTogglePlayPause
                       || event.key === Qt.Key_MediaPlay || event.key === Qt.Key_MediaPause) {
                resumeFromSuspend()
            }
            event.accepted = true
            return
        }
        if (playerRoot.resuming) {
            event.accepted = true   // swallow input during the brief re-buffer
            return
        }
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
                overlayVisible = false
                if (choiceIndex === 0) {
                    beginPlayback(viewOffset)
                } else {
                    startFromBeginning()
                }
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

    function newSessionId() {
        var chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        var id = ""
        for (var i = 0; i < 12; i++) id += chars[Math.floor(Math.random() * chars.length)]
        return id
    }

    // Report the final "stopped" timeline for the current episode exactly once.
    // The fallback position/duration are used only when no live value is known.
    function reportStopped(finalPositionMs, finalDurationMs) {
        if (stoppedReported) return
        stoppedReported = true
        var pos = lastKnownPositionMs || finalPositionMs
        var dur = lastKnownDurationMs || finalDurationMs
        plexBackend.update_timeline(ratingKey, partKey, "stopped", pos, dur)
    }

    function stopPlayback() {
        reportStopped(mpvController.position, mpvController.duration)
        mpvController.stop()
    }

    function initStreamIndices() {
        var selAudio = navParams.selectedAudioId    || ""
        var selSub   = navParams.selectedSubtitleId || "0"
        for (var i = 0; i < audioStreams.length; i++) {
            if (audioStreams[i].id === selAudio) { audioIdx = i; break }
        }
        for (var j = 0; j < subtitleStreams.length; j++) {
            if (subtitleStreams[j].id === selSub) { subtitleIdx = j; break }
        }
        captureCarryLanguages()
    }

    // Record the language of the current audio/subtitle selection so the next
    // episode (which has different per-file stream IDs) can be matched by language.
    function captureCarryLanguages() {
        var a = audioStreams[audioIdx]
        carryAudioLang = (a && a.language) ? a.language : ""
        // subtitleIdx 0 is the synthetic "OFF" entry — preserve "off" deliberately.
        var s = subtitleStreams[subtitleIdx]
        carrySubLang = (subtitleIdx === 0 || !s) ? "__off__" : (s.language || "")
    }

    // Select audioIdx/subtitleIdx on the current stream lists to match the carried
    // languages. Falls back to the first audio track / subtitles-off when no match.
    function applyCarryLanguages() {
        audioIdx = 0
        for (var i = 0; i < audioStreams.length; i++) {
            if (carryAudioLang && audioStreams[i].language === carryAudioLang) { audioIdx = i; break }
        }
        subtitleIdx = 0
        if (carrySubLang !== "__off__" && carrySubLang !== "") {
            for (var j = 1; j < subtitleStreams.length; j++) {
                if (subtitleStreams[j].language === carrySubLang) { subtitleIdx = j; break }
            }
        }
    }

    // mpv's sub track id for the embedded subtitleStreams[idx]: mpv numbers the
    // file's own sub tracks 1..n in container order (the --sub-file sidecars come
    // after them), which is the order of the embedded entries in Plex's list.
    function mpvEmbeddedSid(idx) {
        var n = 0
        for (var i = 1; i <= idx; i++)
            if (subtitleStreams[i] && !subtitleStreams[i].subUrl) n++
        return n
    }

    // Map a track the OSC switched to (MpvController.trackSelected) back onto
    // `streams`, whose real tracks start at `first` (a subtitle list has the
    // synthetic OFF at 0): a sidecar by its URL, an embedded track by its
    // container stream index (mpv's ff-index is Plex's stream index), else by its
    // position among the embedded tracks. -1 when it can't be placed — including
    // mpv's "no audio", which has no entry to keep.
    function streamIdxForMpvTrack(streams, first, track) {
        if (!track.id) return first > 0 ? 0 : -1
        var i
        if (track.external) {
            for (i = first; i < streams.length; i++)
                if (streams[i].subUrl === track.external) return i
            return -1
        }
        if (track.ffIndex >= 0) {
            for (i = first; i < streams.length; i++)
                if (!streams[i].subUrl && streams[i].index === track.ffIndex) return i
        }
        var n = 0
        for (i = first; i < streams.length; i++)
            if (!streams[i].subUrl && ++n === track.id) return i
        return -1
    }

    // The OSC's AUDIO or SUBTITLE button switched tracks. Follow it, so a
    // relaunch (idle-pause resume, a direct-play retry) reopens the same track,
    // and remember it for the show so later episodes and the info screen pick it
    // too. A transcode carries only the chosen tracks (its subtitle burned in),
    // so mpv's tracks don't map onto the stream lists; a clip (trailer) has none.
    function followTrack(type, track) {
        if (isTranscoding) return
        var idx
        if (type === "sub" && subtitleStreams.length > 1) {
            idx = streamIdxForMpvTrack(subtitleStreams, 1, track)
            if (idx < 0) return
            subtitleIdx = idx
            selectedSubtitleId = currentSubId()
            if (partId) plexBackend.set_subtitle_stream(selectedSubtitleId, partId)
            TrackPicks.remember(appCore, "sub", titleKey, subtitleStreams, idx)
        } else if (type === "audio" && audioStreams.length > 1) {
            idx = streamIdxForMpvTrack(audioStreams, 0, track)
            if (idx < 0) return
            audioIdx = idx
            selectedAudioId = currentAudioId()
            if (partId) plexBackend.set_audio_stream(selectedAudioId, partId)
            TrackPicks.remember(appCore, "audio", titleKey, audioStreams, idx)
        } else {
            return
        }
        captureCarryLanguages()
    }

    function buildSubArgs() {
        var allSubUrls = []
        var allSubTitles = []   // the OSC's names for the sidecars (else mpv shows the URL's tail)
        for (var i = 1; i < subtitleStreams.length; i++) {
            if (subtitleStreams[i] && subtitleStreams[i].subUrl) {
                allSubUrls.push(subtitleStreams[i].subUrl)
                allSubTitles.push(subtitleStreams[i].displayTitle || "")
            }
        }
        var selectedSub = subtitleIdx > 0 ? subtitleStreams[subtitleIdx] : null
        var selectedSubUrl = selectedSub ? (selectedSub.subUrl || "") : ""
        var at = selectedSubUrl ? allSubUrls.indexOf(selectedSubUrl) : -1
        if (at > 0) {
            allSubUrls.unshift(allSubUrls.splice(at, 1)[0])
            allSubTitles.unshift(allSubTitles.splice(at, 1)[0])
        }
        var subTrack
        if (subtitleIdx === 0)
            subTrack = -1
        else if (selectedSubUrl)
            subTrack = 0
        else
            subTrack = mpvEmbeddedSid(subtitleIdx)
        return { urls: allSubUrls, titles: allSubTitles, track: subTrack }
    }

    // Starting mpv runs synchronously and, on the Pi, immediately switches VT
    // (suspending Qt's render thread) before the LOADING frame can paint. Defer
    // the launch one tick so the loading indicator is rendered first — mirroring
    // the async transcode path, which already yields to the event loop. Without
    // this, RESUME/direct-play show no loading screen on the Pi.
    Timer {
        id: startTimer
        interval: 50
        repeat: false
        property int pendingOffset: 0
        onTriggered: doStartPlayback(pendingOffset)
    }

    function beginPlayback(offsetMs) {
        startTimer.pendingOffset = offsetMs
        startTimer.restart()
    }

    // Per-playback mpv extras: the OSC title and (for episodes) the flag that
    // shows its |< / >| buttons. --script-opts-append merges rather than
    // clobbering the --script-opts list MpvController builds.
    function playerExtraArgs() {
        var args = []
        if (mediaTitle) args.push("--force-media-title=" + mediaTitle)
        if (episodeNav) args.push("--script-opts-append=episode-nav=1")
        return args
    }

    function doStartPlayback(offsetMs) {
        if (isTranscoding) {
            // Transcode covers the full timeline (requested at offset 0), so seek mpv
            // to the resume point. This keeps everything before offsetMs seekable, so
            // the user can rewind past the resume point.
            mpvController.loadAndPlay(streamUrl, offsetMs / 1000.0, 0, -1, [], [], false, -1, 0.0, plexToken,
                                       false, "", false, [], 0.0, false, playerExtraArgs())
        } else {
            var sub = buildSubArgs()
            mpvController.loadAndPlay(streamUrl, offsetMs / 1000.0,
                                       audioIdx + 1, sub.track, sub.urls, [], false, -1, 0.0, plexToken,
                                       false, "", false, sub.titles, 0.0, false, playerExtraArgs())
        }
    }

    function startFromBeginning() {
        // Transcode already starts at 0, so both paths simply play from the start.
        // Use beginPlayback so the loading indicator shows while mpv spins up.
        beginPlayback(0)
    }

    // Current audio/subtitle stream IDs for a (re)start, from the selected indices.
    function currentAudioId() {
        return (audioStreams[audioIdx] && audioStreams[audioIdx].id) ? audioStreams[audioIdx].id : ""
    }
    function currentSubId() {
        return (subtitleStreams[subtitleIdx] && subtitleStreams[subtitleIdx].id)
               ? subtitleStreams[subtitleIdx].id : "0"
    }

    // Pause held past the grace period: grab the last frame, then release the
    // server slot and tear mpv down (a short delay lets the screenshot land first).
    Timer {
        id: pauseGraceTimer
        interval: playerRoot.pauseGraceMs
        repeat: false
        onTriggered: playerRoot.suspendForPause()
    }
    Timer {
        id: suspendKillTimer
        interval: 500   // let mpv finish writing the screenshot before it exits
        repeat: false
        onTriggered: {
            // The screenshot file now exists — point the held frame at it, then
            // reveal the overlay and tear the stream down.
            playerRoot.heldFrameUrl = playerRoot._pendingShot
            playerRoot.suspended = true
            playerRoot.reportStopped(mpvController.position, mpvController.duration)
            if (playerRoot.isTranscoding)
                plexBackend.stop_transcode(playerRoot.sessionId)   // free the transcoder
            // If the app is minimized (e.g. the user is watching the server
            // dashboard), releasing the stream must not pull it back to the front.
            if (root.visibility === Window.Minimized)
                mpvController.setHoldBackground(true)
            mpvController.stop()                         // drop the connection / slot
            playerRoot.forceActiveFocus()               // take keys while mpv is gone
        }
    }

    // While suspended, keep the server's name resolution warm with a light periodic
    // OS-level lookup, so resuming doesn't pay a cold DNS lookup (which, for a remote
    // server, can add ~10 s before mpv even starts connecting). Frequent, because the
    // host's DNS TTL may be short; each hit is a no-op once the cache is warm.
    Timer {
        interval: 8000
        repeat: true
        running: playerRoot.suspended
        triggeredOnStart: true
        onTriggered: plexBackend.warm_connection()
    }

    // Long-pause escalation: whether the pause is a lightweight hold (Idle Mode on,
    // stream suspended) or an ordinary paused-and-connected video (Idle Mode off),
    // two hours means the user has wandered off — so return to the info screen. When
    // suspended, mpv is already gone and the stop was reported at suspend, so just
    // leave; otherwise quit mpv (which reports stopped and routes back to info). The
    // resume point is saved either way. goBack() is plain navigation, so a minimized
    // window is left undisturbed.
    Timer {
        interval: 2 * 60 * 60 * 1000   // 2 hours
        repeat: false
        running: mpvController.paused || playerRoot.suspended
        onTriggered: {
            if (playerRoot.suspended) playerRoot.goBack()
            else                      playerRoot.stopPlayback()
        }
    }

    function suspendForPause() {
        if (!idleModeEnabled || suspended || mpvController.position <= 0) return
        suspendedOffsetMs = mpvController.position
        // Hold the crop mode too (the OSC's CROP choice dies with mpv): the held
        // frame is shown through it, and the relaunch on resume starts from it.
        suspendedCropState = mpvController.cropState
        _pendingShot = mpvController.grabFrame()   // capture the paused frame (async write)
        suspendKillTimer.restart()
    }

    function resumeFromSuspend() {
        if (!suspended) return
        plexBackend.warm_connection() // final DNS nudge before mpv opens the stream
        suspended = false
        resuming = true               // the held-frame overlay shows "RESUMING…"
        stoppedReported = false       // a fresh session will need its own stop report
        sessionId = newSessionId()    // the old session was torn down
        pendingResume = true
        // Rebuild the stream at offset 0 (full timeline) — doStartPlayback seeks to
        // the saved position — via the same paths the initial launch uses.
        if (isTranscoding)
            plexBackend.request_transcode(ratingKey, partKey, sessionId,
                                          currentAudioId(), currentSubId(), 0)
        else
            plexBackend.build_stream_url(ratingKey, partKey, sessionId)
    }

    function formatTime(ms) {
        var s = Math.floor(ms / 1000)
        var h = Math.floor(s / 3600)
        var m = Math.floor((s % 3600) / 60)
        var sec = s % 60
        if (h > 0)
            return h + ":" + (m < 10 ? "0" : "") + m + ":" + (sec < 10 ? "0" : "") + sec
        return m + ":" + (sec < 10 ? "0" : "") + sec
    }

    Connections {
        target: plexBackend
        function onErrorOccurred(msg) { console.log("[Player] Backend error: " + msg) }
        function onSegmentsReady(rk, segs) {
            if (String(rk) === String(playerRoot.ratingKey)) playerRoot.segments = segs
        }
        function onStreamUrlReady(url, plexToken) {
            if (pendingNextEpisode) {
                // Stream URL for the auto-advanced next episode just arrived.
                pendingNextEpisode = false
                playerRoot.streamUrl = url
                playerRoot.plexToken = plexToken
                doStartPlayback(0)
                return
            }
            if (pendingRetryTranscode) {
                pendingRetryTranscode = false
                isTranscoding = true
                // Fallback transcode was requested at offset 0 (full timeline), so seek
                // mpv to the resume point — keeps everything before it seekable.
                var sub = buildSubArgs()
                mpvController.loadAndPlay(url, viewOffset / 1000.0, audioIdx + 1, sub.track, sub.urls, [], false, -1, 0.0, plexToken,
                                           false, "", false, sub.titles, 0.0, false, playerExtraArgs())
                return
            }
            if (pendingResume) {
                // Resuming a suspended pause: the rebuilt stream is ready — reload
                // mpv at the saved offset. doStartPlayback handles the transcode
                // (seek) vs direct-play (--start) distinction.
                pendingResume = false
                playerRoot.streamUrl = url
                playerRoot.plexToken = plexToken
                mpvController.setStartCrop(suspendedCropState)   // keep the CROP choice, not the setting
                doStartPlayback(suspendedOffsetMs)
                return
            }
        }

        function onNextEpisodeReady(detail) {
            if (!pendingNextEpisode) return
            // Empty detail → no next episode in the season (or a lookup failure).
            if (!detail || !detail.ratingKey) {
                pendingNextEpisode = false
                landOnNextInfo = false
                if (nextViaButton) {
                    // Button press while mpv is still playing: nothing to
                    // advance to, so just keep watching the current episode.
                    nextViaButton = false
                    return
                }
                // No next episode (last of the season / a movie): fall back to the
                // current detail view.
                goBack()
                return
            }
            if (landOnNextInfo) {
                // Finished with autoplay off: don't play the next episode — just
                // repoint BACK to it and exit, so we land on its info screen.
                landOnNextInfo = false
                pendingNextEpisode = false
                updateBackItem({
                    ratingKey: detail.ratingKey,
                    type: detail.type || "episode",
                    title: detail.title || "",
                    grandparentTitle: detail.grandparentTitle || "",
                    // Carry the show key: the detail screen's titleKey() (per-show
                    // volume/upscaler overrides) needs it for an episode, else it
                    // falls back to the episode's own key and the overrides reset.
                    grandparentRatingKey: detail.grandparentRatingKey || "",
                    parentIndex: detail.parentIndex,
                    index: detail.index
                })
                goBack()
                return
            }
            if (nextViaButton) {
                // The current episode is being cut short on purpose — mark it
                // stopped before the player context swaps to the next one.
                nextViaButton = false
                reportStopped(mpvController.position, mpvController.duration)
            }
            playerRoot.advanceToEpisode(detail)
        }
    }

    // Swap the player's context to the next episode in place (no navigation) and
    // begin playing it from the beginning, carrying over the track languages.
    function advanceToEpisode(detail) {
        ratingKey   = detail.ratingKey
        partKey     = detail.partKey      || ""
        partId      = detail.partId       || ""
        itemTitle   = detail.title        || ""
        mediaTitle  = (detail.grandparentTitle ? detail.grandparentTitle + " - " : "")
                      + "S" + (detail.parentIndex != null ? detail.parentIndex : "?")
                      + "E" + (detail.index != null ? detail.index : "?")
                      + " - " + (detail.title || "")
        audioStreams    = detail.audioStreams    || []
        subtitleStreams = detail.subtitleStreams || []
        isTranscoding   = detail.forceTranscode  || false

        // Recompute the image-subtitle IDs for THIS episode (stream IDs are
        // per-file), mirroring Item.qml's build before the initial hand-off.
        var imageSubs = []
        for (var k = 0; k < subtitleStreams.length; k++) {
            if (subtitleStreams[k] && subtitleStreams[k].imageSubtitle)
                imageSubs.push(subtitleStreams[k].id)
        }
        imageSubtitleIds = imageSubs

        // Fresh-start state for the new episode.
        viewOffset           = 0
        stoppedReported      = false
        lastKnownPositionMs  = 0
        lastKnownDurationMs  = 0
        sessionId            = newSessionId()
        resetSkipState()   // new episode → re-fetch its intro markers, drop any prompt

        // Repoint the BACK target so exiting returns to THIS episode's detail
        // screen, not the one we auto-advanced from. Item.qml reloads from
        // item.ratingKey, so a minimal item carrying the new keys suffices.
        updateBackItem({
            ratingKey: detail.ratingKey,
            type: detail.type || "episode",
            title: detail.title || "",
            grandparentTitle: detail.grandparentTitle || "",
            // Carry the show key so the detail screen's per-show volume/upscaler
            // overrides resolve (titleKey() falls back to the episode key without it).
            grandparentRatingKey: detail.grandparentRatingKey || "",
            parentIndex: detail.parentIndex,
            index: detail.index
        })

        // Match the carried languages onto this episode's stream lists, then
        // remember the resulting selection for the episode after this one. The
        // show's remembered tracks win over the carried languages: they know the
        // exact track for any track layout seen before.
        applyCarryLanguages()
        var ap = TrackPicks.resolve(appCore, "audio", titleKey, audioStreams)
        if (ap >= 0) audioIdx = ap
        var sp = TrackPicks.resolve(appCore, "sub", titleKey, subtitleStreams)
        if (sp >= 0) subtitleIdx = sp
        var audioId = (audioStreams[audioIdx] && audioStreams[audioIdx].id) ? audioStreams[audioIdx].id : ""
        var subId   = (subtitleStreams[subtitleIdx] && subtitleStreams[subtitleIdx].id) ? subtitleStreams[subtitleIdx].id : "0"
        selectedAudioId    = audioId
        selectedSubtitleId = subId
        captureCarryLanguages()

        // Persist the chosen tracks to Plex so a transcode burns the right streams
        // (mirrors Item.qml's behavior before playback).
        if (partId) {
            if (audioId) plexBackend.set_audio_stream(audioId, partId)
            plexBackend.set_subtitle_stream(subId, partId)
        }

        // Both paths resolve through onStreamUrlReady, which checks this flag.
        // build_stream_url emits synchronously, so the flag must be set first.
        pendingNextEpisode = true
        if (isTranscoding) {
            plexBackend.request_transcode(ratingKey, partKey, sessionId, audioId, subId, 0)
        } else {
            plexBackend.build_stream_url(ratingKey, partKey, sessionId)
        }
    }

    Connections {
        target: mpvController

        function onPositionChanged(ms) {
            if (ms > 0) {
                playerRoot.lastKnownPositionMs = ms
                // First position update means mpv is up and playing — drop the
                // loading indicator (mpv's own window now covers the screen).
                playerRoot.playbackStarted = true
                // Resume from a suspended pause has landed its first frame — drop
                // the held frame and loading indicator.
                if (playerRoot.resuming)
                    playerRoot.resuming = false

                // Skip Intro: once playback is up, pull the intro markers; then
                // watch for the intro segment and auto-skip or show the OSC button.
                if (!playerRoot.markersFetched && playerRoot.introSkipSetting !== "Off"
                    && playerRoot.episodeNav && playerRoot.ratingKey) {
                    playerRoot.markersFetched = true
                    plexBackend.fetch_markers(playerRoot.ratingKey)
                }
                if (playerRoot.segments.length > 0) {
                    var seg = playerRoot.findActiveSegment(ms)
                    if (seg && seg !== playerRoot.activeSegment) {
                        playerRoot.activeSegment = seg
                        if (playerRoot.introSkipSetting === "Auto") {
                            if (!playerRoot.introAutoSkipped) {
                                playerRoot.introAutoSkipped = true
                                mpvController.seekTo(seg.endMs)
                            }
                        } else if (playerRoot.introSkipSetting === "Button" && !playerRoot.skipPromptShown) {
                            playerRoot.skipPromptShown = true
                            mpvController.showOsdSkipPrompt()
                        }
                    } else if (!seg && playerRoot.activeSegment) {
                        // Left the intro naturally — drop the prompt.
                        playerRoot.activeSegment = null
                        playerRoot.skipPromptShown = false
                        mpvController.clearOsdPrompt()
                    }
                }
            }
        }

        // Report pause/resume to Plex the instant it happens, so the server shows
        // the correct state instead of waiting up to 10 s for the periodic reporter.
        // Without this a paused stream is reported as "playing", which Plex counts
        // as play time and keeps advancing on its dashboard.
        function onPausedChanged(paused) {
            if (playerRoot.suspended) return   // ignore mpv's teardown pause events
            if (mpvController.position > 0)
                plexBackend.update_timeline(playerRoot.ratingKey, playerRoot.partKey,
                                            paused ? "paused" : "playing",
                                            mpvController.position, mpvController.duration)
            // Arm the slot-release grace timer on pause; cancel it on resume.
            // Skipped entirely when Idle Mode is off (a paused video stays connected).
            if (paused && playerRoot.idleModeEnabled) pauseGraceTimer.restart()
            else                                      pauseGraceTimer.stop()
        }

        // The OSC's SKIP button was activated: jump past the current intro.
        function onSkipRequested() {
            if (playerRoot.activeSegment) {
                playerRoot.introAutoSkipped = true
                mpvController.seekTo(playerRoot.activeSegment.endMs)
                mpvController.clearOsdPrompt()
                // Leave activeSegment set; the seek moves past it and the next
                // position update clears it naturally (nulling now would re-detect
                // the same segment at the pre-seek position and re-arm the prompt).
            }
        }

        // The OSC's >| button (mouse or keyboard) with no mpv playlist loaded:
        // resolve and swap to the next episode while the current one keeps
        // playing. |< is handled inside the OSC itself (restart from 0).
        function onEpisodeNavRequested(direction) {
            if (direction !== "next" || pendingNextEpisode) return
            nextViaButton      = true
            pendingNextEpisode = true
            plexBackend.load_next_episode(ratingKey)
        }
        function onDurationChanged(ms) {
            if (ms > 0) playerRoot.lastKnownDurationMs = ms
        }

        function onTrackSelected(type, track) { playerRoot.followTrack(type, track) }

        function onPlaybackEnded(finalPositionMs, finalDurationMs, reason) {
            // mpv was torn down on purpose to suspend a long pause — stay on the
            // held frame and wait for the user to resume, don't exit to the menu.
            if (playerRoot.suspended) return
            if (reason === "failed") {
                if (!isTranscoding) {
                    // Direct play failed (e.g. HTTP 500 from PMS on WAN). Retry
                    // transparently with transcoding at the same resume offset.
                    pendingRetryTranscode = true
                    plexBackend.request_transcode(ratingKey, partKey, sessionId,
                                                  selectedAudioId, selectedSubtitleId,
                                                  0)
                } else {
                    goBack()
                }
                return
            }

            // Both a natural end ("eof") and a user quit ("stopped") mark the item
            // stopped in Plex. A natural end only *attempts* to auto-advance, and
            // only when the user has autoplay enabled — and even then it's just a
            // request: load_next_episode returns an empty detail when there is no
            // next episode (a movie, or the last episode of a season), in which case
            // onNextEpisodeReady falls back to goBack(). Everything else returns to
            // the detail view here.
            reportStopped(finalPositionMs, finalDurationMs)
            // Finished the episode — either a natural end ("eof"), or the user backed
            // out during the credits: past Plex's ~90% watched threshold it's marked
            // watched and drops out of Continue Watching, so treat that quit as a
            // finish too. Advance the return target to the next episode so BACK never
            // re-shows the one just watched. Only a NATURAL end with autoplay on plays
            // the next episode through here; every other finish just repoints BACK
            // (landOnNextInfo) to the next episode's info. A genuine mid-episode quit
            // keeps the current episode for resume, and a movie / last episode falls
            // back to goBack() (empty next detail).
            var dur = finalDurationMs > 0 ? finalDurationMs : playerRoot.lastKnownDurationMs
            var pos = finalPositionMs > 0 ? finalPositionMs : playerRoot.lastKnownPositionMs
            var nearEnd = dur > 0 && pos >= dur * 0.9
            if (episodeNav && (reason === "eof" || (reason === "stopped" && nearEnd))) {
                landOnNextInfo = (reason !== "eof") || !autoplayNext
                pendingNextEpisode = true
                plexBackend.load_next_episode(ratingKey)
                return
            }
            goBack()
        }
    }

    Timer {
        interval: 10000
        repeat:   true
        running:  true
        onTriggered: {
            // Silent while suspended/resuming: mpv is gone (its position is stale)
            // and the session was intentionally stopped — a ping would revive it.
            if (playerRoot.suspended || playerRoot.resuming) return
            if (mpvController.position > 0)
                plexBackend.update_timeline(ratingKey, partKey,
                                            mpvController.paused ? "paused" : "playing",
                                            mpvController.position, mpvController.duration)
        }
    }

    Component.onCompleted: {
        initStreamIndices()
        if (streamUrl === "") return
        resumeSetting = appCore.get_setting(moduleRoot.moduleId, "resume_playback") || "ask"
        // Match ModuleSettings.qml's reading of a toggle: stored as a real bool
        // once the user touches it, but accept the legacy "ON" string too.
        var autoplayRaw = appCore.get_setting(moduleRoot.moduleId, "autoplay_next_episode")
        autoplayNext  = (autoplayRaw === true || autoplayRaw === "ON")
        // Idle Mode defaults ON — enabled unless explicitly turned off.
        var idleRaw = appCore.get_setting(moduleRoot.moduleId, "idle_mode")
        idleModeEnabled = (idleRaw !== false && idleRaw !== "OFF")
        introSkipSetting = appCore.get_setting(moduleRoot.moduleId, "intro_skip") || "Off"

        if (resumeSetting === "ask" && viewOffset > 0) {
            overlayVisible = true
        } else {
            beginPlayback(viewOffset)
        }
    }

    Rectangle {
        anchors.fill: parent
        color: "black"

        // Shown while mpv launches and buffers the stream (before its window
        // takes over). Hidden once the first position update arrives, or while
        // the resume prompt is up.
        LoadingText {
            // White to match mpv's own overlay text color.
            color: "white"
            anchors.centerIn: parent
            visible: streamUrl !== "" && !overlayVisible && !playbackStarted
        }
    }

    Rectangle {
        anchors.fill: parent
        color: root.surfaceColor
        visible: overlayVisible

        Rectangle {
            id: dialogRect
            color: root.surfaceColor
            anchors.centerIn: parent
            width: root.sw * 0.76875
            height: root.sh * 0.2833333

            Column {
                id: dialogColumn
                anchors.fill: parent
                spacing: root.sh * 0.05

                Text {
                    text: "RESUME PLAYBACK?"
                    color: root.secondaryColor
                    font.family: root.globalFont
                    font.pixelSize: root.sh * 0.0333333
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                Column {
                    Repeater {
                        model: [
                            "Resume from " + formatTime(viewOffset),
                            "Start from the beginning"
                        ]
                        delegate: Item {
                            width: dialogColumn.width
                            height: root.sh * 0.0583333

                            // Touch: first tap highlights an option, tapping the
                            // highlighted option confirms it via a synthesized
                            // Enter (same path as the keyboard).
                            MouseArea {
                                anchors.fill: parent
                                onClicked: {
                                    if (choiceIndex === index) inputManager.touchKey("select")
                                    else choiceIndex = index
                                }
                            }

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
                                topPadding: root.sh * 0.0041667
                                leftPadding: root.sw * 0.009375
                                rightPadding: root.sw * 0.009375
                                bottomPadding: root.sh * 0.00625
                                font.pixelSize: root.sh * 0.0416667
                            }
                        }
                    }
                }

                Text {
                    text: root.hints.back + ":BACK " + root.hints.navigate + ":NAVIGATE " + root.hints.select + ":SELECT"
                    color: root.tertiaryColor
                    font.family: root.globalFont
                    font.pixelSize: root.sh * 0.0333333
                    anchors.horizontalCenter: parent.horizontalCenter
                }
            }
        }
    }

    // Held-frame overlay for a suspended pause: mpv and the server stream are gone
    // (slot released), so show the captured last frame with a resume hint. Also
    // covers the brief re-buffer while resuming, until mpv's first frame is back.
    Rectangle {
        id: idlePanel
        anchors.fill: parent
        color: "black"
        visible: playerRoot.suspended || playerRoot.resuming
        z: 1000

        // A static, display-only reproduction of mpv's OSC (which is gone with mpv):
        // same layout fractions, same VCR font and white, so the paused idle state
        // matches the live player. The interactive button row is intentionally left
        // out — nothing is scrubbable/clickable until playback resumes.
        // These fractions must track scripts/mpv-osc.lua so the released-stream
        // screen and the live OSC line up seamlessly (the margins were narrowed
        // there to sit inside the 4:3 crop area — keep them in step).
        readonly property real fs:      root.sh * 0.0333333            // OSC font size
        readonly property real lm:      root.sw * 0.15                 // left margin  (mpv-osc g.lm)
        readonly property real rm:      root.sw * 0.85                 // right margin (mpv-osc g.rm)
        readonly property real barW:    rm - lm
        readonly property real barH:    fs * 2
        readonly property real titleCY: root.sh * 0.0666667 + (fs * 1.5) / 2
        readonly property real infoY:   root.sh * 0.125
        readonly property real infoLH:  fs * 1.5
        readonly property real row1Y:   root.sh * 0.7083333
        readonly property real barY:    root.sh * 0.74375
        readonly property real hintCY:  root.sh * 0.8333333
        readonly property real pct:     playerRoot.lastKnownDurationMs > 0
            ? Math.min(1, Math.max(0, playerRoot.suspendedOffsetMs / playerRoot.lastKnownDurationMs)) : 0
        readonly property string audioStr: (playerRoot.audioStreams[playerRoot.audioIdx]
            && playerRoot.audioStreams[playerRoot.audioIdx].displayTitle)
            ? playerRoot.audioStreams[playerRoot.audioIdx].displayTitle : "(NONE)"
        readonly property bool hasSub: playerRoot.subtitleStreams && playerRoot.subtitleStreams.length > 1
        readonly property string subStr: (playerRoot.subtitleIdx > 0
            && playerRoot.subtitleStreams[playerRoot.subtitleIdx]
            && playerRoot.subtitleStreams[playerRoot.subtitleIdx].displayTitle)
            ? playerRoot.subtitleStreams[playerRoot.subtitleIdx].displayTitle : "(NONE)"

        // The grab is the decoded frame — mpv's crop/panscan is a display-time
        // effect it doesn't carry — so reproduce the crop mode held at release:
        // 0/-1 = source aspect, 1 = fill (panscan crops the bars away), 2 = the
        // centre 4:3 of the frame, pillarboxed, as the live player showed it.
        Item {
            id: heldFrameBox
            readonly property bool is43: playerRoot.suspendedCropState === 2
            width:  is43 ? Math.min(parent.width, parent.height * 4 / 3) : parent.width
            height: is43 ? width * 3 / 4 : parent.height
            anchors.centerIn: parent
            Image {
                anchors.fill: parent
                source: playerRoot.heldFrameUrl
                fillMode: (playerRoot.suspendedCropState === 1 || heldFrameBox.is43)
                          ? Image.PreserveAspectCrop : Image.PreserveAspectFit
                cache: false
                asynchronous: true
            }
        }
        // Light scrim only — the OSC normally sits over undimmed video; a touch of
        // dim keeps the white text legible over a bright held frame.
        Rectangle { anchors.fill: parent; color: "black"; opacity: 0.25 }

        // Touch: tap anywhere to resume (disabled once resuming is under way).
        MouseArea {
            anchors.fill: parent
            enabled: playerRoot.suspended
            onClicked: playerRoot.resumeFromSuspend()
        }

        // ── Title (top-left) ──
        Text {
            x: idlePanel.lm
            y: idlePanel.titleCY - height / 2
            width: idlePanel.barW
            text: playerRoot.mediaTitle
            color: "white"
            font.family: root.globalFont
            font.pixelSize: idlePanel.fs
            font.capitalization: Font.AllUppercase
            elide: Text.ElideRight
        }
        // ── Track info ──
        Text {
            x: idlePanel.lm
            y: idlePanel.infoY - height / 2
            text: "AUDIO: " + idlePanel.audioStr
            color: "white"
            font.family: root.globalFont
            font.pixelSize: idlePanel.fs
            font.capitalization: Font.AllUppercase
        }
        Text {
            visible: idlePanel.hasSub
            x: idlePanel.lm
            y: idlePanel.infoY + idlePanel.infoLH - height / 2
            text: "SUBTITLE: " + idlePanel.subStr
            color: "white"
            font.family: root.globalFont
            font.pixelSize: idlePanel.fs
            font.capitalization: Font.AllUppercase
        }
        // ── Idle status line (below the track info) ──
        Text {
            visible: playerRoot.suspended
            x: idlePanel.lm
            y: idlePanel.infoY + idlePanel.infoLH * (idlePanel.hasSub ? 2 : 1) - height / 2
            text: "IDLE - STREAM RELEASED"
            color: "white"
            font.family: root.globalFont
            font.pixelSize: idlePanel.fs
            font.capitalization: Font.AllUppercase
        }
        // ── Time text (position left, duration right) ──
        Text {
            x: idlePanel.lm
            y: idlePanel.row1Y - height / 2
            text: playerRoot.formatTime(playerRoot.suspendedOffsetMs)
            color: "white"
            font.family: root.globalFont
            font.pixelSize: idlePanel.fs
        }
        Text {
            x: idlePanel.rm - width
            y: idlePanel.row1Y - height / 2
            text: playerRoot.lastKnownDurationMs > 0
                  ? playerRoot.formatTime(playerRoot.lastKnownDurationMs) : "--:--"
            color: "white"
            font.family: root.globalFont
            font.pixelSize: idlePanel.fs
        }
        // ── Seek bar, frozen at the pause point ──
        Rectangle {
            x: idlePanel.lm
            y: idlePanel.barY
            width: idlePanel.barW
            height: idlePanel.barH
            color: "transparent"
            border.color: "white"
            border.width: 2
            Rectangle {
                x: 4; y: 4
                width: Math.max(0, (parent.width - 8) * idlePanel.pct)
                height: parent.height - 8
                color: "white"
            }
        }
        // ── Resume hint, where the button row would be ──
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            y: idlePanel.hintCY - height / 2
            text: playerRoot.resuming ? "RESUMING…"
                  : ("❚❚  " + root.hints.select + " TO RESUME     "
                     + root.hints.back + " TO EXIT")
            color: "white"
            opacity: 0.7
            font.family: root.globalFont
            font.pixelSize: idlePanel.fs
            font.capitalization: Font.AllUppercase
        }
    }
}
