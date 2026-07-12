#pragma once
#include <QObject>
#include <QString>
#include <QFile>
#include <QCryptographicHash>
#include <QNetworkAccessManager>

class QNetworkReply;

// In-app self-update: checks GitHub Releases for a newer version, downloads the
// Windows zip into DATA_ROOT/updates, and applies it.
//   Choosing Install spawns a detached PowerShell helper that waits for the app
//   to quit, extracts the zip next to the install folder, swaps the folders,
//   and relaunches. This works without elevation when the app lives in a
//   user-writable location (the install.ps1 default is
//   %LOCALAPPDATA%\Programs\240-MP). For non-writable installs (e.g. Program
//   Files) the fallback opens the downloaded zip in Explorer and quits so the
//   user can update by hand.
class UpdateManager : public QObject {
    Q_OBJECT
    // idle | checking | upToDate | updateAvailable | downloading | readyToApply | error
    Q_PROPERTY(QString state READ state NOTIFY stateChanged)
    Q_PROPERTY(QString currentVersion READ currentVersion CONSTANT)
    Q_PROPERTY(QString latestVersion READ latestVersion NOTIFY infoChanged)
    Q_PROPERTY(QString releaseNotes READ releaseNotes NOTIFY infoChanged)
    Q_PROPERTY(qreal downloadProgress READ downloadProgress NOTIFY progressChanged)
    Q_PROPERTY(QString errorMessage READ errorMessage NOTIFY stateChanged)
    Q_PROPERTY(bool canApply READ canApply CONSTANT)
    Q_PROPERTY(QString applyHint READ applyHint CONSTANT)
public:
    explicit UpdateManager(const QString &appRoot, const QString &dataRoot,
                           QObject *parent = nullptr);

    QString state() const { return m_state; }
    QString currentVersion() const;
    QString latestVersion() const { return m_latestVersion; }
    QString releaseNotes() const { return m_releaseNotes; }
    qreal downloadProgress() const { return m_downloadProgress; }
    QString errorMessage() const { return m_errorMessage; }
    bool canApply() const { return m_canApply; }
    QString applyHint() const { return m_applyHint; }

    Q_INVOKABLE void checkForUpdates();
    Q_INVOKABLE void download();
    Q_INVOKABLE void cancelDownload();
    Q_INVOKABLE void applyAndRestart();
    Q_INVOKABLE void discardStagedUpdate();

signals:
    void stateChanged();
    void infoChanged();
    void progressChanged();

private:
    void setState(const QString &state, const QString &error = QString());
    void evaluateApplyCapability();
    void reconcileStagingDir();
    void handleReleaseInfo(const QByteArray &json);
    void fetchChecksums(const QString &url);
    void finishDownload();
    void applyWindows();
    QString updatesDir() const;
    QString stagedJsonPath() const;
    void writeStagedMarkers(const QString &sha256Hex);
    void clearStagingFiles();

    QNetworkAccessManager m_nam;
    QString m_appRoot;
    QString m_dataRoot;

    QString m_state = "idle";
    QString m_latestVersion;
    QString m_releaseNotes;
    QString m_errorMessage;
    qreal m_downloadProgress = 0.0;
    bool m_canApply = false;
    QString m_applyHint;

    // Latest-release asset picked for this platform
    QString m_assetName;
    QString m_assetUrl;
    qint64 m_assetSize = 0;
    QString m_expectedSha256;   // from the release's SHA256SUMS asset, if present

    QNetworkReply *m_downloadReply = nullptr;
    QFile m_downloadFile;
    QCryptographicHash m_hash{QCryptographicHash::Sha256};
};
