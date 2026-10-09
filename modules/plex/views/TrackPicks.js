.pragma library

// Per-show audio/subtitle track memory, shared by the info screen (Item.qml) and
// the Player. Plex keeps no per-show track preference and stream ids differ per
// episode, so the choice is kept per show/movie (titleKey, e.g.
// "plex:<showKey>") in two app-level maps per kind ("audio" or "sub"):
//   <kind>_lang_overrides[titleKey] — the chosen language code (subtitles: or "off")
//   <kind>_track_picks[titleKey]    — JSON {track, picks}: the chosen track's
//       identity, and for each track *structure* seen (an episode's whole list
//       of tracks of that kind) which entry the user picked in it, most recent
//       first.
// A show's episodes usually share one structure, so a remembered structure
// restores the exact track, not just its language. An unseen structure falls
// back to the same track by name, then to the first track in the chosen
// language — and a later episode that shares ANY remembered structure gets that
// structure's pick back.
//
// `streams` is a Plex detail's audioStreams or subtitleStreams; a subtitle
// list's entry 0 is the synthetic OFF.

var MAX_PICKS = 12

// Index of the first real track in a list of this kind.
function firstTrack(kind) { return kind === "sub" ? 1 : 0 }

// Language, name, codec, flags, sidecar-ness and (audio) channel count: what
// makes a track "the same track" across episodes (stream ids and positions
// differ per file).
function trackIdentity(s) {
    var id = [s.language || "", (s.title || "").toLowerCase(), s.codec || "",
              s.forced ? "forced" : "", s.hearingImpaired ? "sdh" : "",
              s.subUrl ? "sidecar" : ""].join("|")
    return s.channels ? id + "|" + s.channels + "ch" : id
}

// Compact key for a whole track list: its track count plus an FNV-1a hash of
// every track's identity, in order.
function structureKey(streams, first) {
    var ids = []
    for (var i = first; i < streams.length; i++) ids.push(trackIdentity(streams[i]))
    var str = ids.join("\n")
    var h = 0x811c9dc5
    for (var j = 0; j < str.length; j++) {
        h ^= str.charCodeAt(j)
        h = Math.imul(h, 0x01000193) >>> 0
    }
    return (streams.length - first) + ":" + ("0000000" + h.toString(16)).slice(-8)
}

function loadRecord(appCore, kind, titleKey) {
    var rec = null
    try {
        rec = JSON.parse(appCore.get_map_setting("", kind + "_track_picks", titleKey) || "{}")
    } catch (e) {}
    if (!rec || typeof rec !== "object") rec = {}
    if (!Array.isArray(rec.picks)) rec.picks = []
    return rec
}

// The track index to select for this show, or -1 when nothing is remembered
// (keep the server's own selection).
function resolve(appCore, kind, titleKey, streams) {
    var first = firstTrack(kind)
    if (!titleKey || !streams || streams.length <= first) return -1
    var lang = appCore.get_map_setting("", kind + "_lang_overrides", titleKey) || ""
    if (kind === "sub" && lang === "off") return 0
    var rec = loadRecord(appCore, kind, titleKey)
    // 1. This exact structure was seen before: restore what was picked in it
    //    (unless that pick predates a change of language).
    var key = structureKey(streams, first)
    for (var i = 0; i < rec.picks.length; i++) {
        var idx = rec.picks[i][1]
        if (rec.picks[i][0] === key && idx >= first && idx < streams.length
                && (!lang || streams[idx].language === lang))
            return idx
    }
    // 2. The same track is present under a different structure.
    if (rec.track) {
        for (var j = first; j < streams.length; j++)
            if (trackIdentity(streams[j]) === rec.track) return j
    }
    // 3. The first track in the chosen language.
    if (lang) {
        for (var k = first; k < streams.length; k++)
            if (streams[k].language === lang) return k
    }
    return -1
}

// Remember that `idx` was chosen from `streams` for this show.
function remember(appCore, kind, titleKey, streams, idx) {
    if (!titleKey || !streams || idx < 0 || idx >= streams.length) return
    if (kind === "sub" && idx === 0) {
        // Off is show-wide; the per-structure picks are kept for when it's back on.
        appCore.save_map_setting("", "sub_lang_overrides", titleKey, "off")
        return
    }
    var s = streams[idx]
    appCore.save_map_setting("", kind + "_lang_overrides", titleKey, s.language || "")
    var rec = loadRecord(appCore, kind, titleKey)
    var key = structureKey(streams, firstTrack(kind))
    var picks = [[key, idx]]
    for (var i = 0; i < rec.picks.length && picks.length < MAX_PICKS; i++)
        if (rec.picks[i][0] !== key) picks.push(rec.picks[i])
    appCore.save_map_setting("", kind + "_track_picks", titleKey,
                             JSON.stringify({ track: trackIdentity(s), picks: picks }))
}
