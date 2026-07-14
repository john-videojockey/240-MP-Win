#pragma once
#include <QObject>
#include <QProcess>
#include <QLocalSocket>
#include <QTimer>
#include <QJsonArray>
#include <QStringList>

class AppCore;
class QQuickWindow;

class MpvController : public QObject {
    Q_OBJECT
    Q_PROPERTY(int position    READ position    NOTIFY positionChanged)
    Q_PROPERTY(int duration    READ duration    NOTIFY durationChanged)
    Q_PROPERTY(int playlistPos READ playlistPos NOTIFY playlistPosChanged)

public:
    explicit MpvController(const QString &appRoot, AppCore *appCore = nullptr,
                           QObject *parent = nullptr);
    ~MpvController() override;

    int position()    const { return m_position;    }
    int duration()    const { return m_duration;    }
    int playlistPos() const { return m_playlistPos; }

    Q_INVOKABLE void loadAndPlay(const QString &url, float startSeconds,
                                  int audioTrack, int subTrack,
                                  const QStringList &subFiles = {},
                                  const QStringList &subLangs = {},
                                  bool loop = false,
                                  int playlistStart = -1,
                                  float transcodeOffsetSec = 0.0f,
                                  const QString &plexToken = {},
                                  bool muteAudio = false,
                                  const QString &oscMode = {},
                                  bool shuffle = false,
                                  const QStringList &subTitles = {},
                                  float imageDurationSec = 0.0f,
                                  bool imageContent = false,
                                  const QStringList &extraArgs = {},
                                  const QString &jellyfinToken = {});
    Q_INVOKABLE void stop();
    Q_INVOKABLE void seekTo(int positionMs);
    Q_INVOKABLE void sendKey(const QString &key);
    Q_INVOKABLE void showOsdSkipPrompt();
    Q_INVOKABLE void clearOsdPrompt();

    // The app's main (menu) window. Used to marry mpv's fullscreen window to it
    // so the two behave as a single window (see win_utils adoptMpvWindow).
    void setMainWindow(QQuickWindow *w) { m_mainWindow = w; }

    // Restore the player's window on top with focus — called from QML when the
    // owner (menu) window is un-minimized, so the video returns rather than the
    // menu sitting in front of it.
    Q_INVOKABLE void raisePlayer();

    // Minimize the player's window — called from QML when the owner (menu) window
    // is minimized, so the pair drops together even if the owned-window marriage
    // didn't take (belt-and-suspenders against the two windows "splitting").
    Q_INVOKABLE void minimizePlayer();

    // Kept for the shared Settings view: the smoothness-vs-crop trade-off only
    // exists on the Raspberry Pi 3 decode path upstream. On Windows the D3D11
    // scaler path always supports crop, so the toggle is never shown.
    Q_INVOKABLE bool hasSmoothPlaybackTradeoff() const { return false; }

signals:
    void positionChanged(int ms);
    void durationChanged(int ms);
    void playlistPosChanged(int pos);
    // Emitted exactly once when mpv exits, with the reason it ended:
    //   "eof"     — file played to its natural end. (What a module does with this
    //               is its own concern.  as an example: Plex may autoplay the next episode)
    //   "stopped" — user quit/stopped before the end (also the safe default for a
    //               crash/kill with no end-file event).
    //   "failed"  — mpv exited with an error (code 2 — file could not be played;
    //               Up to the module as to when/how to use; for example Plex retries when transcoding).
    // A single signal (rather than one per reason) is deliberate: a Player view
    // connects one handler and branches on `reason`, so it can never silently drop
    // a case the way an unhandled per-reason signal would.
    void playbackEnded(int finalPositionMs, int finalDurationMs, const QString &reason);

    void skipRequested();
    // The OSC's |< / >| buttons when no mpv playlist is loaded: the app decides
    // what "next"/"prev" means (e.g. Plex plays the next episode in the season).
    void episodeNavRequested(const QString &direction);

    // mpv's window was minimized (e.g. by a global "minimize" hotkey while it
    // held focus). QML responds by minimizing the owner window too, so the
    // married pair drops as one. Restore happens via raisePlayer().
    void playerMinimizeRequested();

private slots:
    void onProcessFinished();
    void tryConnectIpc();
    void onIpcReadyRead();
    // Polls for mpv's window after launch (it appears asynchronously) and, once
    // found, marries it to the main window. Self-stops on success or timeout.
    void tryAdoptMpvWindow();

private:
    void sendCommand(const QJsonArray &args);
    // Mirrors mpv's captured stdout/stderr into the app log, line by line, while
    // dropping its high-frequency terminal status line so it can't flood the log
    // or an attached console.
    static void logMpvOutput(const QByteArray &raw);
    // Appends the --hwdec flags (honouring the app-level "mpv_video_args"
    // override) to a forming mpv argument list.
    void appendVideoArgs(QStringList &args) const;
    // Appends real-time upscaler args for the app-level "mpv_upscaler" setting
    // (GLSL shader chains from shaders/upscalers, or mpv's built-in HQ scalers).
    void appendUpscalerArgs(QStringList &args) const;
    // App-level "auto_crop" setting (default OFF). When ON, playback starts with
    // panscan=1 so video fills a CRT/4:3 screen by default (still toggleable live).
    bool autoCropEnabled() const;

    AppCore      *m_appCore        = nullptr;
    QProcess     *m_process        = nullptr;
    QLocalSocket *m_ipc            = nullptr;
    QTimer       *m_connectTimer   = nullptr;
    QTimer       *m_watchdogTimer  = nullptr;
    QTimer       *m_adoptTimer     = nullptr;   // polls for mpv's window to marry it
    QQuickWindow *m_mainWindow     = nullptr;   // owner window for the marriage
    quintptr      m_mpvHwnd        = 0;         // adopted mpv window (HWND), 0 if none
    int           m_adoptTries     = 0;
    qint64        m_lastIpcEventMs = 0;
    bool          m_paused         = false;  // mirrors mpv's pause property (watchdog exemption)
    QString       m_appRoot;
    QString       m_pipePath;           // \\.\pipe\... — mpv's --input-ipc-server on Windows
    QString       m_inputConfPath;
    QString       m_logFilePath;
    QString       m_subInfoPath;       // JSON map: external sub URL -> friendly name (for the OSC)
    QString       m_lastEndFileReason;  // mpv end-file "reason" for the current session
    int           m_position     = 0;
    int           m_duration     = 0;
    int           m_playlistPos  = -1;
    bool          m_hasMpvOscScript     = false;
    bool          m_hasAmbientOscScript = false;
    bool          m_hasMediaKeysScript  = false;
};
