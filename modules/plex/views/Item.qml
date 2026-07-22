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
    property int focusRow: 1

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

    // Focus rows: 0 = episodes/watchlist (shows/movies as available), 1 = play
    // cluster, 2 = actions (WATCHED/TRACKED), 3 = audio, 4 = subtitles, 5 = volume,
    // 6 = upscaler, 7 = cast & extras, 8 = related. Column focus inside the play row:
    // 0=PREV, 1=PLAY, 2=NEXT (PREV/NEXT are episode-only). actionCol: 0=WATCHED,
    // 1=TRACKED. epCol inside row 0: 0=EPISODES, 1=WATCHLIST.
    property int  playCol: 1
    property int  actionCol: 0
    property bool episodeItem: (detail && detail.type === "episode") || item.type === "episode"
    property bool adjacentPending: false
    // A PREV/NEXT swap carries the chosen audio/subtitle across episodes by
    // language (volume/upscaler are per-show, so they persist on their own).
    property bool   carryPending:   false
    property string carryAudioLang: ""
    property string carrySubLang:   "__off__"

    // Watched state (viewCount) and Continue Watching membership (viewOffset),
    // kept locally so the button labels flip without reloading the item.
    property bool watched: false
    property bool tracked: false

    // Row-2 sub-column: 0 = EPISODES (shows only), 1 = WATCHLIST bookmark. The
    // watchlist target is this movie's GUID, or — on an episode — its show's (you
    // watchlist the show, not the episode). Empty unless it's a plex:// GUID (new
    // Plex agent), which hides the bookmark on legacy-agent libraries.
    property int  epCol: 0
    property string watchlistGuid: !detail ? ""
        : (episodeItem ? (detail.grandparentGuid || "") : (detail.guid || ""))
    property bool watchlistAvailable: watchlistGuid.indexOf("plex://") === 0
    property bool onWatchlist: false
    property bool watchlistBusy: false
    property string _watchlistChecked: ""

    onFocusRowChanged: if (focusRow === 0) epCol = episodeItem ? 0 : 1

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

    function toggleWatchlist() {
        if (!watchlistAvailable || watchlistBusy) return
        watchlistBusy = true
        onWatchlist = !onWatchlist            // optimistic; reverted on failure
        plexBackend.set_watchlist(watchlistGuid, onWatchlist)
    }

    function requestAdjacent(direction) {
        if (adjacentPending || !detail || !detail.ratingKey) return
        adjacentPending = true
        // Capture the current audio/subtitle by language so the swapped episode
        // keeps them instead of reverting to its own stored defaults.
        var a = detail.audioStreams ? detail.audioStreams[audioIdx] : null
        carryAudioLang = (a && a.language) ? a.language : ""
        var s = detail.subtitleStreams ? detail.subtitleStreams[subtitleIdx] : null
        carrySubLang = (subtitleIdx === 0 || !s) ? "__off__" : (s.language || "")
        carryPending = true
        plexBackend.load_adjacent_episode(detail.ratingKey, direction)
    }

    // Open the show's Episodes browser (season rows of screenshots).
    function openEpisodes() {
        var showRk = (detail && detail.grandparentRatingKey) || item.grandparentRatingKey || ""
        if (!showRk) return
        detailRoot.navigateTo("Episodes.qml", {
            showKey: showRk,
            showTitle: item.grandparentTitle || (detail && detail.grandparentTitle) || "",
            currentRatingKey: (detail && detail.ratingKey) || item.ratingKey || "",
            art: (detail && detail.art) || item.art || "",
            theme: item.theme || (detail && detail.theme) || ""
        })
    }

    // Shared by the initial load and the PREV/NEXT swap: install a detail map
    // and re-derive the audio/subtitle selection indices from it.
    function applyDetail(d) {
        detail = d
        watched = (d.viewCount || 0) > 0
        tracked = (d.viewOffset || 0) > 0
        // Resolve the watchlist state for this title — the show, for an episode.
        // Only re-check when the target GUID changes, so an episode PREV/NEXT swap
        // (same show) doesn't refetch.
        var wg = (d.type === "episode") ? (d.grandparentGuid || "") : (d.guid || "")
        if (wg.indexOf("plex://") === 0 && wg !== _watchlistChecked) {
            _watchlistChecked = wg
            watchlistBusy = true
            plexBackend.check_watchlist(wg)
        }
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
        // On a PREV/NEXT swap, carry the previous audio/subtitle by language over
        // the episode's defaults, and re-assert the (per-show) volume/upscaler as
        // the active values for the next play.
        if (carryPending) {
            if (carryAudioLang !== "" && d.audioStreams) {
                for (var ci = 0; ci < d.audioStreams.length; ci++)
                    if (d.audioStreams[ci].language === carryAudioLang) { audioIdx = ci; break }
            }
            if (carrySubLang === "__off__") {
                subtitleIdx = 0
            } else if (carrySubLang !== "" && d.subtitleStreams) {
                subtitleIdx = 0
                for (var cj = 1; cj < d.subtitleStreams.length; cj++)
                    if (d.subtitleStreams[cj].language === carrySubLang) { subtitleIdx = cj; break }
            }
            appCore.save_setting("", "mpv_upscaler_active", upscalers[upscalerIdx].id)
            appCore.save_setting("", "mpv_volume_gain_active", String(volumeDb))
            carryPending = false
        }
        // Theme song for this item (if enabled and one exists). An episode's own
        // detail carries no theme — only the show does — so fall back to the
        // passed-in item's theme (the show's, set on the browse/Continue Watching
        // entry). Without this the async detail would stop the hover theme the
        // moment it lands. play_theme restarts cleanly, so a PREV/NEXT swap is fine.
        var themeToPlay = d.theme || item.theme
        if (detailRoot.showThemes && themeToPlay)
            plexBackend.play_theme(themeToPlay, detailRoot.themeVolume)
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

        // Watchlist membership resolved (initial check) or confirmed/reverted
        // after a toggle. Only apply it if it's still about the current title.
        function onWatchlistStateReady(guid, on) {
            if (guid === detailRoot.watchlistGuid) {
                detailRoot.onWatchlist = on
                detailRoot.watchlistBusy = false
            }
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
                // Keep the show key so titleKey() (per-show volume/upscaler) stays
                // stable, and carry the show's theme (an episode carries none).
                grandparentRatingKey: d.grandparentRatingKey || item.grandparentRatingKey || "",
                theme: item.theme,
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
    // Per-title key: the show (for episodes) else the movie/item, so choices are
    // remembered per show/movie and carry across a show's episodes. Shared by the
    // upscaler and the volume gain.
    function titleKey() {
        var rk = (item.type === "episode" && item.grandparentRatingKey)
                 ? item.grandparentRatingKey : item.ratingKey
        return "plex:" + rk
    }
    function cycleUpscaler(dir) {
        upscalerIdx = (upscalerIdx + dir + upscalers.length) % upscalers.length
        var id = upscalers[upscalerIdx].id
        appCore.save_map_setting("", "upscaler_overrides", titleKey(), id)   // remember per title
        appCore.save_setting("", "mpv_upscaler_active", id)                  // apply to next play
    }

    // Per-title volume gain (dB, default 0), remembered per show/movie like the
    // upscaler. Applied to the next playback via mpv --volume-gain.
    property int volumeDb: 0
    function volumeLabel() { return (volumeDb > 0 ? "+" : "") + volumeDb + " dB" }
    function cycleVolume(dir) {
        volumeDb = Math.max(-20, Math.min(12, volumeDb + dir))
        appCore.save_map_setting("", "volume_overrides", titleKey(), String(volumeDb))
        appCore.save_setting("", "mpv_volume_gain_active", String(volumeDb))
    }

    // The play/options + playback-settings block now all fits at once (compact,
    // like the Local Files screen), so nothing scrolls until Cast & Extras (6);
    // then More Like This (7). Rows 0-5 stay at the top.
    property real sectionScroll: focusRow <= 6 ? 0
                               : focusRow === 7 ? castSection.y
                               : relatedSection.y
    // Keyboard focus scroll: a focusRow change moves sectionScroll; animate the
    // Flickable's contentY to it. Touch sets contentY directly and never touches
    // sectionScroll, so free dragging and focus scrolling coexist.
    onSectionScrollChanged: {
        scrollAnim.stop()
        scrollAnim.to = detailRoot.sectionScroll
        scrollAnim.start()
    }
    NumberAnimation {
        id: scrollAnim
        target: bodyFlick
        property: "contentY"
        duration: 220
        easing.type: Easing.OutCubic
    }

    Component.onCompleted: {
        focusRow = 1

        // Read the theme settings and start the theme FIRST, before any slower work
        // below (detail load, config writes). A theme playing on hover in browse /
        // Continue Watching only carries over gap-free if play_theme — which cancels
        // the deferred stop armed when the browse view was torn down — runs promptly.
        // Toggle settings persist as a boolean (true/false), not "ON"/"OFF".
        var stv = appCore.get_setting(moduleRoot.moduleId, "show_themes")
        showThemes = (stv === true || stv === "ON")
        var tv = parseInt(appCore.get_setting(moduleRoot.moduleId, "theme_volume"))
        if (tv > 0) themeVolume = tv
        // Start from the passed-in item (its theme path is already known) so the
        // hover theme carries over with no restart — play_theme is idempotent;
        // applyDetail re-asserts it once the full detail arrives.
        if (showThemes && item.theme)
            plexBackend.play_theme(item.theme, themeVolume)

        if (item.ratingKey) plexBackend.load_item_detail(item.ratingKey)

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

    // Rows (top-to-bottom): 0 episodes/watchlist, 1 play cluster, 2 actions, 3 audio,
    // 4 subtitles, 5 volume, 6 upscaler, 7 cast & extras, 8 More Like This. A row is
    // only reachable when it has content, and Up/Down skip over any empty rows.
    function rowAvailable(r) {
        if (r === 0) return detailRoot.episodeItem || detailRoot.watchlistAvailable   // Episodes and/or Watchlist
        if (r === 1 || r === 2) return true   // play cluster, actions (always shown)
        if (r === 3) return detail && detail.audioStreams && detail.audioStreams.length > 0
        if (r === 4) return detail && detail.subtitleStreams && detail.subtitleStreams.length > 1
        if (r === 5) return !!detail   // Volume — playback setting, always shown
        if (r === 6) return !!detail   // Upscaler — playback setting, always shown
        if (r === 7) return detailRoot.castExtras.length > 0
        if (r === 8) return detailRoot.showRelated && detailRoot.relatedItems.length > 0
        return false
    }
    Keys.onUpPressed: {
        if (isLaunching) return
        for (var r = focusRow - 1; r >= 0; r--)
            if (rowAvailable(r)) { focusRow = r; break }
    }
    Keys.onDownPressed: {
        if (isLaunching || !detail) return
        for (var r = focusRow + 1; r <= 8; r++)
            if (rowAvailable(r)) { focusRow = r; break }
    }
    Keys.onLeftPressed: {
        if (isLaunching) return
        if (!detail) return
        if (focusRow === 1) {
            if (episodeItem && playCol > 0) playCol--
        } else if (focusRow === 2) {
            if (actionCol > 0) actionCol--
        } else if (focusRow === 0) {
            if (epCol > 0 && episodeItem) epCol--   // → EPISODES
        } else if (focusRow === 3 && detail.audioStreams && detail.audioStreams.length > 1)
            audioIdx = (audioIdx - 1 + detail.audioStreams.length) % detail.audioStreams.length
        else if (focusRow === 4 && detail.subtitleStreams && detail.subtitleStreams.length > 1)
            subtitleIdx = (subtitleIdx - 1 + detail.subtitleStreams.length) % detail.subtitleStreams.length
        else if (focusRow === 5)
            detailRoot.cycleVolume(-1)
        else if (focusRow === 6)
            detailRoot.cycleUpscaler(-1)
        else if (focusRow === 7 && detailRoot.castExtras.length > 0)
            detailRoot.castIndex = (detailRoot.castIndex - 1 + detailRoot.castExtras.length) % detailRoot.castExtras.length
        else if (focusRow === 8 && detailRoot.relatedItems.length > 0)
            detailRoot.relatedIndex = (detailRoot.relatedIndex - 1 + detailRoot.relatedItems.length) % detailRoot.relatedItems.length
    }
    Keys.onRightPressed: {
        if (isLaunching) return
        if (!detail) return
        if (focusRow === 1) {
            if (episodeItem && playCol < 2) playCol++
        } else if (focusRow === 2) {
            if (actionCol < 1) actionCol++
        } else if (focusRow === 0) {
            if (epCol < 1 && watchlistAvailable) epCol++   // → WATCHLIST
        } else if (focusRow === 3 && detail.audioStreams && detail.audioStreams.length > 1)
            audioIdx = (audioIdx + 1) % detail.audioStreams.length
        else if (focusRow === 4 && detail.subtitleStreams && detail.subtitleStreams.length > 1)
            subtitleIdx = (subtitleIdx + 1) % detail.subtitleStreams.length
        else if (focusRow === 5)
            detailRoot.cycleVolume(1)
        else if (focusRow === 6)
            detailRoot.cycleUpscaler(1)
        else if (focusRow === 7 && detailRoot.castExtras.length > 0)
            detailRoot.castIndex = (detailRoot.castIndex + 1) % detailRoot.castExtras.length
        else if (focusRow === 8 && detailRoot.relatedItems.length > 0)
            detailRoot.relatedIndex = (detailRoot.relatedIndex + 1) % detailRoot.relatedItems.length
    }
    Keys.onReturnPressed: {
        if (isLaunching) return
        if (focusRow === 2) {
            if (actionCol === 0) toggleWatched()
            else toggleTracked()
            return
        }
        if (focusRow === 0) {
            if (epCol === 1 && detailRoot.watchlistAvailable) detailRoot.toggleWatchlist()
            else if (detailRoot.episodeItem) detailRoot.openEpisodes()
            return
        }
        if (focusRow === 8 && detailRoot.relatedItems.length > 0) {
            // Open the highlighted related title's info screen.
            detailRoot.navigateTo("Item.qml", { item: detailRoot.relatedItems[detailRoot.relatedIndex] })
            return
        }
        if (focusRow === 7 && detailRoot.castExtras.length > 0) {
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
        if (focusRow === 1 && detail && episodeItem && playCol !== 1) {
            // PREV/NEXT: swap this screen to the sibling episode in place.
            requestAdjacent(playCol === 0 ? -1 : 1)
            return
        }
        if (focusRow === 1 && detail) {
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

    // Body — a Flickable so a touch drag/flick scrolls the section stack with the
    // same momentum as the other menus, while taps on the buttons inside still work
    // (a Flickable disambiguates a tap from a drag natively). Keyboard focus scrolls
    // it too: a focusRow change moves sectionScroll and onSectionScrollChanged
    // animates contentY to bring the focused section to the top.
    Flickable {
        id: bodyFlick
        visible: detail !== null
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.25 //120
        anchors.leftMargin: root.sw * 0.115625 //74
        width: root.sw * 0.76875 //492
        height: root.sh * 0.525 //252
        clip: true
        contentWidth: width
        contentHeight: sectionStack.height
        flickableDirection: Flickable.VerticalFlick

        // Section stack: the play/options block, the audio/subtitle settings, and
        // the Cast / More Like This rows, stacked vertically.
        Item {
            id: sectionStack
            width: bodyFlick.width
            height: childrenRect.height

        Row {
            id: itemDetails
            height: root.sh * 0.30
            spacing: root.sw * 0.0375 //24

            // Left action stack, top to bottom: the Episodes/Watchlist row, then the
            // play cluster (PREV/PLAY/NEXT — PREV/NEXT episode-only, swapping to the
            // sibling episode), then the WATCHED/TRACKED actions. Focus opens on PLAY.
            Column {
                spacing: root.sh * 0.0125 //6

            // Episodes + Watchlist row, above the play cluster. EPISODES (shows
            // only) fills the left; the Watchlist bookmark toggle sits on the right.
            Item {
                id: row2
                visible: detailRoot.episodeItem || detailRoot.watchlistAvailable
                width: root.sw * 0.1875
                height: root.sh * 0.05

                // Watchlist bookmark toggle (right).
                Rectangle {
                    id: watchlistBtn
                    visible: detailRoot.watchlistAvailable
                    property bool sel: focusRow === 0 && detailRoot.epCol === 1
                    width: root.sh * 0.05
                    height: root.sh * 0.05
                    anchors.right: parent.right
                    color: sel ? root.accentColor : root.surfaceColor
                    border.color: sel ? root.accentColor : root.tertiaryColor
                    border.width: root.sh * 0.003125 //2

                    MouseArea {
                        anchors.fill: parent
                        onClicked: { if (watchlistBtn.sel) detailRoot.toggleWatchlist()
                                     else { focusRow = 0; detailRoot.epCol = 1 } }
                    }
                    // Bookmark glyph as a vector: outline when not on the watchlist,
                    // filled when on it.
                    Canvas {
                        id: bookmark
                        anchors.centerIn: parent
                        width: parent.width * 0.4
                        height: parent.height * 0.54
                        property bool filled: detailRoot.onWatchlist
                        property color col: watchlistBtn.sel ? root.surfaceColor : root.accentColor
                        onFilledChanged: requestPaint()
                        onColChanged: requestPaint()
                        onWidthChanged: requestPaint()
                        onHeightChanged: requestPaint()
                        onPaint: {
                            var ctx = getContext("2d")
                            ctx.reset()
                            var w = width, h = height
                            var lw = Math.max(1.5, w * 0.16)
                            var notch = h * 0.26
                            var x0 = lw / 2, y0 = lw / 2, x1 = w - lw / 2, y1 = h - lw / 2
                            ctx.beginPath()
                            ctx.moveTo(x0, y0)
                            ctx.lineTo(x1, y0)
                            ctx.lineTo(x1, y1)
                            ctx.lineTo(w / 2, y1 - notch)
                            ctx.lineTo(x0, y1)
                            ctx.closePath()
                            if (filled) { ctx.fillStyle = col; ctx.fill() }
                            else { ctx.strokeStyle = col; ctx.lineWidth = lw
                                   ctx.lineJoin = "round"; ctx.stroke() }
                        }
                    }
                }

                // Episodes browser (shows/episodes only), left of the bookmark.
                Rectangle {
                    id: episodesBtn
                    visible: detailRoot.episodeItem
                    property bool sel: focusRow === 0 && detailRoot.epCol === 0
                    anchors.left: parent.left
                    anchors.right: watchlistBtn.visible ? watchlistBtn.left : parent.right
                    anchors.rightMargin: watchlistBtn.visible ? root.sw * 0.0046875 : 0
                    height: root.sh * 0.05
                    color: sel ? root.accentColor : root.surfaceColor
                    border.color: sel ? root.accentColor : root.tertiaryColor
                    border.width: root.sh * 0.003125 //2

                    MouseArea {
                        anchors.fill: parent
                        onClicked: { if (episodesBtn.sel) detailRoot.openEpisodes()
                                     else { focusRow = 0; detailRoot.epCol = 0 } }
                    }
                    Text {
                        anchors.centerIn: parent
                        text: "EPISODES"
                        color: episodesBtn.sel ? root.surfaceColor : root.primaryColor
                        font.family: root.globalFont
                        font.pixelSize: root.sh * 0.025 //12
                    }
                }
            }

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
                            text: "\u25C4"
                            color: prevButton.sel ? root.surfaceColor : root.primaryColor
                            font.family: root.globalFont
                            font.pixelSize: root.sh * 0.0416667 //20
                        }
                    }

                    Rectangle {
                        id: playButton
                        property bool sel: focusRow === 1 && (!detailRoot.episodeItem || playCol === 1)
                        color: sel ? root.accentColor : root.surfaceColor
                        border.color: sel ? root.accentColor : root.tertiaryColor
                        // Fill the rest of the 0.1875 cluster so PREV+PLAY+NEXT total
                        // exactly matches the WATCHED/TRACKED row below it.
                        width: detailRoot.episodeItem
                               ? root.sw * 0.1875 - 2 * (root.sw * 0.0375 + root.sw * 0.0046875)
                               : root.sw * 0.1875
                        height: parent.height
                        border.width: root.sh * 0.003125 //2

                        // Touch: first tap focuses the PLAY button, tapping it while
                        // focused activates it via a synthesized Enter.
                        MouseArea {
                            anchors.fill: parent
                            onClicked: {
                                if (playButton.sel) inputManager.touchKey("select")
                                else { focusRow = 1; playCol = 1 }
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
                    property bool sel: focusRow === 2 && actionCol === 0
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
                    // "Remove from Continue Watching" only applies to in-progress items.
                    visible: detail && detail.viewOffset > 0
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
                    source: (detail && detail.thumb)
                            ? plexBackend.image_url(detail.thumb,
                                                    Math.round(width), Math.round(height))
                            : ""
                }
            }
        }

        // AUDIO row — the playback settings begin directly under the details, with
        // no "Playback Settings:" label or gap (compact, like the Local Files view).
        Item {
            id: audioRow
            visible: detail && detail.audioStreams && detail.audioStreams.length > 0
            anchors.top: itemDetails.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.topMargin: root.sh * 0.0083333
            height: root.sh * 0.048 //23

            // Touch: first tap focuses the row; tapping the focused row cycles
            // its value forward, reusing the LEFT/RIGHT keyboard handlers.
            // Declared before the value Row so its arrows stack on top.
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
                text: "Audio"
                color: focusRow === 3 ? root.surfaceColor : root.primaryColor
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
                    color: focusRow === 3 ? root.surfaceColor : root.tertiaryColor
                    font.family: root.globalFont
                    anchors.verticalCenter: parent.verticalCenter
                    font.pixelSize: root.sh * 0.0375 //18

                    // Tap \u25C4 to cycle backward (row must be focused first; a
                    // stray tap focuses it instead of changing it).
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
                    text: (detail && detail.audioStreams && detail.audioStreams[audioIdx])
                          ? detail.audioStreams[audioIdx].displayTitle : ""
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

        // SUBTITLES row
        Item {
            id: subtitleRow
            visible: detail && detail.subtitleStreams && detail.subtitleStreams.length > 1
            anchors.top: audioRow.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: root.sh * 0.048 //23

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
                text: "Subtitles"
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
                    text: "\u25C4"
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
                    text: (detail && detail.subtitleStreams && detail.subtitleStreams[subtitleIdx])
                          ? detail.subtitleStreams[subtitleIdx].displayTitle : ""
                    color: focusRow === 4 ? root.surfaceColor : root.primaryColor
                    font.family: root.globalFont
                    font.capitalization: Font.AllUppercase
                    anchors.verticalCenter: parent.verticalCenter
                    font.pixelSize:root.sh * 0.0416667 //20
                }
                Text {
                    text: "\u25BA"
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

        // VOLUME row — per-title volume gain in dB (◄/►), remembered per show/movie.
        Item {
            id: volumeRow
            anchors.top: subtitleRow.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: root.sh * 0.048 //23

            MouseArea {
                anchors.fill: parent
                onClicked: {
                    if (focusRow === 5) inputManager.touchKey("right")
                    else focusRow = 5
                }
            }

            Rectangle {
                anchors.fill: parent
                color: focusRow === 5 ? root.accentColor : "transparent"
            }

            Text {
                text: "Volume"
                color: focusRow === 5 ? root.surfaceColor : root.primaryColor
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
                    color: focusRow === 5 ? root.surfaceColor : root.tertiaryColor
                    font.family: root.globalFont
                    anchors.verticalCenter: parent.verticalCenter
                    font.pixelSize: root.sh * 0.0375 //18

                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -root.sh * 0.0125
                        onClicked: {
                            if (focusRow === 5) inputManager.touchKey("left")
                            else focusRow = 5
                        }
                    }
                }
                Text {
                    text: detailRoot.volumeLabel()
                    color: focusRow === 5 ? root.surfaceColor : root.primaryColor
                    font.family: root.globalFont
                    font.capitalization: Font.AllUppercase
                    anchors.verticalCenter: parent.verticalCenter
                    font.pixelSize:root.sh * 0.0416667 //20
                }
                Text {
                    text: "►"
                    color: focusRow === 5 ? root.surfaceColor : root.tertiaryColor
                    font.family: root.globalFont
                    anchors.verticalCenter: parent.verticalCenter
                    font.pixelSize: root.sh * 0.0375 //18

                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -root.sh * 0.0125
                        onClicked: {
                            if (focusRow === 5) inputManager.touchKey("right")
                            else focusRow = 5
                        }
                    }
                }
            }
        }

        // UPSCALER row — cycles the "mpv_upscaler" setting (applied by the player on
        // the next playback). Part of the Playback Settings block.
        Item {
            id: upscalerRow
            anchors.top: volumeRow.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: root.sh * 0.048 //23

            MouseArea {
                anchors.fill: parent
                onClicked: {
                    if (focusRow === 6) inputManager.touchKey("right")
                    else focusRow = 6
                }
            }

            Rectangle {
                anchors.fill: parent
                color: focusRow === 6 ? root.accentColor : "transparent"
            }

            Text {
                text: "Upscaler"
                color: focusRow === 6 ? root.surfaceColor : root.primaryColor
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
                    color: focusRow === 6 ? root.surfaceColor : root.tertiaryColor
                    font.family: root.globalFont
                    anchors.verticalCenter: parent.verticalCenter
                    font.pixelSize: root.sh * 0.0375 //18

                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -root.sh * 0.0125
                        onClicked: {
                            if (focusRow === 6) inputManager.touchKey("left")
                            else focusRow = 6
                        }
                    }
                }
                Text {
                    text: detailRoot.upscalers[detailRoot.upscalerIdx].label
                    color: focusRow === 6 ? root.surfaceColor : root.primaryColor
                    font.family: root.globalFont
                    font.capitalization: Font.AllUppercase
                    anchors.verticalCenter: parent.verticalCenter
                    font.pixelSize:root.sh * 0.0416667 //20
                }
                Text {
                    text: "►"
                    color: focusRow === 6 ? root.surfaceColor : root.tertiaryColor
                    font.family: root.globalFont
                    anchors.verticalCenter: parent.verticalCenter
                    font.pixelSize: root.sh * 0.0375 //18

                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -root.sh * 0.0125
                        onClicked: {
                            if (focusRow === 6) inputManager.touchKey("right")
                            else focusRow = 6
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
                color: detailRoot.focusRow === 7 ? root.accentColor : root.secondaryColor
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
                    property bool sel: detailRoot.focusRow === 7 && detailRoot.castIndex === index

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
                        MarqueeText {
                            width: parent.width
                            text: modelData.title || ""
                            color: sel ? root.accentColor : root.primaryColor
                            pixelSize: root.sh * 0.0233333 //~11
                            active: sel   // scroll the full name while highlighted
                        }
                        MarqueeText {
                            width: parent.width
                            text: modelData.subtitle || ""
                            color: root.tertiaryColor
                            pixelSize: root.sh * 0.02 //~10
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

        // SECTION: More Like This — a full-size boxart row (matching the browse /
        // Continue Watching cover grid) below the audio/subtitle settings.
        Item {
            id: relatedSection
            visible: detailRoot.showRelated && detailRoot.relatedItems.length > 0
            anchors.top: castSection.bottom
            anchors.topMargin: root.sh * 0.03
            anchors.left: parent.left
            anchors.right: parent.right
            height: visible ? (relatedLabel.height + root.sh * 0.0083333 + relatedList.height) : 0

            Text {
                id: relatedLabel
                text: "More Like This"
                color: detailRoot.focusRow === 8 ? root.accentColor : root.secondaryColor
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
                        border.color: (detailRoot.focusRow === 8 && detailRoot.relatedIndex === index)
                                      ? root.accentColor : root.tertiaryColor
                        border.width: (detailRoot.focusRow === 8 && detailRoot.relatedIndex === index)
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
                            if (detailRoot.focusRow === 8 && detailRoot.relatedIndex === index)
                                inputManager.touchKey("select")
                            else { detailRoot.focusRow = 8; detailRoot.relatedIndex = index }
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
