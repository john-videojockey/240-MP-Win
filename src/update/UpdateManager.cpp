#include "UpdateManager.h"

#include <QCoreApplication>
#include <QDir>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QProcess>
#include <QStorageInfo>
#include <QSysInfo>
#include <QTimer>

namespace {

const QString kDefaultFeedUrl =
    QStringLiteral("https://api.github.com/repos/john-videojockey/240-MP-Win/releases/latest");

const QString kAssetSuffix = QStringLiteral("-windows-x64.zip");

QString feedUrl() {
    const QString env = qEnvironmentVariable("MP240_UPDATE_FEED_URL");
    return env.isEmpty() ? kDefaultFeedUrl : env;
}

QNetworkRequest githubRequest(const QUrl &url) {
    QNetworkRequest req(url);
    // GitHub's API rejects requests without a User-Agent.
    req.setRawHeader("User-Agent",
                     QStringLiteral("240-MP/%1").arg(QCoreApplication::applicationVersion()).toUtf8());
    req.setRawHeader("Accept", "application/vnd.github+json");
    req.setRawHeader("X-GitHub-Api-Version", "2022-11-28");
    return req;
}

} // namespace

UpdateManager::UpdateManager(const QString &appRoot, const QString &dataRoot, QObject *parent)
    : QObject(parent), m_appRoot(appRoot), m_dataRoot(dataRoot) {
    evaluateApplyCapability();
    reconcileStagingDir();
}

QString UpdateManager::currentVersion() const {
    return QCoreApplication::applicationVersion();
}

QString UpdateManager::updatesDir() const { return m_dataRoot + QStringLiteral("/updates"); }
QString UpdateManager::stagedJsonPath() const { return updatesDir() + QStringLiteral("/staged.json"); }

void UpdateManager::setState(const QString &state, const QString &error) {
    m_state = state;
    m_errorMessage = error;
    emit stateChanged();
}

void UpdateManager::evaluateApplyCapability() {
    // The helper swaps the whole install folder (the appRoot: 240mp.exe + QML +
    // assets), so both the folder and its parent must be writable without
    // elevation. True for the install.ps1 default (%LOCALAPPDATA%\Programs\240-MP)
    // and any other per-user location; false under Program Files.
    const QFileInfo installDir(m_appRoot);
    const QFileInfo parentDir(installDir.absolutePath());
    if (installDir.isWritable() && parentDir.isWritable()) {
        m_canApply = true;
    } else {
        m_canApply = false;
        m_applyHint = QStringLiteral("This copy of 240-MP is not in a user-writable folder — "
                                     "240-MP will quit and show the downloaded zip for manual install.");
    }
}

// Startup pass over DATA_ROOT/updates: drop half-finished downloads, and restore
// readyToApply if a verified staged update is still pending from a previous run.
void UpdateManager::reconcileStagingDir() {
    QDir dir(updatesDir());
    dir.mkpath(QStringLiteral("."));
    const QStringList parts = dir.entryList({QStringLiteral("*.part")}, QDir::Files);
    for (const QString &p : parts)
        dir.remove(p);

    QFile marker(stagedJsonPath());
    if (!marker.open(QIODevice::ReadOnly)) {
        clearStagingFiles();   // sweep payloads orphaned by a discarded stage
        return;
    }
    const QJsonObject staged = QJsonDocument::fromJson(marker.readAll()).object();
    marker.close();

    const QString version = staged.value(QStringLiteral("version")).toString();
    const QString asset   = staged.value(QStringLiteral("asset")).toString();
    const qint64 size     = staged.value(QStringLiteral("size")).toVariant().toLongLong();
    const QFileInfo payload(dir.filePath(asset));

    // Version matching the running app means the update was already applied (or
    // installed another way); a size mismatch means a corrupt stage.
    if (version.isEmpty() || asset.isEmpty() || version == currentVersion()
        || !payload.exists() || payload.size() != size) {
        clearStagingFiles();
        return;
    }

    m_latestVersion = version;
    m_assetName = asset;
    emit infoChanged();
    setState(QStringLiteral("readyToApply"));
}

void UpdateManager::checkForUpdates() {
    if (m_state == QStringLiteral("checking") || m_state == QStringLiteral("downloading"))
        return;
    setState(QStringLiteral("checking"));

    QNetworkReply *reply = m_nam.get(githubRequest(QUrl(feedUrl())));
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        const int status =
            reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (status == 403 || status == 429) {
            setState(QStringLiteral("error"),
                     QStringLiteral("GitHub rate limit reached — try again later."));
            return;
        }
        if (status == 404) {
            setState(QStringLiteral("error"), QStringLiteral("No releases found."));
            return;
        }
        if (reply->error() != QNetworkReply::NoError) {
            setState(QStringLiteral("error"),
                     QStringLiteral("Update check failed: %1").arg(reply->errorString()));
            return;
        }
        handleReleaseInfo(reply->readAll());
    });
}

void UpdateManager::handleReleaseInfo(const QByteArray &json) {
    const QJsonObject release = QJsonDocument::fromJson(json).object();
    const QString tag = release.value(QStringLiteral("tag_name")).toString();
    if (tag.isEmpty()) {
        setState(QStringLiteral("error"), QStringLiteral("Unexpected response from GitHub."));
        return;
    }

    m_latestVersion = tag;
    m_releaseNotes = release.value(QStringLiteral("body")).toString();
    emit infoChanged();

    if (tag == currentVersion()) {
        setState(QStringLiteral("upToDate"));
        return;
    }

    // Release zips are built for x64; a different-architecture Windows (arm64)
    // could run this x64 binary under emulation, but a self-update would keep
    // installing x64 anyway, so just gate on what the release actually ships.
    if (QSysInfo::currentCpuArchitecture() != QStringLiteral("x86_64")) {
        setState(QStringLiteral("error"),
                 QStringLiteral("No update package for this architecture (%1).")
                     .arg(QSysInfo::currentCpuArchitecture()));
        return;
    }

    m_assetName.clear();
    m_assetUrl.clear();
    m_assetSize = 0;
    m_expectedSha256.clear();
    QString checksumsUrl;
    const QJsonArray assets = release.value(QStringLiteral("assets")).toArray();
    for (const QJsonValue &v : assets) {
        const QJsonObject asset = v.toObject();
        const QString name = asset.value(QStringLiteral("name")).toString();
        if (name.endsWith(kAssetSuffix)) {
            m_assetName = name;
            m_assetUrl = asset.value(QStringLiteral("browser_download_url")).toString();
            m_assetSize = asset.value(QStringLiteral("size")).toVariant().toLongLong();
        } else if (name == QStringLiteral("SHA256SUMS")) {
            checksumsUrl = asset.value(QStringLiteral("browser_download_url")).toString();
        }
    }
    if (m_assetUrl.isEmpty()) {
        setState(QStringLiteral("error"),
                 QStringLiteral("Release %1 has no package for this platform.").arg(tag));
        return;
    }

    if (!checksumsUrl.isEmpty())
        fetchChecksums(checksumsUrl);   // sets updateAvailable when done
    else
        setState(QStringLiteral("updateAvailable"));
}

// Releases published before the checksums step (or a fetch hiccup) degrade to
// size-only verification rather than blocking the update.
void UpdateManager::fetchChecksums(const QString &url) {
    QNetworkReply *reply = m_nam.get(githubRequest(QUrl(url)));
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        if (reply->error() == QNetworkReply::NoError) {
            const QString sums = QString::fromUtf8(reply->readAll());
            for (const QString &line : sums.split(QLatin1Char('\n'))) {
                if (line.endsWith(m_assetName)) {
                    m_expectedSha256 = line.section(QLatin1Char(' '), 0, 0).trimmed();
                    break;
                }
            }
        }
        setState(QStringLiteral("updateAvailable"));
    });
}

void UpdateManager::download() {
    if (m_state != QStringLiteral("updateAvailable"))
        return;
    if (currentVersion() == QStringLiteral("dev")) {
        setState(QStringLiteral("error"),
                 QStringLiteral("Dev build — self-update is disabled."));
        return;
    }
    // 3x headroom: zip + extracted .new tree share the same filesystem.
    if (m_assetSize > 0
        && QStorageInfo(updatesDir()).bytesAvailable() < 3 * m_assetSize) {
        setState(QStringLiteral("error"),
                 QStringLiteral("Not enough free disk space to download the update."));
        return;
    }

    m_downloadFile.setFileName(updatesDir() + QStringLiteral("/") + m_assetName
                               + QStringLiteral(".part"));
    if (!m_downloadFile.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        setState(QStringLiteral("error"), QStringLiteral("Could not write to the updates folder."));
        return;
    }
    m_hash.reset();
    m_downloadProgress = 0.0;
    emit progressChanged();
    setState(QStringLiteral("downloading"));

    m_downloadReply = m_nam.get(githubRequest(QUrl(m_assetUrl)));
    connect(m_downloadReply, &QNetworkReply::readyRead, this, [this]() {
        const QByteArray chunk = m_downloadReply->readAll();
        m_downloadFile.write(chunk);
        m_hash.addData(chunk);
    });
    connect(m_downloadReply, &QNetworkReply::downloadProgress, this,
            [this](qint64 received, qint64 total) {
        m_downloadProgress = total > 0 ? qreal(received) / qreal(total) : 0.0;
        emit progressChanged();
    });
    connect(m_downloadReply, &QNetworkReply::finished, this, &UpdateManager::finishDownload);
}

void UpdateManager::cancelDownload() {
    if (m_downloadReply)
        m_downloadReply->abort();   // finishDownload cleans up and restores state
}

void UpdateManager::finishDownload() {
    QNetworkReply *reply = m_downloadReply;
    m_downloadReply = nullptr;
    reply->deleteLater();
    m_downloadFile.close();

    auto fail = [this](const QString &msg) {
        m_downloadFile.remove();
        // A user cancel is not an error — return to the offer.
        if (msg.isEmpty())
            setState(QStringLiteral("updateAvailable"));
        else
            setState(QStringLiteral("error"), msg);
    };

    if (reply->error() == QNetworkReply::OperationCanceledError)
        return fail(QString());
    if (reply->error() != QNetworkReply::NoError)
        return fail(QStringLiteral("Download failed: %1").arg(reply->errorString()));
    if (m_assetSize > 0 && m_downloadFile.size() != m_assetSize)
        return fail(QStringLiteral("Download incomplete — please try again."));

    const QString sha256 = QString::fromLatin1(m_hash.result().toHex());
    if (!m_expectedSha256.isEmpty() && sha256 != m_expectedSha256)
        return fail(QStringLiteral("Downloaded file failed verification — please try again."));

    const QString finalPath = updatesDir() + QStringLiteral("/") + m_assetName;
    QFile::remove(finalPath);
    if (!m_downloadFile.rename(finalPath))
        return fail(QStringLiteral("Could not save the downloaded update."));

    writeStagedMarkers(sha256);
    setState(QStringLiteral("readyToApply"));
}

// Download-time marker only. A downloaded update is inert until the user picks
// Install: backing out and relaunching runs the old version, and the page just
// re-offers Install (restored by reconcileStagingDir).
void UpdateManager::writeStagedMarkers(const QString &sha256Hex) {
    QJsonObject staged{
        {QStringLiteral("version"), m_latestVersion},
        {QStringLiteral("asset"), m_assetName},
        {QStringLiteral("sha256"), sha256Hex},
        {QStringLiteral("size"), QString::number(QFileInfo(updatesDir() + QStringLiteral("/") + m_assetName).size())},
    };
    QFile json(stagedJsonPath());
    if (json.open(QIODevice::WriteOnly | QIODevice::Truncate))
        json.write(QJsonDocument(staged).toJson());
}

void UpdateManager::clearStagingFiles() {
    QDir dir(updatesDir());
    if (!m_assetName.isEmpty())
        dir.remove(m_assetName);
    dir.remove(QStringLiteral("staged.json"));
    // Plus whatever payload an older run left behind
    const QStringList leftovers = dir.entryList({QStringLiteral("*.zip")}, QDir::Files);
    for (const QString &f : leftovers)
        dir.remove(f);
}

void UpdateManager::discardStagedUpdate() {
    if (m_state != QStringLiteral("readyToApply"))
        return;
    clearStagingFiles();
    setState(m_assetUrl.isEmpty() ? QStringLiteral("idle") : QStringLiteral("updateAvailable"));
}

void UpdateManager::applyAndRestart() {
    if (m_state != QStringLiteral("readyToApply"))
        return;
    applyWindows();
}

void UpdateManager::applyWindows() {
    const QString zipPath = QDir::toNativeSeparators(updatesDir() + QStringLiteral("/") + m_assetName);

    if (!m_canApply) {
        // Manual fallback: reveal the zip in Explorer and quit — the fullscreen
        // window otherwise sits over Explorer looking frozen. The user extracts
        // it over the install by hand; the stage is cleaned up by startup
        // reconciliation once the running version matches.
        QProcess::startDetached(QStringLiteral("explorer.exe"),
                                {QStringLiteral("/select,") + zipPath});
        QTimer::singleShot(200, qApp, &QCoreApplication::quit);
        return;
    }

    // apply-windows.ps1 <pid> <zip> <installDir> — spawned detached before the
    // app quits. Waits for the process to exit, extracts the zip beside the
    // install folder, swaps the folders, and relaunches. On any failure it puts
    // the old folder back and opens the zip in Explorer for a manual install.
    static const char kHelper[] = R"HELPER(param([int]$AppPid, [string]$Zip, [string]$InstallDir)
$ErrorActionPreference = 'Stop'
# Never sit inside the folder we're about to rename: a process whose current
# directory is $InstallDir holds a handle that blocks the move — that's what
# stranded the update in an .new folder. Move to a neutral directory first.
Set-Location -LiteralPath $env:TEMP
$log = Join-Path (Split-Path $Zip) 'apply.log'
Start-Transcript -Path $log -Append | Out-Null
try {
    Write-Output "=== $(Get-Date) apply $Zip -> $InstallDir"
    try { Wait-Process -Id $AppPid -Timeout 30 -ErrorAction Stop } catch {}
    Start-Sleep -Milliseconds 500

    $new = "$InstallDir.new"; $old = "$InstallDir.old"
    Remove-Item $new, $old -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive -LiteralPath $Zip -DestinationPath $new -Force

    # Zips may wrap everything in a single top-level folder — hoist it.
    $entries = Get-ChildItem $new
    if ($entries.Count -eq 1 -and $entries[0].PSIsContainer) {
        $inner = $entries[0].FullName
        Get-ChildItem $inner -Force | Move-Item -Destination $new
        Remove-Item $inner -Recurse -Force
    }
    if (-not (Test-Path (Join-Path $new '240mp.exe'))) { throw '240mp.exe missing from update package' }

    # Retry the swap briefly — antivirus or a lingering handle can still hold the
    # folder for a moment right after the app exits.
    $moved = $false
    for ($i = 0; $i -lt 20 -and -not $moved; $i++) {
        try { Move-Item $InstallDir $old -ErrorAction Stop; $moved = $true }
        catch { Start-Sleep -Milliseconds 500 }
    }
    if (-not $moved) { throw "could not move $InstallDir (still in use after 10s)" }
    try {
        Move-Item $new $InstallDir
    } catch {
        Move-Item $old $InstallDir   # roll back
        throw
    }
    Remove-Item $old -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $Zip -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path (Split-Path $Zip) 'staged.json') -Force -ErrorAction SilentlyContinue
    Write-Output 'swap ok, relaunching'
    Start-Process (Join-Path $InstallDir '240mp.exe')
} catch {
    Write-Output "swap failed: $_"
    Start-Process explorer.exe "/select,$Zip"
} finally {
    Stop-Transcript | Out-Null
}
)HELPER";

    const QString scriptPath = updatesDir() + QStringLiteral("/apply-windows.ps1");
    QFile script(scriptPath);
    if (!script.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        setState(QStringLiteral("error"), QStringLiteral("Could not write the update helper."));
        return;
    }
    script.write(kHelper);
    script.close();

    // powershell.exe (Windows PowerShell 5.1) ships with every Windows — no
    // dependency on pwsh being installed.
    QProcess::startDetached(QStringLiteral("powershell.exe"),
                            {QStringLiteral("-NoProfile"),
                             QStringLiteral("-ExecutionPolicy"), QStringLiteral("Bypass"),
                             QStringLiteral("-WindowStyle"), QStringLiteral("Hidden"),
                             QStringLiteral("-File"), QDir::toNativeSeparators(scriptPath),
                             QString::number(QCoreApplication::applicationPid()),
                             zipPath,
                             QDir::toNativeSeparators(m_appRoot)},
                            // Start the helper OUTSIDE the install dir — inheriting it
                            // as the working directory would relock the folder.
                            QDir::tempPath());
    // Give the detached helper a beat to start before the app exits.
    QTimer::singleShot(200, qApp, &QCoreApplication::quit);
}
