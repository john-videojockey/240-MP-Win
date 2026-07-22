# Changelog

All notable changes to 240-MP for Windows are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.6.0]: https://github.com/john-videojockey/240-MP-Win/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/john-videojockey/240-MP-Win/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/john-videojockey/240-MP-Win/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/john-videojockey/240-MP-Win/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/john-videojockey/240-MP-Win/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/john-videojockey/240-MP-Win/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/john-videojockey/240-MP-Win/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/john-videojockey/240-MP-Win/releases/tag/v0.1.0
