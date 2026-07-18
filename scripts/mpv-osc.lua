local assdraw = require 'mp.assdraw'
local mp_utils = require 'mp.utils'

-- Optional map of external sub-file URL -> friendly track name, written by the app
-- so the OSC can show a real subtitle name instead of mpv's URL-derived title
-- (Jellyfin sidecars are served as "Stream.srt?api_key=..."). Absent for most plays.
local subinfo = {}
do
    local path = mp.get_opt("subinfo-file")
    if path then
        local f = io.open(path, "r")
        if f then
            local parsed = mp_utils.parse_json(f:read("*a") or "")
            f:close()
            if type(parsed) == "table" then subinfo = parsed end
        end
    end
end

-- Set by the app (--script-opts-append=episode-nav=1) when |< / >| should be
-- offered even without an mpv playlist: >| asks the app for the next episode
-- via a client-message; |< restarts the current one.
local episode_nav = (mp.get_opt("episode-nav") == "1")

local menu_visible = false
local focus_row = 0  -- 0: Seek Bar, 1: Buttons
local focus_btn = 1  -- index into visible left buttons + STOP; varies with track availability
local update_timer = nil
local idle_timer = nil
local skip_active = false

-- Seek step for the << / >> buttons and LEFT/RIGHT on the seek bar. The app
-- passes the user's "seek_seconds" setting via script-opts (default 10).
local SEEK_SECONDS  = tonumber(mp.get_opt("seek-seconds") or "10") or 10
local MENU_TIMEOUT  = 5   -- keyboard-triggered auto-hide
local MOUSE_TIMEOUT = 3   -- mouse-triggered auto-hide

-- Colors (ABGR format for ASS)
local C_WHITE = "&HFFFFFF&"
local C_BLACK = "&H000000&"
local A_OPAQUE = "&H00&"
local A_TRANS  = "&HFF&"
local A_DIM    = "&H99&"  -- 40% opacity for unfocused seek fill

local function get_audio_str()
    local id = mp.get_property_number("current-tracks/audio/id", 0)
    if id == 0 then return "(NONE)" end
    local title    = (mp.get_property("current-tracks/audio/title", "") or ""):upper()
    local lang     = (mp.get_property("current-tracks/audio/lang",  "") or ""):upper()
    local codec    = (mp.get_property("current-tracks/audio/codec", "") or ""):upper()
    local channels = mp.get_property_number("current-tracks/audio/audio-channels", 0)
    local rate     = mp.get_property_number("current-tracks/audio/demux-samplerate", 0)
    local parts = {}
    if title    ~= "" then parts[#parts+1] = title end
    if lang     ~= "" then parts[#parts+1] = lang  end
    if codec    ~= "" then parts[#parts+1] = codec end
    if channels  > 0  then parts[#parts+1] = channels .. "CH" end
    if rate      > 0  then parts[#parts+1] = rate .. " HZ" end
    return table.concat(parts, " ")
end

local function get_sub_str()
    local id = mp.get_property_number("current-tracks/sub/id", 0)
    if id == 0 then return "(NONE)" end
    -- External sidecar with an app-provided friendly name (e.g. Jellyfin): use it
    -- instead of mpv's URL-derived title.
    local ext = mp.get_property("current-tracks/sub/external-filename", "") or ""
    if ext ~= "" and subinfo[ext] and subinfo[ext] ~= "" then
        return tostring(subinfo[ext]):upper()
    end
    local title = (mp.get_property("current-tracks/sub/title", "") or ""):upper()
    local lang  = (mp.get_property("current-tracks/sub/lang",  "") or ""):upper()
    local codec = (mp.get_property("current-tracks/sub/codec", "") or ""):upper()
    local parts = {}
    if title ~= "" then parts[#parts+1] = title end
    if lang  ~= "" then parts[#parts+1] = lang  end
    if codec ~= "" then parts[#parts+1] = codec end
    return table.concat(parts, " ")
end

local function has_subtitle_tracks()
    local tracks = mp.get_property_native("track-list", {})
    for _, t in ipairs(tracks) do
        if t.type == "sub" then return true end
    end
    return false
end

local function has_playlist()
    return (mp.get_property_number("playlist-count", 1) or 1) > 1
end

local function nav_prev()
    if has_playlist() then
        mp.command("playlist-prev")
    else
        -- Restart the current item — the app resolves "previous" no further.
        mp.commandv("seek", "0", "absolute")
    end
end

local function nav_next()
    if has_playlist() then
        mp.command("playlist-next")
    elseif episode_nav then
        -- The app decides what comes next (e.g. next episode in the season).
        mp.commandv("script-message", "episode-nav", "next")
    end
end

local transcode_offset = tonumber(mp.get_opt("transcode-offset") or "0") or 0

-- Latch duration on first valid read; used to detect PTS base shifts during HLS seeking
local stable_duration = nil
mp.observe_property("duration", "number", function(_, value)
    if value and value > 0 and not stable_duration then
        stable_duration = value
    end
end)

local function format_time(seconds)
    if not seconds or seconds < 0 then seconds = 0 end
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = math.floor(seconds % 60)
    if h > 0 then
        return string.format("%d:%02d:%02d", h, m, s)
    else
        return string.format("%d:%02d", m, s)
    end
end

-- ── Layout ────────────────────────────────────────────────────────────────────
-- One source of truth for every rectangle, shared by drawing (draw_menu) and
-- mouse hit-testing (the MBTN_LEFT handler) so they can never drift apart.

local function build_left_btns(has_sub, bar_w)
    local btns = {}
    if skip_active then
        btns[#btns + 1] = {label="SKIP", width=math.floor(bar_w * 0.08), action=function()
            mp.commandv("script-message", "skip-segment")
        end}
    end
    -- |< / >| appear only when they can actually navigate somewhere (an mpv
    -- playlist or an app-provided next episode); << / >> are always present.
    local show_nav = has_playlist() or episode_nav
    if show_nav then
        btns[#btns + 1] = {label="|<", width=math.floor(bar_w * 0.05), action=nav_prev}
    end
    btns[#btns + 1] = {label="<<", width=math.floor(bar_w * 0.05),
                       action=function() mp.command("seek -" .. SEEK_SECONDS) end}
    local paused = mp.get_property_native("pause", false)
    btns[#btns + 1] = {label=(paused and "PLAY" or "PAUSE"),
                       width=math.floor(bar_w * 0.095), play=true,
                       action=function() mp.command("no-osd cycle pause") end}
    btns[#btns + 1] = {label=">>", width=math.floor(bar_w * 0.05),
                       action=function() mp.command("seek " .. SEEK_SECONDS) end}
    if show_nav then
        btns[#btns + 1] = {label=">|", width=math.floor(bar_w * 0.05), action=nav_next}
    end
    btns[#btns + 1] = {label="AUDIO", width=math.floor(bar_w * 0.095),
                       action=function() mp.command("no-osd cycle audio") end}
    if has_sub then
        -- sub=true marks it for the long-press handlers: a held ENTER or a long
        -- touch turns subtitles off outright instead of cycling to the next track.
        btns[#btns + 1] = {label="SUBTITLE", width=math.floor(bar_w * 0.13), sub=true,
                           action=function() mp.command("no-osd cycle sub") end}
    end
    btns[#btns + 1] = {label="CROP", width=math.floor(bar_w * 0.08),
                       action=function() mp.command("no-osd cycle-values panscan 0 1") end}
    return btns
end

local function layout()
    local ww, wh = mp.get_osd_size()
    if ww == 0 or wh == 0 then return nil end

    local g = {}
    g.ww, g.wh = ww, wh
    g.fs      = math.floor(wh * 0.0333333)   -- font size
    g.lm      = math.floor(ww * 0.12)        -- left margin
    g.rm      = math.floor(ww * 0.88)        -- right margin
    g.bar_w   = g.rm - g.lm
    g.border  = 2

    g.bar_h   = math.floor(g.fs * 2)
    g.btn_h   = math.floor(g.fs * 1.5)
    g.btn_gap = math.floor(g.bar_w * 0.02)

    g.title_y = math.floor(wh * 0.0666667)
    g.info_y  = math.floor(wh * 0.125)
    g.row1_y  = math.floor(wh * 0.7083333)
    g.bar_y   = math.floor(wh * 0.74375)
    g.btn_y   = math.floor(wh * 0.8333333)

    g.has_sub  = has_subtitle_tracks()

    -- Seek bar
    g.bar = { x = g.lm, y = g.bar_y, w = g.bar_w, h = g.bar_h, inset = g.border + 2 }

    -- Button row: left group with x positions assigned, STOP pinned right
    g.btns = build_left_btns(g.has_sub, g.bar_w)
    local bx = g.lm
    for _, btn in ipairs(g.btns) do
        btn.x, btn.y, btn.h = bx, g.btn_y, g.btn_h
        bx = bx + btn.width + g.btn_gap
    end
    local stop_w = math.floor(g.bar_w * 0.08)
    g.stop = { x = g.rm - stop_w, y = g.btn_y, w = stop_w, h = g.btn_h }

    return g
end

-- Draw a filled rectangle with an optional border.
-- Uses ass:pos() (no \an tag) to match mpv's expected drawing coordinate origin.
local function draw_rect(ass, x, y, w, h, fc, fa, bs, bc)
    ass:new_event()
    ass:pos(x, y)
    ass:append(string.format(
        "{\\bord%d\\3c%s\\3a&H00&\\1c%s\\1a%s\\shad0}",
        bs, bc, fc, fa))
    ass:draw_start()
    ass:rect_cw(0, 0, w, h)
    ass:draw_stop()
end

-- Draw a text label using VCR OSD Mono.
local function draw_text(ass, x, y, anchor, text, fs, fc, fa)
    ass:new_event()
    ass:append(string.format(
        "{\\an%d\\pos(%d,%d)\\fnVCR OSD Mono\\fs%d\\1c%s\\1a%s\\shad0\\bord0}%s",
        anchor, x, y, fs, fc, fa, text))
end

local function draw_menu()
    local g = layout()
    if not g then return end
    local ass = assdraw.ass_new()

    -- ── Title (top-left) ──────────────────────────────────────────
    local title = (mp.get_property("media-title", "") or ""):upper()
    -- VCR OSD Mono is monospace ≈ 0.6em per glyph; keep inside the margins.
    local max_chars = math.floor((g.rm - g.lm) / (g.fs * 0.6))
    if #title > max_chars and max_chars > 3 then
        title = title:sub(1, max_chars - 3) .. "..."
    end
    draw_text(ass, g.lm, g.title_y + g.btn_h / 2, 4, title, g.fs, C_WHITE, A_OPAQUE)

    -- ── Track info ────────────────────────────────────────────────
    local info_fs  = math.floor(g.fs * 1)
    local info_lh  = math.floor(info_fs * 1.5)
    draw_text(ass, g.lm, g.info_y, 4, "AUDIO: " .. get_audio_str(), info_fs, C_WHITE, A_OPAQUE)
    if g.has_sub then
        draw_text(ass, g.lm, g.info_y + info_lh, 4, "SUBTITLE: " .. get_sub_str(), info_fs, C_WHITE, A_OPAQUE)
    end

    -- ── Row 1: Time text ──────────────────────────────────────────
    local total    = stable_duration or (mp.get_property_number("duration", 0) or 0)
    local time_pos = math.min(math.max(0, (mp.get_property_number("time-pos", 0) or 0) + transcode_offset), total)
    local percent  = (total > 0) and math.min(100, math.max(0, time_pos / total * 100)) or 0

    draw_text(ass, g.lm, g.row1_y, 4, format_time(time_pos), g.fs, C_WHITE, A_OPAQUE)
    draw_text(ass, g.rm, g.row1_y, 6, format_time(total),    g.fs, C_WHITE, A_OPAQUE)

    -- ── Row 2: Seek bar ───────────────────────────────────────────
    draw_rect(ass, g.bar.x, g.bar.y, g.bar.w, g.bar.h, C_BLACK, A_TRANS, g.border, C_WHITE)
    local inner_w    = g.bar.w - 2 * g.bar.inset
    local fill_w     = math.max(0, math.floor(inner_w * (percent / 100)))
    local fill_alpha = (focus_row == 0) and A_OPAQUE or A_DIM
    if fill_w > 0 then
        draw_rect(ass, g.bar.x + g.bar.inset, g.bar.y + g.bar.inset,
                  fill_w, g.bar.h - 2 * g.bar.inset, C_WHITE, fill_alpha, 0, C_WHITE)
    end

    -- ── Row 3: Buttons ────────────────────────────────────────────
    local stop_idx = #g.btns + 1
    for i, btn in ipairs(g.btns) do
        local sel    = (focus_row == 1 and focus_btn == i)
        local fill_c = sel and C_WHITE or C_BLACK
        local fill_a = sel and A_OPAQUE or A_TRANS
        local text_c = sel and C_BLACK  or C_WHITE

        draw_rect(ass, btn.x, btn.y, btn.width, btn.h, fill_c, fill_a, g.border, C_WHITE)
        draw_text(ass, btn.x + btn.width / 2, btn.y + btn.h / 2, 5,
                  btn.label, g.fs, text_c, A_OPAQUE)
    end

    local sel    = (focus_row == 1 and focus_btn == stop_idx)
    local fill_c = sel and C_WHITE or C_BLACK
    local fill_a = sel and A_OPAQUE or A_TRANS
    local text_c = sel and C_BLACK  or C_WHITE
    draw_rect(ass, g.stop.x, g.stop.y, g.stop.w, g.stop.h, fill_c, fill_a, g.border, C_WHITE)
    draw_text(ass, g.stop.x + g.stop.w / 2, g.stop.y + g.stop.h / 2, 5,
              "STOP", g.fs, text_c, A_OPAQUE)

    mp.set_osd_ass(g.ww, g.wh, ass.text)
end

-- ── Show / hide ───────────────────────────────────────────────────────────────

local function hide_menu()
    if not menu_visible then return end
    menu_visible = false
    mp.set_osd_ass(0, 0, "")
    if update_timer then update_timer:stop() end
    if idle_timer   then idle_timer:kill()   end
    mp.remove_key_binding("menu-up")
    mp.remove_key_binding("menu-down")
    mp.remove_key_binding("menu-left")
    mp.remove_key_binding("menu-right")
    mp.remove_key_binding("menu-esc")
    mp.remove_key_binding("menu-bs")
end

local function reset_idle_timer(timeout)
    if idle_timer then idle_timer:kill(); idle_timer = nil end
    -- Keep the controls up while paused — don't arm the auto-hide countdown.
    if mp.get_property_native("pause", false) then return end
    idle_timer = mp.add_timeout(timeout or MENU_TIMEOUT, hide_menu)
end

local function update_nav(action)
    reset_idle_timer(MENU_TIMEOUT)

    if action == "up" then
        focus_row = 0
    elseif action == "down" then
        focus_row = 1
    elseif action == "left" then
        if focus_row == 0 then
            mp.command("seek -" .. SEEK_SECONDS)
        else
            local g = layout()
            local total = g and (#g.btns + 1) or 1
            focus_btn = focus_btn > 1 and focus_btn - 1 or total
        end
    elseif action == "right" then
        if focus_row == 0 then
            mp.command("seek " .. SEEK_SECONDS)
        else
            local g = layout()
            local total = g and (#g.btns + 1) or 1
            focus_btn = focus_btn < total and focus_btn + 1 or 1
        end
    elseif action == "enter" and focus_row == 1 then
        local g = layout()
        if g then
            local total   = #g.btns + 1
            local clamped = math.min(focus_btn, total)
            if clamped <= #g.btns then
                g.btns[clamped].action()
            else
                mp.command("quit")
            end
        end
    end

    draw_menu()
end

local menu_shown_at = 0   -- for the touch reveal-gesture window (see osc-click)

local function show_menu(timeout)
    if menu_visible then
        reset_idle_timer(timeout)
        return
    end
    -- Tell the volume bar (media-keys.lua) to stand down — the two OSDs
    -- share the same spot and are mutually exclusive.
    mp.commandv("script-message", "240mp-osd-volume-hide")
    menu_visible = true
    menu_shown_at = mp.get_time()
    focus_row    = 1
    -- Default the highlight to Play/Pause rather than the leftmost button. The
    -- button row is dynamic (SKIP / |< come and go), so locate it by its marker.
    focus_btn    = 1
    for i, b in ipairs(build_left_btns(false, 1000)) do
        if b.play then focus_btn = i; break end
    end
    draw_menu()
    update_timer = mp.add_periodic_timer(0.5, draw_menu)
    reset_idle_timer(timeout)

    -- ENTER is handled by the always-present complex "osc-enter" binding
    -- below (tap activates, hold-on-subtitle disables subs). Binding it here
    -- as well would shadow that one and break its down/up event delivery.
    mp.add_forced_key_binding("UP",    "menu-up",    function() update_nav("up")    end)
    mp.add_forced_key_binding("DOWN",  "menu-down",  function() update_nav("down")  end)
    mp.add_forced_key_binding("LEFT",  "menu-left",  function() update_nav("left")  end)
    mp.add_forced_key_binding("RIGHT", "menu-right", function() update_nav("right") end)
    mp.add_forced_key_binding("ESC",   "menu-esc",   hide_menu)
    mp.add_forced_key_binding("BS",    "menu-bs",    hide_menu)
end

-- While the controls are up, a pause holds them open (no countdown); unpausing
-- restarts the auto-hide. Also refreshes the PLAY/PAUSE label immediately.
mp.observe_property("pause", "bool", function(_, paused)
    if not menu_visible then return end
    if paused then
        if idle_timer then idle_timer:kill(); idle_timer = nil end
    else
        reset_idle_timer(MENU_TIMEOUT)
    end
    draw_menu()
end)

local function toggle_menu()
    if menu_visible then hide_menu() else show_menu(MENU_TIMEOUT) end
end

-- Long-press support for the SUBTITLE button: a held ENTER / long touch turns
-- subtitles off (sid=no) rather than cycling. LONG_PRESS_SEC is the threshold.
local LONG_PRESS_SEC = 0.6
local enter_hold_timer = nil     -- keyboard ENTER hold
local enter_consumed = false
local sub_touch_timer = nil      -- touch hold on the subtitle button
local sub_touch_pending = false
local sub_touch_consumed = false

local function set_sub_none()
    mp.command("no-osd set sid no")
end

local function focused_btn_is_sub()
    if focus_row ~= 1 then return false end
    local g = layout()
    if not g then return false end
    local b = g.btns[focus_btn]
    return b ~= nil and b.sub == true
end

-- ── Mouse support ─────────────────────────────────────────────────────────────
-- Plex-style: controls appear on mouse movement or click and hide after
-- MOUSE_TIMEOUT seconds of stillness, or immediately on a click outside them.

local last_mx, last_my = nil, nil
mp.observe_property("mouse-pos", "native", function(_, mpos)
    if not mpos or mpos.hover == false then return end
    if last_mx ~= nil and (mpos.x ~= last_mx or mpos.y ~= last_my) then
        show_menu(MOUSE_TIMEOUT)
    end
    last_mx, last_my = mpos.x, mpos.y
end)

local function hit(r, mx, my)
    return r and mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h
end

-- Complex so a long touch can be timed: most controls act on the initial
-- down, but the SUBTITLE button defers to the release so a hold can turn subs
-- off (sid=no) instead of cycling.
mp.add_forced_key_binding("MBTN_LEFT", "osc-click", function(t)
    if t.event == "up" then
        -- Resolve a deferred subtitle tap: hold fired → already off; short tap
        -- → cycle to the next track.
        if sub_touch_pending then
            if sub_touch_timer then sub_touch_timer:kill(); sub_touch_timer = nil end
            if not sub_touch_consumed then
                mp.command("no-osd cycle sub")
                reset_idle_timer(MOUSE_TIMEOUT)
                draw_menu()
            end
            sub_touch_pending = false
        end
        return
    end
    if t.event ~= "down" then return end

    local mpos = mp.get_property_native("mouse-pos") or {}
    local mx, my = mpos.x or -1, mpos.y or -1

    if not menu_visible then
        show_menu(MOUSE_TIMEOUT)
        return
    end

    -- Touch taps arrive as a cursor move immediately followed by a click. The
    -- move opens the menu; without this window the click half of that same tap
    -- would then land on whatever control happens to be under the finger
    -- (usually the seek bar). A click this soon after the reveal is therefore
    -- consumed as part of the reveal gesture — controls take input only from
    -- a separate, later tap.
    if mp.get_time() - menu_shown_at < 0.4 then
        reset_idle_timer(MOUSE_TIMEOUT)
        return
    end

    local g = layout()
    if not g then return end

    if hit(g.bar, mx, my) then
        -- Click-to-seek: map the x position to the displayed timeline, then
        -- back out the transcode offset to get mpv's own time base.
        local total = stable_duration or (mp.get_property_number("duration", 0) or 0)
        if total > 0 then
            local inner_x = g.bar.x + g.bar.inset
            local inner_w = g.bar.w - 2 * g.bar.inset
            local frac    = math.min(1, math.max(0, (mx - inner_x) / inner_w))
            local target  = math.max(0, frac * total - transcode_offset)
            mp.commandv("seek", tostring(target), "absolute")
        end
        focus_row = 0
        reset_idle_timer(MOUSE_TIMEOUT)
        draw_menu()
        return
    end

    for i, btn in ipairs(g.btns) do
        if hit({x=btn.x, y=btn.y, w=btn.width, h=btn.h}, mx, my) then
            -- Sync the keyboard focus to the clicked button so the highlight
            -- lands where the user is interacting.
            focus_row, focus_btn = 1, i
            if btn.sub then
                -- Defer: a hold turns subs off, a short tap cycles (on release).
                sub_touch_pending  = true
                sub_touch_consumed = false
                if sub_touch_timer then sub_touch_timer:kill() end
                sub_touch_timer = mp.add_timeout(LONG_PRESS_SEC, function()
                    set_sub_none()
                    sub_touch_consumed = true
                    reset_idle_timer(MOUSE_TIMEOUT)
                    draw_menu()
                end)
            else
                btn.action()
            end
            reset_idle_timer(MOUSE_TIMEOUT)
            draw_menu()
            return
        end
    end

    if hit(g.stop, mx, my) then
        mp.command("quit")
        return
    end

    -- Click outside every control: dismiss.
    hide_menu()
end, {complex = true})

-- The volume bar (media-keys.lua) broadcasts this when it appears; close the
-- menu so the two OSDs never overlap.
mp.register_script_message("240mp-osd-menu-hide", hide_menu)

-- media-keys.lua broadcasts this on seek / chapter changes so the nav menu
-- pops up to show the new position. Open it if closed; otherwise just redraw
-- and restart the auto-hide timer.
mp.register_script_message("240mp-osd-menu-show", function()
    if menu_visible then
        reset_idle_timer(MENU_TIMEOUT)
        draw_menu()
    else
        show_menu(MENU_TIMEOUT)
    end
end)

-- Forced bindings so UP/DOWN/ENTER take priority over mpv's default key
-- handling when native keyboard input reaches mpv directly. ENTER shows the
-- playback controls (rather than toggling pause); once the menu is open, the
-- forced "menu-enter" binding added in show_menu overrides this to activate
-- the focused button, and is removed again on hide.
mp.add_forced_key_binding("UP",    "open_menu_up",    toggle_menu)
mp.add_forced_key_binding("DOWN",  "open_menu_down",  toggle_menu)

-- ENTER: a single always-present complex binding (down/up) so a hold can be
-- timed. When the menu is hidden it opens it; when shown, a tap activates the
-- focused button and a hold on the SUBTITLE button turns subtitles off. Being
-- the only ENTER binding is what keeps its down/up events flowing (a second
-- forced ENTER binding would shadow it and collapse it back to simple calls).
mp.add_forced_key_binding("ENTER", "osc-enter", function(t)
    local ev = t.event
    if not menu_visible then
        -- Physical keys/touch send "down"; the keypress IPC command sends an
        -- atomic "press". Either opens the controls.
        if ev == "down" or ev == "press" then show_menu(MENU_TIMEOUT) end
        return
    end
    if ev == "down" then
        -- Physical press: start the hold timer. A held ENTER on the SUBTITLE
        -- button turns subs off; a quick release activates on "up" below.
        enter_consumed = false
        if enter_hold_timer then enter_hold_timer:kill() end
        enter_hold_timer = mp.add_timeout(LONG_PRESS_SEC, function()
            if focused_btn_is_sub() then
                set_sub_none()
                enter_consumed = true
                reset_idle_timer(MENU_TIMEOUT)
                draw_menu()
            end
        end)
    elseif ev == "up" then
        if enter_hold_timer then enter_hold_timer:kill(); enter_hold_timer = nil end
        -- Ignore the release of the very press that opened the menu.
        if mp.get_time() - menu_shown_at < 0.4 then return end
        if not enter_consumed then update_nav("enter") end
    elseif ev == "press" then
        -- Atomic tap (keypress IPC command, incl. gamepad/QML sendKey): no hold
        -- is possible, so just activate the focused button.
        if mp.get_time() - menu_shown_at < 0.4 then return end
        update_nav("enter")
    end
end, {complex = true})

-- ESC / BS quit when the menu is not visible. When the menu opens it adds
-- forced bindings for these keys that take priority automatically; when it
-- closes those forced bindings are removed and these become active again.
mp.add_key_binding("ESC", "bg-esc", function() mp.command("quit") end)
mp.add_key_binding("BS",  "bg-bs",  function() mp.command("quit") end)

mp.register_script_message("skip-overlay-state", function(state)
    skip_active = (state == "1")
    -- Land focus on SKIP (first button) so ENTER skips immediately —
    -- focus_btn otherwise persists from the last menu interaction.
    if skip_active then focus_btn = 1 end
end)
