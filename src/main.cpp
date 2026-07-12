#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QUrl>
#include <QDir>
#include <QStandardPaths>
#include <QCursor>
#include <QDebug>
#include <QQuickWindow>
#include <locale.h>

#include "AppCore.h"
#include "modules/local_files/LocalFilesBackend.h"
#include "modules/plex/PlexBackend.h"
#include "modules/jellyfin/JellyfinBackend.h"
#include "modules/ambient_mode/AmbientModeBackend.h"
#include "modules/youtube/YouTubeBackend.h"
#include "player/MpvController.h"
#include "input/InputManager.h"
#include "input/IdleTracker.h"
#include "update/UpdateManager.h"
#include "win_utils.h"

// APP_ROOT env wins; otherwise walk up from the executable looking for
// Main.qml. That single rule covers every layout this app runs from:
//   installed:      <dir>/240mp.exe next to Main.qml           (0 levels up)
//   Ninja build:    build/240mp.exe, repo root one up          (1 level up)
//   VS generator:   build/Release/240mp.exe, repo root two up  (2 levels up)
static QString resolveAppRoot() {
    QString envRoot = qEnvironmentVariable("APP_ROOT");
    if (!envRoot.isEmpty())
        return QDir(envRoot).canonicalPath();

    QDir dir(QCoreApplication::applicationDirPath());
    for (int i = 0; i < 4; ++i) {
        if (dir.exists(QStringLiteral("Main.qml")))
            return dir.canonicalPath();
        if (!dir.cdUp())
            break;
    }
    return QDir(QCoreApplication::applicationDirPath()).canonicalPath();
}

static QString resolveDataRoot() {
    QString envRoot = qEnvironmentVariable("DATA_ROOT");
    if (!envRoot.isEmpty()) {
        QDir().mkpath(envRoot);
        return QDir(envRoot).canonicalPath();
    }

    // %APPDATA%/240-MP — roaming, survives reinstalls of the app folder.
    QString path = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    QDir().mkpath(path);
    return path;
}

int main(int argc, char *argv[]) {
    QGuiApplication app(argc, argv);
    app.setApplicationName("240-MP");
    app.setApplicationVersion(QStringLiteral(APP_VERSION));

    // Hide cursor — 240-MP is keyboard/gamepad-only so the cursor serves no purpose.
    QGuiApplication::setOverrideCursor(Qt::BlankCursor);

    setlocale(LC_NUMERIC, "C");

    const QString appRoot  = resolveAppRoot();
    const QString dataRoot = resolveDataRoot();

    installWindowsLogging(dataRoot);   // before the first qDebug so nothing is lost
    keepDisplayAwake();
    prependToolDirsToPath(appRoot);    // mpv/yt-dlp discovery for every backend

    qDebug("[main] appRoot  = %s", qPrintable(appRoot));
    qDebug("[main] dataRoot = %s", qPrintable(dataRoot));

    QQmlApplicationEngine engine;

    AppCore             appCore(appRoot, dataRoot);
    LocalFilesBackend   localFiles(appRoot, dataRoot);
    PlexBackend         plexBackend(appRoot, dataRoot);
    JellyfinBackend     jellyfinBackend(appRoot, dataRoot);
    AmbientModeBackend  ambientMode(dataRoot);
    YouTubeBackend      youtubeBackend(appRoot, dataRoot);
    MpvController       mpvController(appRoot, &appCore);
    InputManager        inputManager(dataRoot);
    IdleTracker         idleTracker(60);   // disabled until Main.qml applies the saved setting
    UpdateManager       updateManager(appRoot, dataRoot);

    // When the Qt window is inactive (fullscreen mpv holds OS focus during
    // playback), gamepad actions bypass QML and drive mpv directly over IPC.
    QObject::connect(&inputManager, &InputManager::mpvKeyRequested,
                     &mpvController, &MpvController::sendKey);

    // App-level "controller_input" setting (default ON): apply the saved value
    // now and track live changes from the Settings view. Lets users park a
    // misbehaving pad without unplugging it.
    auto applyControllerInputSetting = [&appCore, &inputManager]() {
        const QString v = appCore.get_setting(QString(), "controller_input").toString();
        inputManager.setControllerInputEnabled(
            v.compare(QLatin1String("Off"), Qt::CaseInsensitive) != 0);
    };
    applyControllerInputSetting();
    QObject::connect(&appCore, &AppCore::appSettingChanged, &inputManager,
                     [applyControllerInputSetting](const QString &key, const QString &) {
        if (key == QLatin1String("controller_input"))
            applyControllerInputSetting();
    });

    // Each module backend is wired in one call: stored for action routing, exposed to QML
    // under its context-property name, and its optional signals/slots connected by
    // introspection. The module ID lives in exactly one place per module.
    QQmlContext *ctx = engine.rootContext();
    appCore.registerModule("com.240mp.local_files",  "localFilesBackend",  &localFiles,  ctx);
    appCore.registerModule("com.240mp.plex",         "plexBackend",        &plexBackend, ctx);
    appCore.registerModule("com.240mp.jellyfin",     "jellyfinBackend",    &jellyfinBackend, ctx);
    appCore.registerModule("com.240mp.ambient_mode", "ambientModeBackend", &ambientMode, ctx);
    appCore.registerModule("com.240mp.youtube",      "youtubeBackend",     &youtubeBackend, ctx);

    ctx->setContextProperty("idleTracker",   &idleTracker);
    ctx->setContextProperty("appCore",       &appCore);
    ctx->setContextProperty("mpvController", &mpvController);
    ctx->setContextProperty("inputManager",  &inputManager);
    ctx->setContextProperty("updateManager", &updateManager);

    engine.addImportPath(appRoot + "/views");

    engine.load(QUrl::fromLocalFile(appRoot + "/Main.qml"));
    if (engine.rootObjects().isEmpty()) {
        qCritical("[main] QML engine failed to load Main.qml");
        return 1;
    }

    // Gamepad key events are posted straight to the root window so they reach
    // the QML focus item even when another window (mpv) holds OS focus.
    inputManager.setTargetWindow(qobject_cast<QQuickWindow *>(engine.rootObjects().first()));

    return app.exec();
}
