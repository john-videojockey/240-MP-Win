#pragma once
#include <QString>

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
