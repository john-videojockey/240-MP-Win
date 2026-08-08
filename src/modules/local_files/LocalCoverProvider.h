#pragma once

#include <QQuickImageProvider>
#include <QImage>
#include <QImageReader>
#include <QUrl>
#include <QDir>
#include <QFileInfo>
#include <QFile>
#include <QCryptographicHash>
#include <QDateTime>
#include <QMutex>
#include <atomic>

// Serves local-media cover art through a persistent, downscaled disk cache so
// browsing — especially from an external or network source — doesn't re-read the
// full-size artwork every time it scrolls into view.
//
// QML asks for `image://lfcover/<url-encoded file:// path>`. The first request reads
// and downscales the source on a background thread (ForceAsynchronousImageLoading,
// so the UI never blocks) and writes a small JPEG to <dataRoot>/covers; every later
// request — this session or a future one — reads that small local file instead.
// Keyed by the source's path + size + mtime, so a replaced cover restales itself.
//
// Caching can be turned off (setEnabled) and bounded (setLimitBytes) live from the
// Local Files settings; when the cache passes its limit the oldest files are evicted
// first. All state the render threads read is atomic; eviction is mutex-guarded.
class LocalCoverProvider : public QQuickImageProvider {
public:
    explicit LocalCoverProvider(const QString &dataRoot)
        : QQuickImageProvider(QQuickImageProvider::Image,
                              QQuickImageProvider::ForceAsynchronousImageLoading),
          m_cacheDir(dataRoot + QStringLiteral("/covers")) {
        QDir().mkpath(m_cacheDir);
    }

    void setEnabled(bool on)         { m_enabled.store(on); }
    void setLimitBytes(qint64 bytes) { m_limitBytes.store(bytes); }

    QImage requestImage(const QString &id, QSize *size, const QSize &requestedSize) override {
        // Qt may hand the id still percent-encoded (and/or keep %2F escaped), so
        // fully decode it before use. QML passes encodeURIComponent(<file:// url>).
        QString s = QUrl::fromPercentEncoding(id.toUtf8());
        while (s.startsWith(QLatin1Char('/'))) s.remove(0, 1);   // defensive: no leading slash
        const QString path = s.startsWith(QStringLiteral("file:")) ? QUrl(s).toLocalFile() : s;
        const QFileInfo fi(path);
        if (!fi.exists()) {
            static bool warned = false;
            if (!warned) { warned = true;
                qWarning("[lfcover] cover not found — id='%s' -> path='%s'",
                         qPrintable(id), qPrintable(path)); }
            return QImage();
        }

        const bool useCache = m_enabled.load();
        QString cachePath;
        if (useCache) {
            const QString key = fi.absoluteFilePath() + QLatin1Char('|')
                              + QString::number(fi.size()) + QLatin1Char('|')
                              + QString::number(fi.lastModified().toSecsSinceEpoch());
            const QString hash = QString::fromLatin1(
                QCryptographicHash::hash(key.toUtf8(), QCryptographicHash::Md5).toHex());
            cachePath = m_cacheDir + QLatin1Char('/') + hash + QStringLiteral(".jpg");
            const QFileInfo cfi(cachePath);
            if (cfi.exists()) {
                QImage cached;
                // Open read-write so a cache hit can also bump the file's mtime:
                // eviction is oldest-mtime-first, and touching on use makes that the
                // least-recently-*used* cover, not just the oldest-written one. The
                // touch is throttled (only when the mtime has gone stale) to avoid
                // rewriting metadata on every scroll.
                QFile f(cachePath);
                if (f.open(QIODevice::ReadWrite) && cached.load(&f, nullptr)) {
                    if (cfi.lastModified().secsTo(QDateTime::currentDateTime()) > 60)
                        f.setFileTime(QDateTime::currentDateTime(), QFileDevice::FileModificationTime);
                    return finish(cached, requestedSize, size);
                }
            }
        }

        // Read the source (the slow external read, on this async thread), downscale,
        // and — when caching is on — write a small JPEG for next time. A corrupt
        // partial write just fails to load later and is regenerated, so no locking.
        QImageReader reader(path);
        reader.setAutoTransform(true);
        QImage img = reader.read();
        if (img.isNull())
            return QImage();
        if (img.width() > kCap || img.height() > kCap)
            img = img.scaled(kCap, kCap, Qt::KeepAspectRatio, Qt::SmoothTransformation);
        if (useCache && !cachePath.isEmpty() && img.save(cachePath, "JPG", 85)) {
            if ((m_writes.fetch_add(1) % kEvictEvery) == 0)
                enforceLimit();
        }
        return finish(img, requestedSize, size);
    }

private:
    static constexpr int kCap        = 640;   // cached long-edge cap (px) — crisp for posters
    static constexpr int kEvictEvery = 16;    // run eviction every Nth cache write

    static QImage finish(QImage img, const QSize &requestedSize, QSize *size) {
        // Honour an explicit sourceSize if a view sets one; otherwise hand back the
        // cached image and let the GPU scale it to the delegate.
        if (requestedSize.isValid() && requestedSize.width() > 0 && requestedSize.height() > 0
            && (img.width() > requestedSize.width() || img.height() > requestedSize.height()))
            img = img.scaled(requestedSize, Qt::KeepAspectRatio, Qt::SmoothTransformation);
        if (size) *size = img.size();
        return img;
    }

    // Delete the oldest cached covers until the cache is back under its limit.
    void enforceLimit() {
        const qint64 limit = m_limitBytes.load();
        if (limit <= 0) return;              // 0 = unbounded
        if (!m_evict.tryLock()) return;      // another thread is already evicting
        const QFileInfoList files =
            QDir(m_cacheDir).entryInfoList(QDir::Files, QDir::Time | QDir::Reversed);  // oldest first
        qint64 total = 0;
        for (const QFileInfo &fi : files) total += fi.size();
        for (const QFileInfo &fi : files) {
            if (total <= limit) break;
            total -= fi.size();
            QFile::remove(fi.absoluteFilePath());
        }
        m_evict.unlock();
    }

    QString m_cacheDir;
    std::atomic<bool>   m_enabled{true};
    std::atomic<qint64> m_limitBytes{qint64(250) * 1024 * 1024};   // default 250 MB
    std::atomic<int>    m_writes{0};
    QMutex m_evict;
};
