#include "LocalFilesBackend.h"
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QVariantMap>
#include <QJsonDocument>
#include <QJsonObject>
#include <QUrl>
#include <QXmlStreamReader>
#include <QRegularExpression>
#include <QDateTime>
#include <QtConcurrent/QtConcurrentRun>

// supported image types
static const QStringList kImageExts = {
    "jpg", "jpeg", "png", "gif", "webp", "bmp", "tif", "tiff"
};
// supported playlist types
static const QStringList kPlaylistExts = { 
    "m3u", "m3u8" 
};
// full list of supported playback types (combo of video, image and playlist)
static const QStringList kMediaExts =
    QStringList{ "mp4", "mkv", "avi", "mov", "m4v", "webm", "wmv", "flv", "f4v", "mpg", "mpeg", "vob" }
    + kImageExts
    + kPlaylistExts;

LocalFilesBackend::LocalFilesBackend(const QString &appRoot, const QString &dataRoot, QObject *parent)
    : QObject(parent), m_appRoot(appRoot), m_dataRoot(dataRoot), m_mediaRoot(dataRoot + "/media")
{
    // Resolve the configured media directory (falls back to the dataRoot/media default).
    QFile f(m_dataRoot + "/config.json");
    if (f.open(QIODevice::ReadOnly)) {
        QJsonObject cfg = QJsonDocument::fromJson(f.readAll()).object();
        QString dir = cfg["modules"].toObject()["com.240mp.local_files"].toObject()
                          ["media_directory"].toString();
        if (!dir.isEmpty())
            setMediaRoot(dir);
    }
}

bool LocalFilesBackend::isImage(const QString &path) const {
    return kImageExts.contains(QFileInfo(path).suffix().toLower());
}

bool LocalFilesBackend::isPlaylist(const QString &path) const {
    return kPlaylistExts.contains(QFileInfo(path).suffix().toLower());
}

// True if an .m3u/.m3u8 references at least one image entry. Used to decide whether
// the slideshow-redraw mpv script is needed (see MpvController::loadAndPlay): mpv's
// KMS output won't repaint consecutive same-size stills without it.
bool LocalFilesBackend::playlistContainsImages(const QString &path) const {
    if (!isPlaylist(path))
        return false;
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text))
        return false;
    while (!f.atEnd()) {
        const QString line = QString::fromUtf8(f.readLine()).trimmed();
        if (line.isEmpty() || line.startsWith('#'))
            continue;
        if (isImage(line))
            return true;
    }
    return false;
}

QString LocalFilesBackend::historyFilePath() const {
    return m_dataRoot + "/local_files_history.json";
}

QVariantMap LocalFilesBackend::loadHistory() const {
    QFile file(historyFilePath());
    if (!file.open(QIODevice::ReadOnly))
        return {};
    return QJsonDocument::fromJson(file.readAll()).object().toVariantMap();
}

void LocalFilesBackend::saveHistory(const QVariantMap &history) {
    QFile file(historyFilePath());
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate))
        return;
    file.write(QJsonDocument(QJsonObject::fromVariantMap(history)).toJson(QJsonDocument::Compact));
}

QVariantMap LocalFilesBackend::getSavedPosition(const QString &filePath) {
    const QVariant val = loadHistory().value(filePath);
    if (!val.isValid())
        return {};
    if (val.canConvert<QVariantMap>()) {
        QVariantMap entry = val.toMap();
        if (!entry.contains("plPos")) entry["plPos"] = -1;
        return entry;
    }
    // Legacy: plain int stored (pos only)
    return {{"pos", val.toInt()}, {"plPos", -1}};
}

void LocalFilesBackend::savePosition(const QString &filePath, int positionMs,
                                     int playlistPos, int durationMs) {
    QVariantMap history = loadHistory();
    QVariantMap entry;
    entry["pos"]   = positionMs;
    entry["plPos"] = playlistPos;
    // Duration and a last-played timestamp drive the Continue Watching row
    // (progress bar + newest-first ordering). Keep any prior duration if this
    // call didn't supply one.
    if (durationMs > 0)
        entry["dur"] = durationMs;
    else if (history.value(filePath).toMap().contains("dur"))
        entry["dur"] = history.value(filePath).toMap().value("dur");
    entry["ts"] = QDateTime::currentMSecsSinceEpoch();
    history[filePath] = entry;
    saveHistory(history);
}

bool LocalFilesBackend::has_continue_watching() {
    const QVariantMap history = loadHistory();
    for (auto it = history.constBegin(); it != history.constEnd(); ++it) {
        const QVariantMap e = it.value().toMap();
        if (e.value("pos").toInt() <= 0) continue;
        if (isImage(it.key()) || isPlaylist(it.key())) continue;
        if (QFileInfo::exists(it.key())) return true;
    }
    return false;
}

// In-progress single videos (partially watched, still on disk), newest first,
// enriched with artwork/nfo so the Continue Watching grid can show a poster.
QVariantList LocalFilesBackend::get_continue_watching() {
    const QVariantMap history = loadHistory();

    struct Entry { QString path; qint64 ts; int pos; int dur; };
    QList<Entry> entries;
    for (auto it = history.constBegin(); it != history.constEnd(); ++it) {
        const QVariantMap e = it.value().toMap();
        const int pos = e.value("pos").toInt();
        if (pos <= 0) continue;                       // nothing to resume
        if (isImage(it.key()) || isPlaylist(it.key())) continue;
        if (!QFileInfo::exists(it.key())) continue;   // moved/deleted
        entries.append({ it.key(), e.value("ts").toLongLong(),
                         pos, e.value("dur").toInt() });
    }
    std::sort(entries.begin(), entries.end(),
              [](const Entry &a, const Entry &b) { return a.ts > b.ts; });

    QVariantList result;
    const int kMax = 30;
    for (const Entry &e : entries) {
        if (result.size() >= kMax) break;
        QVariantMap item;
        item["name"]       = QFileInfo(e.path).fileName();
        item["path"]       = e.path;
        item["isFolder"]   = false;
        item["viewOffset"] = e.pos;
        item["duration"]   = e.dur;
        enrichVideoItem(item, e.path);
        result.append(item);
    }
    return result;
}

void LocalFilesBackend::clearPosition(const QString &filePath) {
    QVariantMap history = loadHistory();
    history.remove(filePath);
    saveHistory(history);
}

void LocalFilesBackend::get_auto_subtitles_options() {
    QVariantList options;
    QVariantMap forced; forced["id"] = "forced"; forced["label"] = "Forced Only"; forced["old"] = false;
    QVariantMap on;     on["id"] = "on";         on["label"] = "On";              on["old"] = true;
    QVariantMap off;    off["id"] = "off";       off["label"] = "Off";
    options << forced << on << off;
    emit dynamicOptionsReady("auto_subtitles", options);
}

void LocalFilesBackend::get_resume_playback_options() {
    QVariantList options;
    QVariantMap ask; ask["id"] = "ask"; ask["label"] = "Ask";
    QVariantMap yes; yes["id"] = "yes"; yes["label"] = "Always";
    QVariantMap no;  no["id"]  = "no";  no["label"]  = "Never";
    options << ask << yes << no;
    emit dynamicOptionsReady("resume_playback", options);
}

void LocalFilesBackend::get_image_duration_options() {
    QVariantList options;
    QVariantMap five;   five["id"]   = "5";  five["label"]   = "5 Seconds";
    QVariantMap ten;    ten["id"]    = "10"; ten["label"]    = "10 Seconds";
    QVariantMap thirty; thirty["id"] = "30"; thirty["label"] = "30 Seconds";
    QVariantMap sixty;  sixty["id"]  = "60"; sixty["label"]  = "60 Seconds";
    options << five << ten << thirty << sixty;
    emit dynamicOptionsReady("image_duration", options);
}

void LocalFilesBackend::get_subtitle_languages() {
    QStringList addedLabels;
    QVariantList options;

    QFile file(m_appRoot + "/modules/local_files/iso639-1.json");
    if (!file.open(QIODevice::ReadOnly))
        return;

    options.append(QVariantMap{{"id","-"},{"label","Any"}});

    QVariantList locList = QJsonDocument::fromJson(file.readAll()).toVariant().toList();
    for (const QVariant loc : locList)
    {
        QVariantMap langOption = QVariantMap{{"id",loc.toJsonObject()["id"].toString()},{"label",loc.toJsonObject()["label"].toString()}};
        if (langOption["label"].toString() == "" || addedLabels.contains(langOption["label"].toString())) continue;
        addedLabels.append(langOption["label"].toString());
        options.append(langOption);
    }

    emit dynamicOptionsReady("sub_lang", options);
}

QString LocalFilesBackend::mediaRoot() const {
    return m_mediaRoot;
}

void LocalFilesBackend::setMediaRoot(const QString &path) {
    // An empty (reset) setting means back to the dataRoot/media default.
    m_mediaRoot = path.isEmpty() ? m_dataRoot + "/media" : path;
    QDir().mkpath(m_mediaRoot);
    qDebug("[LocalFiles] media root: %s", qPrintable(m_mediaRoot));
}

void LocalFilesBackend::onSettingChanged(const QString &moduleId, const QString &key, const QVariant &value) {
    if (moduleId == QLatin1String("com.240mp.local_files") && key == QLatin1String("media_directory"))
        setMediaRoot(value.toString());
}

// Scraper artwork must not be listed as playable media: a folder of episodes
// with TinyMediaManager "-thumb.jpg" sidecars would otherwise show every
// artwork file as a slideshow entry between the videos.
static bool isArtworkImage(const QString &baseName) {
    static const QStringList kArtBases = {
        "poster", "folder", "cover", "fanart", "backdrop", "background",
        "banner", "landscape", "clearlogo", "clearart", "keyart", "disc", "thumb"
    };
    static const QStringList kArtSuffixes = {
        "-poster", "-thumb", "-fanart", "-backdrop", "-landscape",
        "-banner", "-clearlogo", "-clearart", "-keyart", "-disc"
    };
    const QString b = baseName.toLower();
    if (kArtBases.contains(b)) return true;
    for (const QString &s : kArtSuffixes)
        if (b.endsWith(s)) return true;
    return false;
}

// First existing "<base>.<ext>" image in dir for any of the given base names
// (checked in order), as a file:// URL string QML's Image can load directly.
QString LocalFilesBackend::findArtFile(const QDir &dir, const QStringList &baseNames) {
    static const QStringList kArtExts = {"jpg", "jpeg", "png", "webp"};
    for (const QString &base : baseNames) {
        for (const QString &ext : kArtExts) {
            const QString p = dir.filePath(base + "." + ext);
            if (QFileInfo::exists(p))
                return QUrl::fromLocalFile(p).toString();
        }
    }
    return {};
}

// Minimal Kodi/TinyMediaManager .nfo reader: accepts <movie>, <tvshow>, or
// <episodedetails> roots and extracts the display fields the views use.
// Stops at the root's end so the URL line some scrapers append after the XML
// doesn't trip the parser; a non-XML nfo (bare URL file) yields an empty map.
QVariantMap LocalFilesBackend::parseNfo(const QString &nfoPath) {
    QFile f(nfoPath);
    if (!f.open(QIODevice::ReadOnly))
        return {};

    static const QStringList kRoots = {"movie", "tvshow", "episodedetails"};
    QVariantMap meta;
    QXmlStreamReader xml(&f);
    QString rootName;
    while (!xml.atEnd()) {
        const auto tok = xml.readNext();
        if (tok == QXmlStreamReader::StartElement) {
            const QString name = xml.name().toString().toLower();
            if (rootName.isEmpty()) {
                if (!kRoots.contains(name))
                    return {};   // not a media nfo
                rootName = name;
                continue;
            }
            // Only direct children we care about; readElementText consumes
            // the element so nesting stays balanced.
            if (name == "title")
                meta["title"] = xml.readElementText(QXmlStreamReader::SkipChildElements).trimmed();
            else if (name == "year")
                meta["year"] = xml.readElementText(QXmlStreamReader::SkipChildElements).trimmed();
            else if (name == "premiered" || name == "aired") {
                const QString date = xml.readElementText(QXmlStreamReader::SkipChildElements).trimmed();
                if (!meta.contains("year") && date.size() >= 4)
                    meta["year"] = date.left(4);
            }
            else if (name == "plot" || (name == "outline" && !meta.contains("plot")))
                meta["plot"] = xml.readElementText(QXmlStreamReader::SkipChildElements).trimmed();
            else if (name == "showtitle")
                meta["showTitle"] = xml.readElementText(QXmlStreamReader::SkipChildElements).trimmed();
            else if (name == "season")
                meta["season"] = xml.readElementText(QXmlStreamReader::SkipChildElements).trimmed().toInt();
            else if (name == "episode")
                meta["episode"] = xml.readElementText(QXmlStreamReader::SkipChildElements).trimmed().toInt();
            else if (name == "runtime")
                meta["runtime"] = xml.readElementText(QXmlStreamReader::SkipChildElements).trimmed().toInt();
            else
                xml.skipCurrentElement();
        } else if (tok == QXmlStreamReader::EndElement
                   && xml.name().toString().toLower() == rootName) {
            break;   // ignore anything after the root (scraper URL lines)
        }
    }
    return meta;
}

// Folder entries: Kodi-convention artwork inside the folder plus a
// tvshow.nfo / movie.nfo for the display title.
void LocalFilesBackend::enrichFolderItem(QVariantMap &item, const QString &folderPath) const {
    const QDir d(folderPath);
    const QString thumb = findArtFile(d, {"poster", "folder", "cover"});
    const QString art   = findArtFile(d, {"fanart", "backdrop", "background"});
    if (!thumb.isEmpty()) { item["thumb"] = thumb; item["poster"] = thumb; }
    if (!art.isEmpty())   item["art"]   = art;

    for (const QString &nfoName : {QStringLiteral("tvshow.nfo"), QStringLiteral("movie.nfo")}) {
        const QString nfoPath = d.filePath(nfoName);
        if (!QFileInfo::exists(nfoPath)) continue;
        const QVariantMap meta = parseNfo(nfoPath);
        for (auto it = meta.constBegin(); it != meta.constEnd(); ++it)
            item[it.key()] = it.value();
        break;
    }
}

// Video-file entries: TinyMediaManager sidecars ("<name>-poster.jpg",
// "<name>-fanart.jpg", "<name>.nfo"), falling back to the folder's artwork —
// right for the one-movie-per-folder layout, and for episodes it means the
// season/show art.
void LocalFilesBackend::enrichVideoItem(QVariantMap &item, const QString &filePath) const {
    const QFileInfo fi(filePath);
    const QDir d = fi.dir();
    const QString base = fi.completeBaseName();

    QString thumb = findArtFile(d, {base + "-poster", base + "-thumb", base + "-landscape"});
    if (thumb.isEmpty()) thumb = findArtFile(d, {"poster", "folder", "cover"});
    QString art = findArtFile(d, {base + "-fanart", base + "-backdrop"});
    if (art.isEmpty()) art = findArtFile(d, {"fanart", "backdrop", "background"});
    // The show/season poster (never the episode still) — used by the Continue
    // Watching grid, which prefers a poster over a screenshot.
    QString poster = findArtFile(d, {base + "-poster", "poster", "folder", "cover"});
    QDir parent = d;
    const bool haveParent = parent.cdUp();
    if (art.isEmpty() && haveParent) {
        // Episodes inside "Show/Season N/" — scrapers keep fanart at the show
        // level, so look one folder up before giving up.
        art = findArtFile(parent, {"fanart", "backdrop", "background"});
    }
    if (poster.isEmpty() && haveParent)
        poster = findArtFile(parent, {"poster", "folder", "cover"});
    if (!thumb.isEmpty())  item["thumb"]  = thumb;
    if (!art.isEmpty())    item["art"]    = art;
    if (!poster.isEmpty()) item["poster"] = poster;

    // Per-file nfo ("<name>.nfo") is authoritative. Failing that, a folder-level
    // movie.nfo applies — a movie folder holds one video, so its metadata is the
    // video's. tvshow.nfo is deliberately NOT used here: it's the show title, and
    // applying it to every episode would mislabel them all.
    QString nfoPath = d.filePath(base + ".nfo");
    if (!QFileInfo::exists(nfoPath) && QFileInfo::exists(d.filePath("movie.nfo")))
        nfoPath = d.filePath("movie.nfo");
    if (QFileInfo::exists(nfoPath)) {
        const QVariantMap meta = parseNfo(nfoPath);
        for (auto it = meta.constBegin(); it != meta.constEnd(); ++it)
            item[it.key()] = it.value();
    }
}

// Season/series folder name: "Season 1", "Series 03", "S1", "S 01", or
// "Specials". Used to decide whether a show folder shows seasons or flattens.
bool LocalFilesBackend::isSeasonFolder(const QString &name) {
    static const QRegularExpression re(
        QStringLiteral("^(season|series|s)\\s*\\d{1,3}$|^specials$"),
        QRegularExpression::CaseInsensitiveOption);
    return re.match(name.trimmed()).hasMatch();
}

// A "media folder" carries scraper output: a .nfo file or an artwork image.
// That marks it as a show/movie folder (vs. a plain browse directory) so its
// contents get flattened / seasoned rather than shown file-by-file.
bool LocalFilesBackend::folderHasNfoOrArtwork(const QDir &dir) {
    const QStringList files = dir.entryList(QDir::Files);
    for (const QString &f : files) {
        const QFileInfo fi(f);
        const QString suffix = fi.suffix().toLower();
        if (suffix == QLatin1String("nfo")) return true;
        if (kImageExts.contains(suffix) && isArtworkImage(fi.completeBaseName()))
            return true;
    }
    return false;
}

// Gather a media folder's videos across its subfolders into one flat, enriched
// list (used when a show/movie folder has no season subfolders). Depth-capped
// so a stray deep tree can't stall the scan; artwork/nfo files are skipped.
void LocalFilesBackend::collectVideos(const QString &path, QVariantList &out, int depth) const {
    if (depth > 4) return;
    QDir dir(path);
    for (const QString &name : dir.entryList(QDir::Files, QDir::Name)) {
        const QString suffix = QFileInfo(name).suffix().toLower();
        // Videos only here — a movie/show folder's images are artwork, not content.
        if (!kMediaExts.contains(suffix) || kImageExts.contains(suffix)
            || kPlaylistExts.contains(suffix))
            continue;
        QVariantMap item;
        item["name"]     = name;
        item["path"]     = dir.absoluteFilePath(name);
        item["isFolder"] = false;
        enrichVideoItem(item, item["path"].toString());
        out.append(item);
    }
    for (const QString &sub : dir.entryList(QDir::Dirs | QDir::NoDotAndDotDot, QDir::Name))
        collectVideos(dir.absoluteFilePath(sub), out, depth + 1);
}

// Synchronous scan (runs on a worker thread via loadItems): mediaRoot is
// passed by value so a settings change mid-scan can't race the member.
QVariantList LocalFilesBackend::scanItems(const QString &path, const QString &mediaRoot) const {
    QVariantList result;
    QDir dir(path);
    if (!dir.exists()) {
        qWarning("[LocalFiles] directory not found: %s", qPrintable(path));
        return result;
    }
    // Validate against the media root lexically (absolutePath cleans "." / ".."
    // without resolving symlinks) so intentional symlinks placed inside the media
    // root are followed, while ".." traversal out of the root is still blocked.
    // Case-insensitive: NTFS paths compare equal regardless of case, and QML
    // navigation can hand back a differently-cased drive letter.
    QString clean = QDir(path).absolutePath();
    QString root  = QDir(mediaRoot).absolutePath();
    bool inside = (clean.compare(root, Qt::CaseInsensitive) == 0) ||
                  clean.startsWith(root.endsWith('/') ? root : root + '/',
                                   Qt::CaseInsensitive);
    if (!inside) {
        qWarning("[LocalFiles] path escapes media root: %s", qPrintable(path));
        return result;
    }

    const QStringList subdirs = dir.entryList(QDir::Dirs | QDir::NoDotAndDotDot, QDir::Name);
    const bool isMediaRoot = (clean.compare(root, Qt::CaseInsensitive) == 0);

    // Smart show/movie folders: a scraped folder (has .nfo/artwork) below the
    // media root presents as content, not a raw directory listing. The media
    // root itself always browses normally.
    if (!isMediaRoot && folderHasNfoOrArtwork(dir)) {
        QStringList seasonDirs;
        for (const QString &sub : subdirs)
            if (isSeasonFolder(sub)) seasonDirs.append(sub);

        if (!seasonDirs.isEmpty()) {
            // Show folder with seasons: list the season subfolders (entering one
            // flattens to its episodes), plus any loose videos at the root.
            for (const QString &sub : seasonDirs) {
                QVariantMap item;
                item["name"]     = sub;
                item["path"]     = dir.absoluteFilePath(sub);
                item["isFolder"] = true;
                item["isSeason"] = true;
                enrichFolderItem(item, item["path"].toString());
                result.append(item);
            }
            for (const QString &name : dir.entryList(QDir::Files, QDir::Name)) {
                const QString suffix = QFileInfo(name).suffix().toLower();
                if (!kMediaExts.contains(suffix) || kImageExts.contains(suffix)
                    || kPlaylistExts.contains(suffix))
                    continue;
                QVariantMap item;
                item["name"]     = name;
                item["path"]     = dir.absoluteFilePath(name);
                item["isFolder"] = false;
                enrichVideoItem(item, item["path"].toString());
                result.append(item);
            }
            return result;
        }

        // Movie or flat show folder: flatten to just the videos.
        collectVideos(clean, result, 0);
        return result;
    }

    // Plain browse directory: folders + files as-is.
    for (const QString &name : subdirs) {
        if (isPlaylist(name)) {
            QString innerPath = dir.absoluteFilePath(name) + "/" + name;
            if (QFileInfo::exists(innerPath)) {
                QVariantMap item;
                item["name"]     = name;
                item["path"]     = innerPath;
                item["isFolder"] = false;
                result.append(item);
                continue;
            }
        }
        QVariantMap item;
        item["name"]     = name;
        item["path"]     = dir.absoluteFilePath(name);
        item["isFolder"] = true;
        enrichFolderItem(item, item["path"].toString());
        result.append(item);
    }

    for (const QString &name : dir.entryList(QDir::Files, QDir::Name)) {
        const QString suffix = QFileInfo(name).suffix().toLower();
        if (!kMediaExts.contains(suffix)) continue;
        // Skip scraper artwork (poster.jpg, <name>-thumb.jpg, …) — it backs
        // the covers/backgrounds, it isn't content.
        if (kImageExts.contains(suffix) && isArtworkImage(QFileInfo(name).completeBaseName()))
            continue;
        QVariantMap item;
        item["name"]     = name;
        item["path"]     = dir.absoluteFilePath(name);
        item["isFolder"] = false;
        // Artwork/nfo lookups only make sense for videos — images ARE their
        // own art, and playlists have no scraper convention.
        if (!kImageExts.contains(suffix) && !kPlaylistExts.contains(suffix))
            enrichVideoItem(item, item["path"].toString());
        result.append(item);
    }
    return result;
}

QVariantList LocalFilesBackend::getItems(const QString &path) {
    const QVariantList items = scanItems(path, m_mediaRoot);
    updateCache(QDir(path).absolutePath(), items);
    return items;
}

QString LocalFilesBackend::cacheFilePath() const {
    return m_dataRoot + "/local_files_cache.json";
}

void LocalFilesBackend::ensureCacheLoaded() {
    if (m_cacheLoaded) return;
    m_cacheLoaded = true;
    QFile f(cacheFilePath());
    if (f.open(QIODevice::ReadOnly))
        m_cache = QJsonDocument::fromJson(f.readAll()).object().toVariantMap();
}

void LocalFilesBackend::updateCache(const QString &path, const QVariantList &items) {
    ensureCacheLoaded();
    m_cache[path] = items;
    QFile f(cacheFilePath());
    if (f.open(QIODevice::WriteOnly | QIODevice::Truncate))
        f.write(QJsonDocument(QJsonObject::fromVariantMap(m_cache)).toJson(QJsonDocument::Compact));
}

QVariantList LocalFilesBackend::cachedItems(const QString &path) {
    ensureCacheLoaded();
    return m_cache.value(QDir(path).absolutePath()).toList();
}

void LocalFilesBackend::loadItems(const QString &path) {
    const QString clean = QDir(path).absolutePath();
    const QString mediaRoot = m_mediaRoot;
    // Scan on a worker thread — network shares and spun-down disks can stall
    // for seconds, and the UI shows the LOADING splash (or the cached listing)
    // meanwhile. Result hops back to the main thread before touching state.
    auto future = QtConcurrent::run([this, clean, mediaRoot]() {
        const QVariantList items = scanItems(clean, mediaRoot);
        QMetaObject::invokeMethod(this, [this, clean, items]() {
            updateCache(clean, items);
            emit itemsLoaded(clean, items);
        }, Qt::QueuedConnection);
    });
    Q_UNUSED(future)
}
