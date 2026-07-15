#pragma once
#include <QString>
#include <QtGlobal>

// Windows platform glue for 240-MP. Each function is a no-op-safe, call-once
// setup step invoked from main() before the QML engine loads.

// Routes qDebug/qWarning/qCritical somewhere visible. 240-MP builds as a GUI
// subsystem app (no console window), so stdout/stderr go nowhere by default.
// When launched from a terminal this attaches to it so logs print right there;
// in every case logs are also appended to <dataRoot>/logs/240mp.log (rotated
// at ~1 MB) so "it won't start" reports always have something to attach.
void installWindowsLogging(const QString &dataRoot);

// Tells Windows the display is in use for the lifetime of the app.
// 240-MP is a TV frontend with its own screen saver; without this the OS
// blanks the screen mid-browse on default power plans. mpv manages its own
// keep-awake during playback, so this only needs to cover the menus.
void keepDisplayAwake();

// Prepends the directories where mpv/yt-dlp typically live on Windows to this
// process's PATH so QStandardPaths::findExecutable (and mpv's own yt-dlp
// lookup, which inherits our environment) resolve them even when the app is
// launched from a Start Menu shortcut with a minimal PATH:
//   <appRoot>/mpv           — an optional app-bundled mpv/yt-dlp
//   WinGet links            — %LOCALAPPDATA%/Microsoft/WinGet/Links
//   Scoop shims             — %USERPROFILE%/scoop/shims
//   Chocolatey bin          — %ProgramData%/chocolatey/bin
void prependToolDirsToPath(const QString &appRoot);

// Resolves the real mpv player binary. Never returns the mpv.com console
// wrapper that official builds ship next to mpv.exe: PATHEXT prefers .COM, so
// a plain findExecutable("mpv") hands back the wrapper, which runs the actual
// player as a *separate* process — QProcess::terminate()/kill() would then hit
// only the wrapper and leave the video playing (the next-episode swap used to
// leak an orphaned fullscreen mpv exactly this way). Empty string if no mpv.
QString findMpvExecutable();

// ── Window marriage ────────────────────────────────────────────────────────────
// mpv plays in its own top-level fullscreen window (a separate process), so by
// default it and the app's menu window are two independent windows: two taskbar
// buttons, and a "minimize" sent to one leaves the other on screen. These helpers
// make them behave as a single composed window without embedding mpv (which would
// break the input hand-off that relies on mpv owning OS focus).

// Finds mpv's top-level window by process id and marries it to the app's main
// window: makes it an *owned* window of ownerHwnd (so the player stays above the
// menu) and removes its separate taskbar button. mpv's window appears
// asynchronously after launch, so this returns 0 until it exists AND ownership
// verifiably took (a cross-process window call can fail silently) — the caller
// polls and retries until it succeeds. Idempotent, so re-calling just re-asserts
// the marriage. On success returns mpv's window handle (opaque), passed back to
// raiseMpvWindow()/minimizeMpvWindow().
quintptr adoptMpvWindow(quintptr ownerHwnd, qint64 mpvPid);

// Un-minimizes the mpv window (if needed) and brings it back to the front with
// focus. Called when the app's owner window is restored so the video returns on
// top of the menu. No-op if mpvHwnd is 0 or no longer a valid window.
void raiseMpvWindow(quintptr mpvHwnd);

// Minimizes the mpv window. Called when the owner window is minimized so the
// player drops with it explicitly, rather than relying only on owned-window
// auto-hide (which needs the marriage to have taken). No-op if mpvHwnd is 0,
// invalid, or already minimized.
void minimizeMpvWindow(quintptr mpvHwnd);

// Force the given window to the foreground, bypassing Windows' foreground lock
// (which makes a plain SetForegroundWindow/QWindow::requestActivate a no-op when
// the caller isn't already the foreground app — e.g. right after the fullscreen
// mpv window it was behind has closed). Called when playback ends so the menu
// returns on top instead of behind another app's window.
void forceForegroundWindow(quintptr hwnd);

// True while the given handle is still a live window. Used to detect mpv's window
// closing (which precedes process exit) so the menu can be raised right then.
bool isWindowAlive(quintptr hwnd);

// Toggle a window's always-on-top (WS_EX_TOPMOST) state without activating it.
// The menu is made topmost during playback so that when the owned mpv window
// closes, the menu is already above every ordinary window — no frame where another
// window shows through — then dropped back to normal once playback ends. mpv, being
// owned by the menu, stays above it either way, so the video is never covered.
void setWindowTopmost(quintptr hwnd, bool on);
