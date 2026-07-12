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
    // GUI-subsystem apps have no console; if the app was started from one,
    // attach so logs print in that terminal like they do on other platforms.
    if (AttachConsole(ATTACH_PARENT_PROCESS)) {
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
