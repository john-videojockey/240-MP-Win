# 240-MP for Windows

240-MP is a retro VCR style frontend to play content on a TV-connected PC. **This repository is the Windows port** of [anthonycaccese/240-MP](https://github.com/anthonycaccese/240-MP), which targets Raspberry Pi (preferably hooked up to a CRT TV) and macOS. Everything about the experience is the same — the VCR-style UI, the modules, the mpv hand-off — rebuilt on Windows-native plumbing.

Playback experiences are handled via modules to enable new integrations without requiring major changes to the overall frontend. There are 5 included playback modules; [Local Files](https://github.com/anthonycaccese/240-MP/wiki/Module:-Local-Files), [Plex](https://github.com/anthonycaccese/240-MP/wiki/Module:-Plex), [Jellyfin](https://github.com/anthonycaccese/240-MP/wiki/Module:-Jellyfin), [YouTube](https://github.com/anthonycaccese/240-MP/wiki/Module:-YouTube) and a module similar to art/wallpaper modes on modern tvs called [Ambient:Mode](https://github.com/anthonycaccese/240-MP/wiki/Module:-Ambient-Mode).

It works in conjunction with [mpv](https://mpv.io/), which the [install script](#install) sets up as a dependency.

## What's different in the Windows port

The philosophy and module system are untouched (see [ARCHITECTURE.md](ARCHITECTURE.md)); the platform layer was rebuilt for Windows rather than translated line-by-line:

- **mpv control channel** uses a Windows named pipe (`\\.\pipe\240mp-mpv`) instead of a Unix socket — both mpv and Qt speak it natively.
- **Hardware video decode** via D3D11VA (`--hwdec=auto-safe`); override per-device with the `mpv_video_args` setting.
- **Gamepads** still go through SDL2 — on Windows that covers XInput and DirectInput pads (Xbox, PlayStation, 8BitDo, NES-style clones) with hotplug, exactly like upstream.
- **Self-update** downloads the release zip and swaps the install folder with a detached helper — no admin prompt, because the app installs per-user under `%LOCALAPPDATA%\Programs\240-MP`.
- **Install** is one PowerShell script that also brings in mpv/yt-dlp via winget (or scoop/choco). Optional autostart-at-logon via a Startup shortcut. No admin rights required for any of it.
- **mpv can be bundled**: drop `mpv.exe` into `<app folder>\mpv\` and 240-MP prefers it over any system install — handy for a fully portable setup.
- **Directory browser understands drives** — navigate above `C:\` to switch to the drive where your media lives.
- **Touchscreen support** — tap to highlight, tap again to select, everywhere; floating ◄ BACK and minimize buttons; during playback, tap to show the controls, tap them to seek/pause/switch tracks, tap elsewhere to hide.
- **Plex extras** — optional Cover browse view (poster grid for movies/shows), episode thumbnails, PREV/NEXT episode buttons on the info screen, and an optional fanart background with scanlines (opacity configurable) — all under Settings → Plex.
- **Logs** land in `%APPDATA%\240-MP\logs\240mp.log` (and in your terminal when launched from one), since Windows GUI apps have no stdout.
- The display is kept awake while the app runs (it's a TV frontend with its own screen saver); Windows power settings resume control when it exits.

Everything Raspberry-Pi-specific (KMS/DRM hand-off, per-Pi decode profiles, systemd autostart) does not apply here and was removed rather than ported.

## Current Features

### Local Files Module ([Wiki](https://github.com/anthonycaccese/240-MP/wiki/Module:-Local-Files))
- Supported file types: `"mp4", "mkv", "avi", "mov", "m4v", "webm", "wmv", "flv", "f4v", "mpg", "mpeg", "vob"`
- Playlist support using `m3u` and `m3u8` files
- Folder browsing
- Loop playback
- Shuffle playback
- Playback history
- Switch audio/subtitle tracks during playback

### Plex Module ([Wiki](https://github.com/anthonycaccese/240-MP/wiki/Module:-Plex))
- Designed for simple, fast, list browsing
- Supported library types: `Movies, TV Shows, Other Videos`
- Server switching
- User profile switching and auto sign in
- Select specific libraries to display
- Continue Watching and Resume
- Autoplay next episode in a season (optional, off by default)
- Hub, Playlist, Collection and Category support
- Movie editions
- Select preferred audio/subtitle track before playback and switch tracks during playback
- Full library browsing by letter
- Show/Season browsing
- Video quality selection: Direct Playback (Default) or Transcode options

### Jellyfin Module ([Wiki](https://github.com/anthonycaccese/240-MP/wiki/Module:-Jellyfin))
- Designed for simple, fast, list browsing
- Supported library types: `movies, tvshows, homevideos, boxsets`
- "Quick Connect" authentication
- Select specific libraries to display
- Continue Watching, Next Up and Resume Playback
- Autoplay next episode in a season (optional, off by default)
- Collections support
- Select preferred audio/subtitle track before playback and switch tracks during playback
- Full library browsing by letter
- Show/Season browsing
- Video quality selection: Direct Playback (Default) or Transcode options

### YouTube Module ([Wiki](https://github.com/anthonycaccese/240-MP/wiki/Module:-YouTube))
- Designed for simple, fast, list browsing
- Built to list content from YouTube RSS feeds and playback via mpv + yt-dlp (no auth required)
- View Subscriptions: Browse the latest videos from your configured channels as a reverse chronological list
- Browse by Channel: Browse videos by Channel
- Save to Watch Later: Save videos to watch later. This is local to 240-MP (on device only), not associated to any account and the list can be cleared in settings at any time.
- View Watch History: Displays a list of recently watch videos via the module. This is local to 240-MP (on device only), not associated to any account and the list can be cleared in settings at any time.
- Resume Playback: Resume from your last playback position or restart from the beginning
- Set Playback Resolution: 480p, 720p and 1080p
- Choose to Display Shorts or not (default is On)

### Ambient:Mode Module ([Wiki](https://github.com/anthonycaccese/240-MP/wiki/Module:-Ambient-Mode))
- Supported video file types: `"mp4", "mkv", "avi", "mov", "m4v", "webm", "wmv", "flv", "f4v", "mpg", "mpeg", "vob"`
- Playlist support for audio tracks using `m3u` and `m3u8` files
- Mix video with a different audio track
- Loops forever until you stop it

### Global
- [Color Schemes](https://github.com/anthonycaccese/240-MP/wiki/Customizations)
- [Keyboard & Controller](https://github.com/anthonycaccese/240-MP/wiki/Input) input support, plus touchscreen/mouse navigation
- Media Keys during video playback (volume +/-, mute, play/pause, stop, seek, next chapter, previous chapter)
- In-app self-update from GitHub Releases

## Install

One-liner (PowerShell — no admin needed):

```powershell
irm https://github.com/anthonycaccese/240-mp-win/releases/latest/download/install.ps1 | iex
```

Full options (autostart, custom folder, uninstall) and the manual zip install are in **[INSTALL.md](INSTALL.md)**. Building from source is covered in **[BUILDING.md](BUILDING.md)**.

## FAQs

- Why didn't you use Kodi/Plex HTPC/Jellyfin Media Player?
    - Those are all excellent. 240-MP is deliberately simpler — something that feels like a VCR from my youth. See the [upstream FAQ](https://github.com/anthonycaccese/240-MP#faqs) for the whole philosophy.
- Where does the name "240-MP" come from?
    - 240 refers to the longest [VHS tape length](https://en.wikipedia.org/wiki/VHS#Tape_lengths) and the upstream project's CRT display target of [240p](https://consolemods.org/wiki/CRT:What_is_240p%3F). MP means "Media Player" and plays on the "SP/LP/EP/SLP" VHS recording-quality terminology.
- Does it output 240p?
    - No — the UI scales to your display's resolution. On a modern TV over HDMI it renders at native resolution; it just *looks* gloriously 1985.
- Can I keep using my Raspberry Pi / Mac?
    - Yes — use [upstream 240-MP](https://github.com/anthonycaccese/240-MP) there. Settings concepts are identical, so switching between them is painless.

## Credits & Acknowledgments

- This is a Windows port of [240-MP](https://github.com/anthonycaccese/240-MP) by Anthony Caccese — all of the app's design, modules, and views are his work.
- The `VCR OSD Mono` font was created by Riciery Santos Leal (a.k.a. mrmanet) https://www.dafont.com/vcr-osd-mono.font
- Like upstream, this port was built with substantial help from [Claude Code](https://www.anthropic.com/product/claude-code).
- Thank you to Plex for providing an open and free [API](https://developer.plex.tv/), and to [the mpv team](https://mpv.io/) for a simple, extensible and cross platform media player.

## License

This project is licensed under the GNU General Public License v3.0. See [LICENSE](LICENSE) for the full text.

You are free to use, study, and modify this code. If you distribute a modified version, you must also distribute it under GPL-3.0 and make the source available.
