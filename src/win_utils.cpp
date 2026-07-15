#include "win_utils.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QMutex>
#include <QStandardPaths>

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <shobjidl.h>   // ITaskbarList (drop mpv's separate taskbar button)
#include <cstdio>

// Laptop hybrid-GPU hint: ask the NVIDIA/AMD driver for the discrete GPU so
// QML rendering doesn't land on a struggling iGPU profile. Read by the driver
// at process start; harmless everywhere else.
extern "C" {
__declspec(dllexport) DWORD NvOptimusEnablement = 0x00000001;
__declspec(dllexport) int AmdPowerXpressRequestHighPerformance = 1;
}

namespace {

QFile   g_logFile;
QMutex  g_logMutex;
bool    g_haveConsole = false;

constexpr qint64 kLogRotateBytes = 1 * 1024 * 1024;

void messageHandler(QtMsgType type, const QMessageLogContext &, const QString &msg) {
    const char *level =
          type == QtDebugMsg    ? "D"
        : type == QtInfoMsg     ? "I"
        : type == QtWarningMsg  ? "W"
        : type == QtCriticalMsg ? "C" : "F";
    const QString line = QStringLiteral("%1 [%2] %3\n")
        .arg(QDateTime::currentDateTime().toString(QStringLiteral("yyyy-MM-dd HH:mm:ss.zzz")),
             QLatin1String(level), msg);
    const QByteArray utf8 = line.toUtf8();

    QMutexLocker lock(&g_logMutex);
    if (g_logFile.isOpen()) {
        g_logFile.write(utf8);
        g_logFile.flush();
    }
    if (g_haveConsole) {
        fwrite(utf8.constData(), 1, size_t(utf8.size()), stderr);
        fflush(stderr);
    }
    if (type == QtFatalMsg)
        abort();
}

} // namespace

void installWindowsLogging(const QString &dataRoot) {
    // GUI-subsystem apps have no console. Attaching to the launching terminal is
    // handy for interactive debugging, but ATTACH_PARENT_PROCESS grabs whatever
    // console is up the process tree — so a launcher started from a shell (e.g. a
    // taskbar app run from PowerShell that spawns 240-MP) gets our logs dumped
    // into that session. So it's opt-in: set MP240_CONSOLE=1 for live console
    // output; otherwise logs go only to the file below (which always has them).
    if (qEnvironmentVariableIntValue("MP240_CONSOLE") > 0 && AttachConsole(ATTACH_PARENT_PROCESS)) {
        FILE *unused;
        freopen_s(&unused, "CONOUT$", "w", stderr);
        freopen_s(&unused, "CONOUT$", "w", stdout);
        g_haveConsole = true;
    }

    const QString logDir = dataRoot + QStringLiteral("/logs");
    QDir().mkpath(logDir);
    const QString logPath = logDir + QStringLiteral("/240mp.log");

    // Single-file rotation: keep one previous session's worth of history.
    if (QFile::exists(logPath) && QFileInfo(logPath).size() > kLogRotateBytes) {
        const QString prev = logDir + QStringLiteral("/240mp.prev.log");
        QFile::remove(prev);
        if (!QFile::rename(logPath, prev))
            QFile::remove(logPath);   // rotation is best-effort; never block logging
    }

    g_logFile.setFileName(logPath);
    if (!g_logFile.open(QIODevice::Append | QIODevice::Text))
        g_logFile.close();

    qInstallMessageHandler(messageHandler);
}

void keepDisplayAwake() {
    // ES_CONTINUOUS makes the flags persist until the process exits, at which
    // point Windows automatically clears them — no teardown call needed.
    SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED);
}

QString findMpvExecutable() {
    // Explicit suffix bypasses PATHEXT (which would prefer mpv.com).
    QString bin = QStandardPaths::findExecutable(QStringLiteral("mpv.exe"));
    if (!bin.isEmpty())
        return bin;
    bin = QStandardPaths::findExecutable(QStringLiteral("mpv"));
    if (bin.endsWith(QLatin1String(".com"), Qt::CaseInsensitive)) {
        // Wrapper found without a sibling on PATH — swap for the real player.
        const QString exe = bin.left(bin.size() - 4) + QStringLiteral(".exe");
        if (QFile::exists(exe))
            return exe;
    }
    return bin;
}

namespace {

// EnumWindows callback state: find the visible top-level window owned by mpv's
// process. mpv's video-output window uses the "mpv" window class, which we
// prefer; any other visible, un-owned top-level window of the same process is a
// fallback (covers window-class changes across mpv builds).
struct MpvWindowSearch {
    DWORD pid;
    HWND  best;
};

BOOL CALLBACK findMpvWindowProc(HWND hwnd, LPARAM lparam) {
    auto *s = reinterpret_cast<MpvWindowSearch *>(lparam);
    DWORD wpid = 0;
    GetWindowThreadProcessId(hwnd, &wpid);
    if (wpid != s->pid)              return TRUE;   // different process
    if (!IsWindowVisible(hwnd))      return TRUE;   // hidden helper/message window
    if (GetWindow(hwnd, GW_OWNER))   return TRUE;   // already owned → not the VO window

    wchar_t cls[64] = {0};
    GetClassNameW(hwnd, cls, 63);
    if (wcscmp(cls, L"mpv") == 0) {
        s->best = hwnd;
        return FALSE;               // exact match — stop enumerating
    }
    if (!s->best)
        s->best = hwnd;             // remember first candidate, keep looking for "mpv"
    return TRUE;
}

} // namespace

quintptr adoptMpvWindow(quintptr ownerHwnd, qint64 mpvPid) {
    if (!ownerHwnd || mpvPid <= 0)
        return 0;

    MpvWindowSearch search{ DWORD(mpvPid), nullptr };
    EnumWindows(findMpvWindowProc, reinterpret_cast<LPARAM>(&search));
    if (!search.best)
        return 0;   // mpv's window isn't up yet — caller retries

    HWND mpv   = search.best;
    HWND owner = reinterpret_cast<HWND>(ownerHwnd);

    // Own the player with the menu window. For a non-child top-level window,
    // GWLP_HWNDPARENT sets the OWNER (not a parent): mpv stays a normal focusable
    // top-level (its OSC and OS-focus-based input hand-off keep working) but now
    // sits above the menu in Z-order and is hidden whenever the menu minimizes.
    SetWindowLongPtrW(mpv, GWLP_HWNDPARENT, reinterpret_cast<LONG_PTR>(owner));

    // Verify ownership actually took. Setting another process's window owner can
    // fail silently (timing, cross-process restrictions); if it didn't stick,
    // report failure so the caller keeps polling instead of trusting a
    // half-applied marriage (which is what leaves the two windows "split").
    if (GetWindow(mpv, GW_OWNER) != owner)
        return 0;

    // Remove mpv's own taskbar button so the pair shows a single button (the
    // menu window's). DeleteTab does this without a hide/show cycle, so there's
    // no flicker of the fullscreen video. Uses __uuidof so no CLSID_/IID_ import
    // lib is needed; COM is already initialised on Qt's GUI thread.
    ITaskbarList *taskbar = nullptr;
    if (SUCCEEDED(CoCreateInstance(__uuidof(TaskbarList), nullptr, CLSCTX_INPROC_SERVER,
                                   __uuidof(ITaskbarList),
                                   reinterpret_cast<void **>(&taskbar))) && taskbar) {
        if (SUCCEEDED(taskbar->HrInit()))
            taskbar->DeleteTab(mpv);
        taskbar->Release();
    }

    return reinterpret_cast<quintptr>(mpv);
}

void raiseMpvWindow(quintptr mpvHwnd) {
    HWND h = reinterpret_cast<HWND>(mpvHwnd);
    if (!h || !IsWindow(h))
        return;
    if (IsIconic(h))
        ShowWindow(h, SW_RESTORE);
    SetWindowPos(h, HWND_TOP, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
    SetForegroundWindow(h);
}

void minimizeMpvWindow(quintptr mpvHwnd) {
    HWND h = reinterpret_cast<HWND>(mpvHwnd);
    if (!h || !IsWindow(h) || IsIconic(h))
        return;
    ShowWindow(h, SW_MINIMIZE);
}

void forceForegroundWindow(quintptr hwnd) {
    HWND h = reinterpret_cast<HWND>(hwnd);
    if (!h || !IsWindow(h))
        return;
    if (IsIconic(h))
        ShowWindow(h, SW_RESTORE);

    // Windows only lets the current foreground app hand focus away, so a plain
    // SetForegroundWindow from here is ignored. Attach our input queue to the
    // current foreground thread's so we count as "the same" app for the duration,
    // then raise/activate. (A HWND_TOPMOST toggle also works but briefly re-layers
    // the fullscreen window, flashing the desktop — BringWindowToTop is gap-free.)
    const HWND fg = GetForegroundWindow();
    const DWORD fgThread   = fg ? GetWindowThreadProcessId(fg, nullptr) : 0;
    const DWORD thisThread = GetCurrentThreadId();
    const bool attached = fgThread && fgThread != thisThread
                          && AttachThreadInput(thisThread, fgThread, TRUE);

    BringWindowToTop(h);
    SetForegroundWindow(h);
    SetActiveWindow(h);

    if (attached)
        AttachThreadInput(thisThread, fgThread, FALSE);
}

void prependToolDirsToPath(const QString &appRoot) {
    const QStringList candidates = {
        appRoot + QStringLiteral("/mpv"),
        qEnvironmentVariable("LOCALAPPDATA") + QStringLiteral("/Microsoft/WinGet/Links"),
        QDir::homePath() + QStringLiteral("/scoop/shims"),
        qEnvironmentVariable("ProgramData") + QStringLiteral("/chocolatey/bin"),
    };

    QString path = qEnvironmentVariable("PATH");
    const QStringList current = path.split(QLatin1Char(';'), Qt::SkipEmptyParts);
    for (const QString &c : candidates) {
        const QString native = QDir::toNativeSeparators(QDir(c).absolutePath());
        if (!QDir(c).exists() || current.contains(native, Qt::CaseInsensitive))
            continue;
        path = native + QLatin1Char(';') + path;
    }
    qputenv("PATH", path.toLocal8Bit());
}
