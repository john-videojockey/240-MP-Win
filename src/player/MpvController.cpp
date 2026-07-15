#include "MpvController.h"
#include "../AppCore.h"
#include "../win_utils.h"
#include <QDir>
#include <QFile>
#include <QProcessEnvironment>
#include <QJsonDocument>
#include <QJsonObject>
#include <QStandardPaths>
#include <QDateTime>
#include <QRegularExpression>
#include <QQuickWindow>
#include <QDebug>

MpvController::MpvController(const QString &appRoot, AppCore *appCore, QObject *parent)
    : QObject(parent)
    , m_appCore(appCore)
    , m_appRoot(appRoot)
    // Windows IPC is a named pipe, not a filesystem socket. mpv's
    // --input-ipc-server and QLocalSocket::connectToServer both accept the
    // full \\.\pipe\ form, so one string serves both ends of the channel.
    , m_pipePath(QStringLiteral("\\\\.\\pipe\\240mp-mpv"))
    , m_inputConfPath(QDir::tempPath() + "/240mp-input.conf")
    , m_logFilePath(QDir::tempPath() + "/240mp-mpv.log")
    , m_subInfoPath(QDir::tempPath() + "/240mp-mpv-subinfo.json")
{
    QFile f(m_inputConfPath);
    if (f.open(QFile::WriteOnly | QFile::Text)) {
        f.write("ESC quit\n");
        f.write("BS quit\n");
        // ENTER opens the OSC (bound in mpv-osc.lua); SPACE remains the quick
        // pause toggle, so ENTER is deliberately NOT mapped to pause here.
        f.close();
    }

    m_hasMpvOscScript     = QFile::exists(m_appRoot + "/scripts/mpv-osc.lua");
    m_hasAmbientOscScript = QFile::exists(m_appRoot + "/scripts/ambient-osc.lua");
    m_hasMediaKeysScript  = QFile::exists(m_appRoot + "/scripts/media-keys.lua");

    m_ipc = new QLocalSocket(this);
    connect(m_ipc, &QLocalSocket::connected, this, [this] {
        m_connectTimer->stop();
        m_lastIpcEventMs = QDateTime::currentMSecsSinceEpoch();
        m_watchdogTimer->start();
        sendCommand({"observe_property", 1, "time-pos"});
        sendCommand({"observe_property", 2, "duration"});
        sendCommand({"observe_property", 3, "playlist-pos"});
        sendCommand({"observe_property", 4, "pause"});
        // window-minimized lets us catch a "minimize" sent to mpv (it holds OS
        // focus during playback) and mirror it onto the married owner window.
        sendCommand({"observe_property", 5, "window-minimized"});
    });
    connect(m_ipc, &QLocalSocket::readyRead, this, &MpvController::onIpcReadyRead);

    m_connectTimer = new QTimer(this);
    m_connectTimer->setInterval(100);
    connect(m_connectTimer, &QTimer::timeout, this, &MpvController::tryConnectIpc);

    // Watchdog: fires every 10 s; logs a warning if no IPC time-pos event has
    // arrived for 30 s while connected — strong indicator of a playback freeze.
    // Exempt while paused: time-pos is legitimately silent then (a long pause is
    // a normal state now that the screen saver runs over it), and the unpause
    // property-change event refreshes m_lastIpcEventMs so the 30 s window
    // restarts fresh on resume.
    m_watchdogTimer = new QTimer(this);
    m_watchdogTimer->setInterval(10000);
    connect(m_watchdogTimer, &QTimer::timeout, this, [this] {
        if (m_ipc->state() != QLocalSocket::ConnectedState || m_paused) return;
        qint64 silenceMs = QDateTime::currentMSecsSinceEpoch() - m_lastIpcEventMs;
        if (silenceMs > 30000) {
            qWarning("[MpvController] WATCHDOG: no IPC time-pos event for %lld s — possible freeze",
                     silenceMs / 1000);
        }
    });

    // mpv's window appears a beat after the process starts, so poll briefly for
    // it and marry it to the main window once it exists (see tryAdoptMpvWindow).
    m_adoptTimer = new QTimer(this);
    m_adoptTimer->setInterval(120);
    connect(m_adoptTimer, &QTimer::timeout, this, &MpvController::tryAdoptMpvWindow);
}

MpvController::~MpvController() {
    if (m_process && m_process->state() != QProcess::NotRunning) {
        m_process->terminate();               // WM_CLOSE to mpv's window
        if (!m_process->waitForFinished(2000)) {
            m_process->kill();                // TerminateProcess fallback
            m_process->waitForFinished(500);
        }
    }
}

void MpvController::loadAndPlay(const QString &url, float startSeconds,
                                 int audioTrack, int subTrack,
                                 const QStringList &subFiles,
                                 const QStringList &subLangs, bool loop,
                                 int playlistStart, float transcodeOffsetSec,
                                 const QString &plexToken, bool muteAudio,
                                 const QString &oscMode, bool shuffle,
                                 const QStringList &subTitles, float imageDurationSec,
                                 bool imageContent, const QStringList &extraArgs, const QString &jellyfinToken) {
    // Replace-while-playing (e.g. the OSC's next-episode button): the old mpv
    // must be fully gone before the new one starts, or it keeps the screen AND
    // the IPC pipe name, leaving the replacement running deaf in the background.
    // Ask nicely over IPC first (clean fullscreen teardown), then escalate.
    if (m_process) {
        m_process->disconnect();
        if (m_process->state() != QProcess::NotRunning) {
            if (m_ipc->state() == QLocalSocket::ConnectedState) {
                sendCommand({"quit"});
                m_ipc->flush();
                m_process->waitForFinished(1000);
            }
            if (m_process->state() != QProcess::NotRunning) {
                m_process->terminate();
                if (!m_process->waitForFinished(1000)) {
                    m_process->kill();
                    m_process->waitForFinished(500);
                }
            }
        }
        m_process->deleteLater();
        m_process = nullptr;
    }
    m_watchdogTimer->stop();
    m_adoptTimer->stop();
    m_mpvHwnd     = 0;   // previous player's window (if any) is being torn down
    m_ipc->abort();
    m_position    = 0;
    m_duration    = 0;
    m_playlistPos = -1;
    m_paused      = false;
    m_lastEndFileReason.clear();

    // PATH was extended at startup (win_utils prependToolDirsToPath) to cover
    // an app-bundled <appRoot>/mpv as well as WinGet/Scoop/Chocolatey installs.
    // findMpvExecutable targets mpv.exe, never the mpv.com console wrapper —
    // process control (terminate/kill) must reach the actual player.
    const QString bin = findMpvExecutable();
    if (bin.isEmpty()) {
        qWarning("[MpvController] mpv not found — install it (winget install shinchiro.mpv) "
                 "or place mpv.exe in <app folder>\\mpv\\");
        QTimer::singleShot(0, this, [this]() {
            emit playbackEnded(0, 0, QStringLiteral("stopped"));
        });
        return;
    }
    qInfo("[MpvController] using mpv at %s", qPrintable(bin));

    const bool hasOscScript = (oscMode == "ambient") ? m_hasAmbientOscScript : m_hasMpvOscScript;
    const QString oscScript = m_appRoot + "/scripts/" + ((oscMode == "ambient") ? "ambient-osc.lua" : "mpv-osc.lua");

    // Stamp the log file so each session is identifiable. mpv logs its command
    // line (incl. auth headers) at verbose level into --log-file; the file lives
    // in the per-user %TEMP%, which is not readable by other users on Windows.
    {
        QFile lf(m_logFilePath);
        if (lf.open(QFile::Append | QFile::Text)) {
            QString safeUrl = url;
            safeUrl.replace(QRegularExpression("Api[_-]?Key=[^&\\s]+", QRegularExpression::CaseInsensitiveOption), "ApiKey=REDACTED");
            safeUrl.replace(QRegularExpression("X-Plex-Token[=:][^&\\s]+"), "X-Plex-Token=REDACTED");
            safeUrl.replace(QRegularExpression("Token=\"[^\"]+\""), "Token=\"REDACTED\"");
            lf.write(QString("\n=== 240-MP session start %1 ===\n    url: %2\n\n")
                         .arg(QDateTime::currentDateTime().toString(Qt::ISODate))
                         .arg(safeUrl)
                         .toUtf8());
        }
    }

    QStringList args;
    args << url
         << QString("--input-ipc-server=%1").arg(m_pipePath)
         << QString("--log-file=%1").arg(m_logFilePath)
         << (hasOscScript ? "--osc=no" : "--osc=yes")
         << "--osd-level=0"
         // Silence mpv's periodic terminal status line ("AV: .. A-V: .."). We
         // capture mpv's stdout/stderr to mirror real messages into the app log,
         // but that status line prints many times a second and would flood both
         // the log and any console the app is attached to. Full detail still goes
         // to --log-file. (logMpvOutput also filters any that slip through.)
         << "--term-status-msg=";

    if (hasOscScript)
        args << QString("--script=%1").arg(oscScript);

    // Media-key handling + themed volume bar — loaded for every mode so HID
    // media keys work anytime mpv is playing, not just inside a given module.
    if (m_hasMediaKeysScript)
        args << QString("--script=%1").arg(m_appRoot + "/scripts/media-keys.lua");

    // Screen saver Lua script — only loaded when the user has opted in via the
    // screensaver_timeout setting (a positive number of seconds; "OFF" parses
    // to 0 and disables). The timeout reaches the script via scriptOpts below.
    int screensaverTimeout = 0;
    if (m_appCore) {
        const int n = m_appCore->get_setting(QString(), "screensaver_timeout").toString().toInt();
        const QString ssScript = m_appRoot + "/scripts/screensaver.lua";
        if (n > 0 && QFile::exists(ssScript)) {
            screensaverTimeout = n;
            args << QString("--script=%1").arg(ssScript);
        }
    }

    // Still-image playback: nudges a render-affecting property on each playlist
    // advance so photo slideshows repaint reliably. Loaded only for image
    // content, so video playback is untouched.
    if (imageContent) {
        const QString slideshowScript = m_appRoot + "/scripts/slideshow-redraw.lua";
        if (QFile::exists(slideshowScript))
            args << QString("--script=%1").arg(slideshowScript);
    }

    if (playlistStart >= 0)
        args << QString("--playlist-start=%1").arg(playlistStart);
    if (startSeconds > 0.5f)
        args << QString("--start=%1").arg(double(startSeconds), 0, 'f', 3);
    if (audioTrack > 0)
        args << QString("--aid=%1").arg(audioTrack);
    for (const QString &sf : subFiles)
        args << QString("--sub-file=%1").arg(sf);
    if (subTrack > 0)
        args << QString("--sid=%1").arg(subTrack);
    else if (subTrack < -1)
        // subs disabled or provided via transcode
        args << QStringLiteral("--sid=no");
    else if (subTrack == -1)
        // forced subs only
        args << QStringLiteral("--subs-with-matching-audio=forced") << QStringLiteral("--subs-fallback-forced=always");
    else if (subTrack == 0) {
        // Always display subs, even if the audio and subtitle languages match
        args << QStringLiteral("--subs-with-matching-audio=yes") << QStringLiteral("--subs-fallback=yes");
        if (subFiles.isEmpty())
            // use embedded or auto-matched sub
            args << QStringLiteral("--sid=auto");
    }
    // else: external sub(s) loaded, subTrack==0 → mpv auto-selects first loaded sub
    if (!subLangs.isEmpty())
        args << QString("--slang=%1").arg(subLangs.join(QStringLiteral(",")));

    QStringList scriptOpts;
    if (transcodeOffsetSec > 0.5f)
        scriptOpts << QString("transcode-offset=%1").arg(double(transcodeOffsetSec), 0, 'f', 3);
    if (screensaverTimeout > 0)
        scriptOpts << QString("screensaver_timeout=%1").arg(screensaverTimeout);

    // App-level "seek_seconds" setting: how far the OSC's <</>>  buttons and
    // LEFT/RIGHT on the seek bar jump. Read per launch so a settings change
    // applies on the next playback.
    {
        int seekSeconds = 10;
        if (m_appCore) {
            const int n = m_appCore->get_setting(QString(), "seek_seconds").toString().toInt();
            if (n > 0) seekSeconds = n;
        }
        scriptOpts << QString("seek-seconds=%1").arg(seekSeconds);
    }

    // Hand the OSC a map of external sub-file URL -> friendly track name so it can show
    // the real subtitle name. mpv otherwise titles an external sub from its URL basename
    // (e.g. "Stream.srt" for Jellyfin sidecars). Purely cosmetic — it does not affect
    // which sub mpv loads or selects.
    QFile::remove(m_subInfoPath);
    if (!subTitles.isEmpty() && subTitles.size() == subFiles.size()) {
        QJsonObject info;
        for (int i = 0; i < subFiles.size(); ++i) {
            if (!subTitles[i].isEmpty())
                info.insert(subFiles[i], subTitles[i]);
        }
        QFile sf(m_subInfoPath);
        if (!info.isEmpty() && sf.open(QFile::WriteOnly | QFile::Truncate)) {
            sf.write(QJsonDocument(info).toJson(QJsonDocument::Compact));
            sf.close();
            // Path is comma- and space-free, so it is safe in the script-opts list.
            scriptOpts << QString("subinfo-file=%1").arg(m_subInfoPath);
        }
    }
    if (!scriptOpts.isEmpty())
        args << QString("--script-opts=%1").arg(scriptOpts.join(QStringLiteral(",")));

    if (loop)
        args << QStringLiteral("--loop-playlist=inf");
    if (shuffle)
        args << QStringLiteral("--shuffle");
    // How long a still image is shown before mpv advances (or EOFs back to the
    // menu). Global for the launch, so it covers every image in a mixed playlist;
    // mpv ignores it for video and animated formats.
    if (imageDurationSec > 0.0f)
        args << QString("--image-display-duration=%1").arg(double(imageDurationSec), 0, 'f', 1);
    if (muteAudio)
        args << QStringLiteral("--no-audio");
    // yt-dlp hook intercepts HTTP media URLs and can break Plex/Jellyfin
    // playback with spurious 401/400 errors — disabled unless the caller
    // explicitly opts in via extraArgs (e.g. YouTube passes --ytdl=yes).
    bool ytdlOverridden = false;
    for (const QString &a : extraArgs) {
        if (a == QLatin1String("--ytdl") || a.startsWith(QLatin1String("--ytdl=")))
            ytdlOverridden = true;
    }
    if (!ytdlOverridden)
        args << QStringLiteral("--ytdl=no");
    args << extraArgs;
    if (!plexToken.isEmpty()) {
        args << QString("--http-header-fields=X-Plex-Token:%1").arg(plexToken);
    }
    if (!jellyfinToken.isEmpty()) {
        args << QString("--http-header-fields=Authorization:MediaBrowser Token=\"%1\"").arg(jellyfinToken);
    }

    // plex.direct certs are Let's Encrypt-signed but ffmpeg's bundled CA bundle
    // may not trust the full chain (same reason Qt needs ignoreSslErrors for these
    // hosts). Disable TLS verification only for plex.direct playback URLs.
    if (QUrl(url).host().endsWith(QStringLiteral(".plex.direct")))
        args << QStringLiteral("--tls-verify=no");

    // Auto Crop: start with panscan=1. The Windows decode path always renders
    // through the scaler, so crop is safe everywhere; the OSC CROP button still
    // toggles it live.
    if (autoCropEnabled())
        args << QStringLiteral("--panscan=1");

    m_process = new QProcess(this);
    m_process->setProcessChannelMode(QProcess::MergedChannels);
    connect(m_process,
            QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
            this, &MpvController::onProcessFinished);
    connect(m_process, &QProcess::readyRead, this, [this]() {
        logMpvOutput(m_process->readAll());
    });

    // Fullscreen hand-off: mpv opens its own fullscreen window over the Qt
    // window and takes OS focus; when it exits, focus falls back to the app.
    // Gamepad input keeps flowing meanwhile via InputManager's IPC bridge.
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    env.insert("APP_ROOT", m_appRoot);
    m_process->setProcessEnvironment(env);
    args << QString("--input-conf=%1").arg(m_inputConfPath)
         << "--video-sync=audio"
         << "--fullscreen";
    appendVideoArgs(args);
    appendUpscalerArgs(args);
    // mpv runs as a separate process and can't see the app's FontLoader font.
    // --osd-fonts-dir loads the bundled VCR OSD Mono straight into the OSD
    // libass instance (used by the OSC scripts), no system install needed.
    args << QString("--osd-fonts-dir=%1").arg(m_appRoot + "/assets/fonts");

    QString safeCmd = args.join(" ");
    // Redact all token forms in debug output
    safeCmd.replace(QRegularExpression("Api[_-]?Key=[^&\\s]+", QRegularExpression::CaseInsensitiveOption), "ApiKey=REDACTED");
    safeCmd.replace(QRegularExpression("X-Plex-Token[=:][^&\\s]+"), "X-Plex-Token=REDACTED");
    safeCmd.replace(QRegularExpression("Token=\"[^\"]+\""), "Token=\"REDACTED\"");
    qDebug("[MpvController] launch: mpv %s", qPrintable(safeCmd));
    m_process->start(bin, args);
    m_connectTimer->start();
    // Begin looking for mpv's window so we can marry it to the menu window.
    if (m_mainWindow) {
        m_mpvHwnd = 0;                     // clear any stale handle from a prior play
        m_adoptTries = 0;
        m_adoptTimer->setInterval(120);   // reset from the post-marriage fast watch
        m_adoptTimer->start();
    }
}

// Polls (every ~120 ms) for mpv's fullscreen window after launch and marries it
// to the main window once it appears: single taskbar button, player above the
// menu, minimize/restore as one. Gives up after a few seconds so a headless or
// window-less mpv (e.g. a failed launch) doesn't poll forever.
void MpvController::tryAdoptMpvWindow() {
    if (!m_mainWindow || !m_process || m_process->state() != QProcess::Running) {
        m_adoptTimer->stop();
        return;
    }
    // Once married, the same timer switches to a fast watch for mpv's window
    // closing. mpv destroys its window a noticeable beat before the process exits
    // (it saves state, tears down, …), so acting on the window's disappearance —
    // rather than onProcessFinished — raises the menu before Windows can paint a
    // frame of it behind whatever it re-activated.
    if (m_mpvHwnd) {
        if (!isWindowAlive(m_mpvHwnd)) {
            m_mpvHwnd = 0;
            m_adoptTimer->stop();
            raiseAppWindow();
        }
        return;
    }
    if (++m_adoptTries > 80) {   // ~10 s — cover a slow-to-appear mpv window
        m_adoptTimer->stop();
        qWarning("[MpvController] gave up marrying mpv window (not found / ownership refused)");
        return;
    }
    const quintptr hwnd = adoptMpvWindow(m_mainWindow->winId(), m_process->processId());
    if (hwnd) {
        m_mpvHwnd = hwnd;
        m_adoptTimer->setInterval(16);   // ~1 frame — snappy close detection
        qInfo("[MpvController] married mpv window to the app window");
    }
}

void MpvController::raisePlayer() {
    if (m_mpvHwnd)
        raiseMpvWindow(m_mpvHwnd);
}

void MpvController::minimizePlayer() {
    if (m_mpvHwnd)
        minimizeMpvWindow(m_mpvHwnd);
}

void MpvController::raiseAppWindow() {
    if (m_mainWindow)
        forceForegroundWindow(m_mainWindow->winId());
}

void MpvController::stop() {
    if (m_ipc->state() == QLocalSocket::ConnectedState) {
        sendCommand({"quit"});
    } else if (m_process && m_process->state() != QProcess::NotRunning) {
        m_process->terminate();
    }
}

void MpvController::seekTo(int positionMs) {
    sendCommand({"seek", positionMs / 1000.0, "absolute+exact"});
}

void MpvController::sendKey(const QString &key) {
    sendCommand({"keypress", key});
}

void MpvController::showOsdSkipPrompt() {
    sendCommand({"script-message", "skip-overlay-state", "1"});
    sendCommand({"keypress", "DOWN"});
}

void MpvController::clearOsdPrompt() {
    sendCommand({"script-message", "skip-overlay-state", "0"});
}

void MpvController::tryConnectIpc() {
    if (m_ipc->state() == QLocalSocket::ConnectedState ||
        m_ipc->state() == QLocalSocket::ConnectingState)
        return;
    m_ipc->connectToServer(m_pipePath);
}

void MpvController::onIpcReadyRead() {
    while (m_ipc->canReadLine()) {
        const QByteArray line = m_ipc->readLine().trimmed();
        const QJsonObject obj = QJsonDocument::fromJson(line).object();
        if (obj.isEmpty()) continue;
        const QString event = obj["event"].toString();
        // property-change is the hot path (fires many times per second), so test
        // it first; only other events pay for the end-file check below.
        if (event != "property-change") {
            // mpv reports why playback ended: "eof" (played to the end),
            // "quit"/"stop" (user exited), "error", etc. Remember the last one
            // so onProcessFinished can distinguish a natural finish from a quit.
            if (event == "end-file") {
                m_lastEndFileReason = obj["reason"].toString();
            } else if (event == "client-message") {
                const QJsonArray args = obj["args"].toArray();
                if (args.size() > 0) {
                    const QString msg = args[0].toString();
                    if (msg == "skip-segment")
                        emit skipRequested();
                    else if (msg == "episode-nav" && args.size() > 1)
                        emit episodeNavRequested(args[1].toString());
                }
            }
            continue;
        }

        m_lastIpcEventMs = QDateTime::currentMSecsSinceEpoch();

        const QString     name = obj["name"].toString();
        const QJsonValue  data = obj["data"];
        if (data.isNull() || data.isUndefined()) continue; // property unavailable during shutdown
        if (name == "pause") {
            m_paused = data.toBool();
            continue;
        }
        if (name == "window-minimized") {
            // mpv was minimized while it held focus (e.g. a global minimize
            // hotkey). Mirror it onto the married owner window so both drop as
            // one; QML restores both when the single taskbar button is clicked.
            if (data.toBool())
                emit playerMinimizeRequested();
            continue;
        }
        const double val = data.toDouble();
        if (name == "time-pos") {
            m_position = int(val * 1000.0);
            emit positionChanged(m_position);
        } else if (name == "duration") {
            m_duration = int(val * 1000.0);
            emit durationChanged(m_duration);
        } else if (name == "playlist-pos") {
            m_playlistPos = int(val);
            emit playlistPosChanged(m_playlistPos);
        }
    }
}

void MpvController::onProcessFinished() {
    int exitCode = m_process ? m_process->exitCode() : -1;
    if (m_process)
        logMpvOutput(m_process->readAll());
    if (exitCode != 0)
        qWarning("[MpvController] mpv exited with code %d", exitCode);
    m_connectTimer->stop();
    m_watchdogTimer->stop();
    m_adoptTimer->stop();
    m_mpvHwnd = 0;   // player window is gone
    // Take the foreground now, synchronously with the exit — not via the queued
    // playbackEnded → QML handler, which runs an event-loop hop later, long enough
    // to show the menu behind whatever Windows re-activated when mpv closed (e.g.
    // the console the app was launched from). The QML handler still re-asserts it
    // (and covers the restore-from-minimized case).
    if (m_mainWindow)
        raiseAppWindow();
    // Drain any buffered-but-unread IPC data before tearing the socket down.
    // readyRead and QProcess::finished are independent event-loop signals with
    // no ordering guarantee, so mpv's final "end-file" event may still be sitting
    // in the pipe buffer here. Flushing it now ensures m_lastEndFileReason is
    // accurate, so a natural EOF reliably triggers autoplay-next.
    if (m_ipc->state() == QLocalSocket::ConnectedState)
        onIpcReadyRead();
    m_ipc->abort();
    const int pos = m_position;
    const int dur = m_duration;
    m_position = 0;
    m_duration = 0;

    // Classify why mpv exited, once:
    //   exit code 2          -> "failed"  (file could not be played; up to the module as to what to do. As an example: Plex attemps a retry in this case)
    //   end-file reason "eof"-> "eof"     (natural end; up to the module as to what to do. As an example: Plex autoplays next)
    //   anything else        -> "stopped" (user quit/stop, crash, or kill; a safe default)
    QString reason;
    if (exitCode == 2)                    reason = QStringLiteral("failed");
    else if (m_lastEndFileReason == "eof") reason = QStringLiteral("eof");
    else                                   reason = QStringLiteral("stopped");

    emit playbackEnded(pos, dur, reason);
}

void MpvController::logMpvOutput(const QByteArray &raw) {
    if (raw.isEmpty())
        return;
    // mpv's status line is \r-terminated (it overwrites in place on a terminal);
    // normalise to \n so each update is its own line, then log the real messages
    // and skip the status line. A video status line always carries the "A-V:"
    // sync field; audio-only / video-only status starts with "A: " / "V: ".
    QByteArray data = raw;
    data.replace('\r', '\n');
    const QList<QByteArray> lines = data.split('\n');
    for (const QByteArray &line : lines) {
        const QByteArray t = line.trimmed();
        if (t.isEmpty())
            continue;
        if (t.contains("A-V:") || t.startsWith("A: ") || t.startsWith("V: "))
            continue;   // periodic status line — noise
        qWarning("[mpv] %s", t.constData());
    }
}

void MpvController::sendCommand(const QJsonArray &args) {
    if (m_ipc->state() != QLocalSocket::ConnectedState) {
        qWarning("[MpvController] IPC not connected, dropping: %s",
                 QJsonDocument(QJsonObject{{"command", args}}).toJson(QJsonDocument::Compact).constData());
        return;
    }
    QJsonObject cmd;
    cmd["command"] = args;
    m_ipc->write(QJsonDocument(cmd).toJson(QJsonDocument::Compact) + "\n");
}

void MpvController::appendVideoArgs(QStringList &args) const {
    // App-level "mpv_video_args" override replaces the default hwdec flags
    // verbatim. Read here (not cached) so edits to config.json take effect
    // on the next playback without a rebuild — handy for per-device tuning.
    if (m_appCore) {
        const QString override =
            m_appCore->get_setting(QString(), "mpv_video_args").toString().trimmed();
        if (!override.isEmpty()) {
            args << override.split(' ', Qt::SkipEmptyParts);
            return;
        }
    }

    // Windows: auto-safe selects D3D11VA hardware decode (mpv's default is
    // software decode). The video output stays on mpv's default (gpu-next on
    // current builds), which composites through the D3D11 swapchain — the
    // scaler path, so crop/zoom (--panscan) always works.
    args << "--hwdec=auto-safe";
}

void MpvController::appendUpscalerArgs(QStringList &args) const {
    if (!m_appCore) return;
    // "mpv_upscaler_active" is the per-play value the info screen resolves (its
    // per-title override, else the global default). Fall back to the global
    // "mpv_upscaler" for any play path that didn't set it.
    QString sel = m_appCore->get_setting(QString(), "mpv_upscaler_active").toString().toLower();
    if (sel.isEmpty())
        sel = m_appCore->get_setting(QString(), "mpv_upscaler").toString().toLower();
    if (sel.isEmpty() || sel == "off") return;

    // Built-in high-quality scalers — no external files needed.
    if (sel == "hq") {
        args << "--scale=ewa_lanczossharp"
             << "--cscale=ewa_lanczossharp"
             << "--dscale=mitchell"
             << "--sigmoid-upscaling=yes"
             << "--correct-downscaling=yes";
        return;
    }

    // GLSL shader upscalers. Files live in <app>/shaders/upscalers (fetched by
    // scripts/get-upscalers.ps1). --glsl-shaders-append (one per file) sidesteps
    // the platform-specific list separator; a missing file makes mpv log and play
    // without it, so a not-yet-downloaded shader degrades to no upscaling.
    QStringList shaders;
    bool heavy = false;   // large shaders that hang the D3D11 HLSL compiler
    if (sel == "artcnn") {
        shaders << "ArtCNN_C4F32.glsl";
        heavy = true;
    } else if (sel == "fsrcnnx") {
        shaders << "FSRCNNX_x2_16-0-4-1.glsl";
        heavy = true;
    } else if (sel == "anime4k") {
        // Mode A (Fast): clamp + restore + a 2x upscale chain, balanced for
        // mid-range GPUs.
        shaders << "Anime4K_Clamp_Highlights.glsl"
                << "Anime4K_Restore_CNN_M.glsl"
                << "Anime4K_Upscale_CNN_x2_M.glsl"
                << "Anime4K_AutoDownscalePre_x2.glsl"
                << "Anime4K_AutoDownscalePre_x4.glsl"
                << "Anime4K_Upscale_CNN_x2_S.glsl";
    } else {
        return;
    }
    // Big shaders (ArtCNN, FSRCNNX) take ~40 s per pass to translate HLSL->DXBC on
    // the D3D11 backend, which hangs playback startup. Vulkan compiles them in a
    // fraction of the time (libplacebo emits SPIR-V directly, no HLSL step); mpv's
    // shader cache (on by default) then makes repeat plays instant. Small shaders
    // like Anime4K compile fast on D3D11, so they keep the default backend.
    if (heavy)
        args << "--gpu-api=vulkan";

    const QString dir = m_appRoot + "/shaders/upscalers/";
    for (const QString &s : shaders)
        args << QString("--glsl-shaders-append=%1").arg(dir + s);
}

bool MpvController::autoCropEnabled() const {
    // Default OFF: only an explicit "On" opts in. Stored by Settings as a string
    // ("On"/"Off") via the list_single row, so compare on the string form.
    if (!m_appCore)
        return false;
    const QVariant v = m_appCore->get_setting(QString(), "auto_crop");
    return v.toString().compare(QStringLiteral("On"), Qt::CaseInsensitive) == 0;
}
