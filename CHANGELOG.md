# Changelog

All notable changes to 240-MP for Windows are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.8.0] - 2026-08-01

### Added
- **Retro filters (Plex & Local Files).** A new **Shader** row on the info screen
  lays a bundled CRT/tape look over playback — chosen per title like the other
  playback settings and remembered per show. Six looks, each with a curved-tube
  **(CURVED)** variant:
  - **Scanlines** — gentle horizontal scanlines.
  - **CRT** — a soft tube: scanline bloom, a light horizontal bleed and a mild glow.
  - **NTSC** — composite colour done in YIQ (NTSC's native encoding): band-limited
    chroma, the signature "wrong-tint" hue drift, a warm cast, and dot-crawl shimmer.
  - **VHS** — chroma fringe, tape grain, a slow tracking bar, an organic wobble that
    swells into brief dropouts, and pixelated head-switching noise torn along the
    bottom edge.
  - **Heavy CRT** — a bigger tube: deeper scanlines, a strong centre-weighted glow,
    a vignette, and a touch of chromatic aberration.
  The filter runs after the upscaler and leaves subtitles and the on-screen controls
  untouched. The shaders are self-authored GLSL bundled with the app; the heavier
  looks use Vulkan to avoid a first-play shader-compile stall.

### Fixed
- **Bundled GLSL shaders now ship in the release package.** The `shaders/` folder
  was left out of the packaged build, so a release install had no GLSL upscalers
  (only the built-in High-Quality scaler worked). The retro filters and the
  ArtCNN / FSRCNNX / Anime4K upscalers are now all included.

## [0.7.0] - 2026-08-01

### Added
- **Idle Mode (Plex).** When a Plex video is paused for a minute, its server
  stream is released — freeing the slot for other devices — and the last frame is
  held on screen with the player's title, audio/subtitle, time, and a frozen
  progress bar (plus an `IDLE - STREAM RELEASED` line). Pressing play reloads
  from where you left off. A new **Plex Settings → Idle Mode** toggle (on by
  default) controls it. Either way, any pause left for **two hours** returns to
  the info screen (the resume point is kept). While idle the connection's name
  resolution is kept warm so resuming is quick rather than a cold reconnect.

### Fixed
- **A paused Plex stream is reported as paused, not playing.** Previously a
  left-paused video was reported to the server as actively playing forever —
  which inflated the account's watch-time statistics and looped a phantom
  progress bar on the Plex dashboard. It now reports paused (and, with Idle Mode,
  releases the stream entirely).

### Security
- **Plex credentials are encrypted at rest (Windows DPAPI).** The device signing
  key and tokens (`plex_key.pem`, `plex_auth.json`) are now encrypted with the
  Windows Data Protection API, keyed to your login, so a copied file can't be
  read on another machine or by another user. Existing files migrate
  automatically on first launch; same-machine reinstalls keep you signed in.

## [0.6.2] - 2026-07-30

### Fixed
- **Plex playback settings now stick across a show.** After an episode ended
  (or on reopening any episode), the info screen used to reset the audio track,
  subtitle track, volume, and upscaler to defaults. Volume and upscaler are again
  remembered per show, and audio/subtitle language is now remembered per show too
  and re-applied to every episode — so, for example, "subtitles off for this
  show" sticks even though Plex keeps no per-show track preference and an account
  default (e.g. subtitles on) would otherwise reassert on each episode.
- **Touch: holding the Subtitles button turns subtitles off again**, and a touch
  press-and-hold no longer pauses playback. On Windows a long touch is delivered
  as a right-click, which had hijacked the gesture (and mpv's default
  right-click-to-pause); it now drives subtitles-off when it lands on that button.

### Performance
- **The animated background stops when it can't be seen** — during video
  playback, while the screen saver is up, and when minimized — instead of
  decoding every frame regardless. Idle resource use while minimized is now
  near-zero. (A visible animated background still costs what it costs.)
- **Theme music is buffered** rather than re-streamed from the server on each loop.
- **Gamepad polling is adaptive** — fast only while a controller is connected,
  and idle (2 Hz, enough to catch a plug-in) otherwise, instead of a constant
  60 Hz for the whole session.

## [0.6.1] - 2026-07-23

### Fixed
- **Rapidly tapping the player controls no longer blacks out the video.** A fast
  double-tap registered as mpv's built-in double-click action (toggle
  fullscreen); because the player runs fullscreen with its window married to the
  app, leaving fullscreen tore down the composition and the video stayed black
  until playback ended. mpv's fullscreen toggles are now disabled during
  playback (the window is fixed fullscreen anyway).

## [0.6.0] - 2026-07-22

### Added
- **Local Files Watchlist (on-device).**
  - A square bookmark toggle on the info screen adds or removes a title from an
    on-device watchlist — beside the new Episodes button on a show/episode, on
    its own for a movie — styled to match the Plex bookmark.
  - A **Watchlist** entry on the Local Files menu lists the saved titles as an
    8-across poster grid.
- **Local Files Episodes view.** A show folder now opens a season-by-season view
  — the synopsis on top, then one still row per `SEASON X (YEAR)` — mirroring the
  Plex Episodes browser. Reachable two ways: ENTER on a show folder in Browse
  opens Episodes (a separate key still opens the raw folder contents), and an
  **EPISODES** button on the info screen. `season.nfo` is parsed for per-season
  titles, years, and summaries.

### Changed
- **Renamed to 240-MP-Win.** The window and taskbar button now read
  *240-MP-Win*, and the roaming data directory moves from `%APPDATA%\240-MP` to
  `%APPDATA%\240-MP-Win`. **Existing installs start fresh there** — copy the old
  folder to the new name to keep your settings, auth, and history. The install
  location and your Plex/Jellyfin device registrations are unchanged.
- **Local Files browse grid.** Folder and movie browsing now uses the same fixed
  8-across poster grid as the Plex Home/Watchlist views — including a
  shows-parent folder, which previously rendered as a 3-column landscape grid.

## [0.5.0] - 2026-07-22

### Added
- **Plex Watchlist.**
  - A bookmark toggle on the info screen — beside the Episodes button on a
    show/episode, on its own for a movie — adds or removes the title from your
    Plex-account watchlist (an episode watchlists its show). It shows the current
    state on open and toggles in one press.
  - The top library menu's Continue Watching shortcut is replaced by a
    **Watchlist** entry listing the watchlisted titles that are on this server,
    as an 8-across poster grid or a name list (per Browse View), paged 64 at a
    time with a **Load More** tile. (Continue Watching still leads the Home
    dashboard.)
- **Home text view.** With Browse View = Title, the Home dashboard becomes a
  two-pane text menu — Continue Watching and the libraries on the left (40%), the
  selected one's titles on the right (60%). Browse View = Cover keeps the poster
  dashboard.
- **Touch scrolling on the Plex info screen.** Its sections now scroll with a
  touch drag/flick (momentum like the other menus), so Cast & Extras and More
  Like This are reachable by touch. Taps on the buttons inside still work.

### Changed
- **Info-screen layout.** The Episodes/Watchlist row now sits above the
  Prev/Play/Next cluster; the default highlight stays on Play.

### Fixed
- **No stray mpv titlebar when minimized.** Minimizing 240-MP during playback no
  longer leaves mpv's minimized-window caption stub parked at the screen edge
  (visible with a custom taskbar/dock that doesn't cover that spot).
- **Recover from an overnight display sleep.** After the monitor is off for hours
  over a paused video, 240-MP nudges mpv to re-present when the screen wakes — and
  uses a BitBlt D3D11 swapchain, less prone to that freeze — instead of needing
  the video exited to restore it.

## [0.4.1] - 2026-07-21

### Fixed
- **Seeking no longer flashes the video to black.** The `<<`/`>>` controls, the
  seek bar's LEFT/RIGHT, and the Fast-Forward/Rewind media keys now do exact
  seeks, so the destination frame is drawn immediately instead of a black frame
  (which under hardware decode could linger, and stayed black while paused).
- **Episodes synopsis scroll** now steps a whole line at a time and no longer
  clips a sliver of the last line.

## [0.4.0] - 2026-07-19

### Added
- **Plex Episodes browser.** An **EPISODES** button beside the Watched/Tracked
  actions opens a season-by-season view — the show synopsis on top (auto-scrolling
  when it runs long), then one screenshot row per season under a `SEASON X (YEAR)`
  header; pick an episode to open its info.

### Changed
- **Plex PREV/NEXT crosses seasons** on the info screen (it now walks the whole
  show rather than only the current season), and carries the chosen audio/subtitle
  by language and the per-show volume/upscaler across episodes.

## [0.3.0] - 2026-07-18

### Added
- **Skip Intro (Plex).** Using the server's intro markers, the player can auto-skip
  the intro or show a Skip button — chosen in Plex Settings → Skip Intro
  (Off / Auto / Button). Requires Plex's intro detection to have run for the show.

### Changed
- **Player controls default to Play/Pause.** Revealing the on-screen controls now
  highlights Play/Pause instead of the leftmost (Previous File) button.
- **Player controls stay visible while paused** instead of auto-hiding after a few
  seconds.

### Fixed
- A tap to reveal the player controls no longer briefly freezes the video (mpv's
  default window-dragging entered a modal move loop on Windows).

## [0.2.0] - 2026-07-16

### Added
- **Local Files series navigation.** On a show's info screen, PREV/NEXT — and the
  mpv `|< / >|` controls during playback — now step through the whole series
  across season folders, not just the current folder. Finishing an episode
  advances to the next one's info screen (the next season's first episode
  included), and this works when playback is launched from Continue Watching.
- **Local Files Cast & Extras.** A new section on the info screen (scroll down past
  the playback settings) listing the show/movie's `.nfo` cast and its bonus
  videos — files in `Extras` / `Featurettes` / `Behind the Scenes` /
  `Deleted Scenes` / `Specials` / `Trailers` folders, and Kodi `-trailer` /
  `-featurette` / `-deleted` / … named files. Extras play directly, and get a
  thumbnail auto-generated from the video (via ffmpeg) when they have no artwork.
- **Scrolling Cast & Extras labels.** A highlighted card's title/character now
  scrolls horizontally so long names aren't just truncated (Plex and Local Files).

### Changed
- **Broader Local Files episode detection.** Shows are now recognized from
  `SxxExx` / `S01 E02` / `1x02` markers in filenames and from a `tvshow.nfo`
  marking the show root, so flat folders and irregularly-named season folders are
  handled. Episode order falls back to natural/alphabetical for irregular names.
  Bonus content is kept out of the episode rotation (it lives in Cast & Extras).

### Fixed
- **Self-update** left the new version stranded in an `<install>.new` folder
  instead of applying: the apply helper inherited the install folder as its
  working directory, which blocked the folder swap. (The fix ships in the updater,
  so the first hop onto a fixed build must be a manual re-install.)

## [0.1.1] - 2026-07-15

### Added
- The installer downloads the upscaler shaders (ArtCNN, FSRCNNX, Anime4K) into the
  install folder, so the info-screen Upscaler options work out of the box. Opt out
  with `-SkipUpscalers`; already-downloaded shaders are preserved across updates.

## [0.1.0] - 2026-07-15

### Added
- Initial public release — the Windows-native port of
  [240-MP](https://github.com/anthonycaccese/240-MP). Highlights:
  - Plex, Local Files, Jellyfin, YouTube and Ambient:Mode modules.
  - mpv playback with a VCR-style on-screen control bar; the mpv window is married
    to the app as a single composed window.
  - Per-title playback settings (audio language, subtitle language, volume gain,
    video upscaler) that carry across a show's episodes.
  - Video upscalers (ArtCNN, FSRCNNX, Anime4K, High Quality) via GPU-accelerated
    mpv GLSL shaders.
  - Plex Home dashboard (Continue Watching, Recently Added, custom hubs) with
    hover fanart and theme music, and watch-progress bars on Continue Watching.
  - Cast & Extras and "up next" episode advance on the Plex info screen.
  - Keyboard, gamepad (SDL2) and touchscreen input; per-user install with an
    in-app self-updater; one-line PowerShell installer.

[0.7.0]: https://github.com/john-videojockey/240-MP-Win/compare/v0.6.2...v0.7.0
[0.6.2]: https://github.com/john-videojockey/240-MP-Win/compare/v0.6.1...v0.6.2
[0.6.1]: https://github.com/john-videojockey/240-MP-Win/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/john-videojockey/240-MP-Win/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/john-videojockey/240-MP-Win/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/john-videojockey/240-MP-Win/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/john-videojockey/240-MP-Win/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/john-videojockey/240-MP-Win/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/john-videojockey/240-MP-Win/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/john-videojockey/240-MP-Win/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/john-videojockey/240-MP-Win/releases/tag/v0.1.0
