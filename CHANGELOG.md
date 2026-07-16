# Changelog

All notable changes to 240-MP for Windows are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
  `-featurette` / `-deleted` / … named files. Extras play directly.

### Changed
- **Broader Local Files episode detection.** Shows are now recognized from
  `SxxExx` / `S01 E02` / `1x02` markers in filenames and from a `tvshow.nfo`
  marking the show root, so flat folders and irregularly-named season folders are
  handled. Episode order falls back to natural/alphabetical for irregular names.
  Bonus content is kept out of the episode rotation (it lives in Cast & Extras).

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

[0.2.0]: https://github.com/john-videojockey/240-MP-Win/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/john-videojockey/240-MP-Win/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/john-videojockey/240-MP-Win/releases/tag/v0.1.0
