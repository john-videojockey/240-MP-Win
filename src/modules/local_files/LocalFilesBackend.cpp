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
#include <QCollator>
#include <QDateTime>
#include <QFileSystemWatcher>
#include <QTimer>
#include <QtConcurrent/QtConcurrentRun>
#include <QProcess>
#include <QStandardPaths>
#include <QCryptographicHash>
#include <QJsonArray>
#include <QSet>

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

    // Live folder watch. directoryChanged fires on any add/remove/rename in the
    // watched folder; coalesce a burst (e.g. copying several files) through a
    // short debounce before rescanning the current folder.
    m_watcher = new QFileSystemWatcher(this);
    m_rescanDebounce = new QTimer(this);
    m_rescanDebounce->setSingleShot(true);
    m_rescanDebounce->setInterval(500);
    connect(m_watcher, &QFileSystemWatcher::directoryChanged, this,
            [this](const QString &changed) {
        // Some tools replace a directory entry on change, which drops it from the
        // watch list — re-add it if it still exists.
        if (QDir(changed).exists() && !m_watcher->directories().contains(changed))
            m_watcher->addPath(changed);
        if (changed == m_watchedFolder)
            m_rescanDebounce->start();
    });
    connect(m_rescanDebounce, &QTimer::timeout, this, [this]() {
        if (!m_watchedFolder.isEmpty())
            rescanAsync(m_watchedFolder);
    });
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

// Canonical history key: forward slashes (what Qt's absoluteFilePath produces,
// and what mpv accepts on Windows) so a path never fails to match itself just
// because of separator style.
static QString normKey(const QString &path) {
    return QDir::fromNativeSeparators(path);
}

// Watched flag for a path in an already-loaded history map (avoids re-reading the
// history file once per item during a scan).
static bool isWatchedIn(const QVariantMap &history, const QString &path) {
    return history.value(normKey(path)).toMap().value("watched").toBool();
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
    const QVariant val = loadHistory().value(normKey(filePath));
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
    const QVariantMap prev = history.value(normKey(filePath)).toMap();
    QVariantMap entry;
    entry["pos"]   = positionMs;
    entry["plPos"] = playlistPos;
    // Duration and a last-played timestamp drive the Continue Watching row
    // (progress bar + newest-first ordering). Keep any prior duration if this
    // call didn't supply one.
    if (durationMs > 0)
        entry["dur"] = durationMs;
    else if (prev.contains("dur"))
        entry["dur"] = prev.value("dur");
    entry["ts"] = QDateTime::currentMSecsSinceEpoch();
    // Playing re-enters Continue Watching (tracked) and clears any watched mark.
    entry["tracked"] = true;
    history[normKey(filePath)] = entry;
    saveHistory(history);
}

// Watched flag (from the detail view's Watched button). Marking watched drops
// the resume position so the item leaves Continue Watching; unmarking just
// clears the flag.
void LocalFilesBackend::set_watched(const QString &filePath, bool watched) {
    QVariantMap history = loadHistory();
    QVariantMap entry = history.value(normKey(filePath)).toMap();
    if (watched) {
        entry.remove("pos");
        entry.remove("plPos");
        entry["watched"] = true;
        entry["ts"] = QDateTime::currentMSecsSinceEpoch();
    } else {
        entry.remove("watched");
        if (entry.value("pos").toInt() <= 0) { history.remove(normKey(filePath)); saveHistory(history); return; }
    }
    history[normKey(filePath)] = entry;
    saveHistory(history);
}

bool LocalFilesBackend::is_watched(const QString &filePath) {
    return loadHistory().value(normKey(filePath)).toMap().value("watched").toBool();
}

// Continue Watching membership (the detail view's Tracked button). Untracking
// keeps the resume position but hides the item from the row; tracking restores
// it. An item with no saved position simply can't be tracked.
void LocalFilesBackend::set_tracked(const QString &filePath, bool tracked) {
    QVariantMap history = loadHistory();
    if (!history.contains(normKey(filePath))) return;
    QVariantMap entry = history.value(normKey(filePath)).toMap();
    entry["tracked"] = tracked;
    history[normKey(filePath)] = entry;
    saveHistory(history);
}

bool LocalFilesBackend::has_continue_watching() {
    const QVariantMap history = loadHistory();
    for (auto it = history.constBegin(); it != history.constEnd(); ++it) {
        const QVariantMap e = it.value().toMap();
        if (e.value("pos").toInt() <= 0) continue;
        if (e.contains("tracked") && !e.value("tracked").toBool()) continue;
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
        if (e.contains("tracked") && !e.value("tracked").toBool()) continue;  // removed from CW
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
    history.remove(normKey(filePath));
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
// Numeric-aware, case-insensitive sort so "Season 2" precedes "Season 10" and
// unpadded episode names ("Episode 2" before "Episode 10") order correctly —
// QDir::Name is plain lexicographic. Applied to browse/flatten listings so both
// the on-screen order and the playback order (Detail walks the items array) are
// right.
static void naturalSort(QStringList &names) {
    QCollator c;
    c.setNumericMode(true);
    c.setCaseSensitivity(Qt::CaseInsensitive);
    std::sort(names.begin(), names.end(),
              [&c](const QString &a, const QString &b) { return c.compare(a, b) < 0; });
}

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

// Pull a season/episode out of a filename: "S01E02", "S1 E2", "S01.E02",
// "1x02", etc. Lets shows with no season folders and no per-file nfo still be
// recognized (and ordered) as a series.
static bool parseSeasonEpisode(const QString &name, int &season, int &episode) {
    static const QRegularExpression reSE(
        QStringLiteral("[Ss](\\d{1,2})[\\s._-]*[Ee](\\d{1,3})"));
    QRegularExpressionMatch m = reSE.match(name);
    if (m.hasMatch()) { season = m.captured(1).toInt(); episode = m.captured(2).toInt(); return true; }
    // NxNN form (1x02), with boundaries so it doesn't grab "1920x1080" etc.
    static const QRegularExpression reX(
        QStringLiteral("(?<![\\dA-Za-z])(\\d{1,2})[Xx](\\d{1,3})(?![\\dxX])"));
    m = reX.match(name);
    if (m.hasMatch()) { season = m.captured(1).toInt(); episode = m.captured(2).toInt(); return true; }
    return false;
}

// Bonus content, not an episode: a video in an "Extras"/"Featurettes"/…​ folder
// anywhere up to the show root, or one with a Kodi extras filename suffix.
static bool isExtraVideo(const QString &absPath, const QString &showRoot) {
    static const QStringList kExtraDirs = {
        QStringLiteral("extras"), QStringLiteral("featurettes"),
        QStringLiteral("behind the scenes"), QStringLiteral("behindthescenes"),
        QStringLiteral("deleted scenes"), QStringLiteral("deletedscenes"),
        QStringLiteral("interviews"), QStringLiteral("trailers"),
        QStringLiteral("shorts"), QStringLiteral("scenes"),
        QStringLiteral("specials"), QStringLiteral("bonus"), QStringLiteral("other")
    };
    static const QStringList kExtraSuffixes = {
        QStringLiteral("-trailer"), QStringLiteral("-behindthescenes"),
        QStringLiteral("-featurette"), QStringLiteral("-deleted"),
        QStringLiteral("-interview"), QStringLiteral("-scene"),
        QStringLiteral("-short"), QStringLiteral("-clip"),
        QStringLiteral("-sample"), QStringLiteral("-bonus"), QStringLiteral("-other")
    };
    const QString root = QDir(showRoot).absolutePath();
    QDir d = QFileInfo(absPath).absoluteDir();
    for (int guard = 0; guard < 8; ++guard) {
        if (kExtraDirs.contains(d.dirName().toLower())) return true;
        if (d.absolutePath().compare(root, Qt::CaseInsensitive) == 0) break;
        if (!d.cdUp()) break;
    }
    const QString base = QFileInfo(absPath).completeBaseName().toLower();
    for (const QString &s : kExtraSuffixes)
        if (base.endsWith(s)) return true;
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

QString LocalFilesBackend::findSuffixArtFile(const QDir &dir, const QStringList &suffixes) {
    static const QStringList kArtExts = {"jpg", "jpeg", "png", "webp"};
    const QFileInfoList files = dir.entryInfoList(QDir::Files, QDir::Name);
    for (const QFileInfo &fi : files) {
        if (!kArtExts.contains(fi.suffix().toLower())) continue;
        const QString b = fi.completeBaseName().toLower();
        // Skip Kodi season sidecars (season01-poster, season-all-poster, …) so a
        // show folder doesn't adopt one of its season posters as its own cover.
        if (b.startsWith("season") && b.size() > 6 && (b.at(6).isDigit() || b.at(6) == '-'))
            continue;
        for (const QString &s : suffixes)
            if (b.endsWith(s))
                return QUrl::fromLocalFile(fi.absoluteFilePath()).toString();
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

// Actors from a Kodi/TMM nfo: each <actor> with <name>/<role>/<thumb>. Capped so
// a huge cast doesn't bloat the info screen. thumb is whatever the nfo holds (a
// scraper URL or a local path); the view falls back to an initial when absent.
static QVariantList parseActors(const QString &nfoPath) {
    QFile f(nfoPath);
    if (!f.open(QIODevice::ReadOnly))
        return {};
    QVariantList actors;
    QVariantMap cur;
    bool inActor = false;
    QXmlStreamReader xml(&f);
    while (!xml.atEnd()) {
        const auto tok = xml.readNext();
        if (tok == QXmlStreamReader::StartElement) {
            const QString n = xml.name().toString().toLower();
            if (n == "actor") { inActor = true; cur.clear(); }
            else if (inActor && n == "name")  cur["name"] = xml.readElementText().trimmed();
            else if (inActor && n == "role")  cur["role"] = xml.readElementText().trimmed();
            else if (inActor && n == "thumb" && !cur.contains("thumb"))
                cur["thumb"] = xml.readElementText().trimmed();
        } else if (tok == QXmlStreamReader::EndElement
                   && xml.name().toString().toLower() == "actor") {
            if (!cur.value("name").toString().isEmpty()) actors.append(cur);
            inActor = false;
            if (actors.size() >= 30) break;
        }
    }
    return actors;
}

// Folder entries: Kodi-convention artwork inside the folder plus a
// tvshow.nfo / movie.nfo for the display title.
void LocalFilesBackend::enrichFolderItem(QVariantMap &item, const QString &folderPath) const {
    const QDir d(folderPath);
    // Generic names first (poster.jpg/folder.jpg/…); then TinyMediaManager
    // sidecars named after the title inside the folder ("MovieName-poster.jpg"),
    // so a one-movie-per-folder library shows covers in the browse grid too, not
    // only on the info screen.
    QString thumb = findArtFile(d, {"poster", "folder", "cover"});
    if (thumb.isEmpty()) thumb = findSuffixArtFile(d, {"-poster", "-thumb"});
    QString art = findArtFile(d, {"fanart", "backdrop", "background"});
    if (art.isEmpty()) art = findSuffixArtFile(d, {"-fanart", "-backdrop"});
    if (!thumb.isEmpty()) { item["thumb"] = thumb; item["poster"] = thumb; }
    if (!art.isEmpty())   item["art"]   = art;

    // tvshow.nfo / movie.nfo, plus "<FolderName>.nfo" — the TinyMediaManager movie
    // convention names the nfo after the folder ("Movie (2020)/Movie (2020).nfo").
    const QStringList nfoCandidates = {
        QStringLiteral("tvshow.nfo"), QStringLiteral("movie.nfo"), d.dirName() + ".nfo"
    };
    for (const QString &nfoName : nfoCandidates) {
        const QString nfoPath = d.filePath(nfoName);
        if (!QFileInfo::exists(nfoPath)) continue;
        const QVariantMap meta = parseNfo(nfoPath);
        if (meta.isEmpty()) continue;
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

    // Season/episode from the filename (SxxExx / 1x02) as a baseline, so a show
    // with no season folders and no nfo is still recognized and ordered. A per-
    // file/show nfo below overrides these when it carries its own numbers.
    int fsn = 0, fep = 0;
    if (parseSeasonEpisode(base, fsn, fep)) {
        item["season"]  = fsn;
        item["episode"] = fep;
    }

    // Per-file nfo ("<name>.nfo") is authoritative. Failing that, a folder-level
    // movie.nfo applies — a movie folder holds one video, so its metadata is the
    // video's. Both describe THIS item, so everything (including title) applies.
    QString nfoPath = d.filePath(base + ".nfo");
    if (!QFileInfo::exists(nfoPath) && QFileInfo::exists(d.filePath("movie.nfo")))
        nfoPath = d.filePath("movie.nfo");
    if (QFileInfo::exists(nfoPath)) {
        const QVariantMap meta = parseNfo(nfoPath);
        for (auto it = meta.constBegin(); it != meta.constEnd(); ++it)
            item[it.key()] = it.value();
        return;
    }

    // No metadata of its own: inherit show-level context from the closest
    // ancestor .nfo (typically a show's tvshow.nfo), so a bare episode file still
    // shows a plot / year / show name. That ancestor's title is the SHOW title,
    // so it becomes showTitle — never the item title, which stays the filename.
    const QVariantMap inherited = parentNfoMeta(d);
    if (inherited.isEmpty())
        return;
    const QString showTitle = !inherited.value("showTitle").toString().isEmpty()
                              ? inherited.value("showTitle").toString()
                              : inherited.value("title").toString();
    if (!showTitle.isEmpty() && !item.contains("showTitle"))
        item["showTitle"] = showTitle;
    if (inherited.contains("plot") && !item.contains("plot"))
        item["plot"] = inherited.value("plot");
    if (inherited.contains("year") && !item.contains("year"))
        item["year"] = inherited.value("year");
}

QVariantMap LocalFilesBackend::parentNfoMeta(const QDir &startDir) const {
    const QString root = QDir(m_mediaRoot).absolutePath();
    QDir dir = startDir;
    for (int level = 0; level <= 6; ++level) {
        // Standard show/season metadata names first.
        for (const QString &cand : {QStringLiteral("tvshow.nfo"), QStringLiteral("season.nfo")}) {
            const QString p = dir.filePath(cand);
            if (QFileInfo::exists(p)) {
                const QVariantMap m = parseNfo(p);
                if (!m.isEmpty()) return m;
            }
        }
        // Otherwise a lone folder-level .nfo (a dir with several is more likely
        // per-episode nfos, so skip those to avoid grabbing a sibling's data).
        const QStringList nfos = dir.entryList({QStringLiteral("*.nfo")}, QDir::Files);
        if (nfos.size() == 1) {
            const QVariantMap m = parseNfo(dir.filePath(nfos.first()));
            if (!m.isEmpty()) return m;
        }
        if (dir.absolutePath().compare(root, Qt::CaseInsensitive) == 0)
            break;   // don't climb above the media root
        if (!dir.cdUp())
            break;   // reached the filesystem root
    }
    return {};
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

// True if the folder — or any descendant, up to the same depth collectVideos
// reaches — holds a video file. Early-exits on the first hit. Used to decide
// whether a subfolder has content worth keeping as its own navigable folder
// (a season or nested group) instead of flattening it into the parent.
bool LocalFilesBackend::folderContainsVideo(const QString &path, int depth) const {
    if (depth > 4) return false;
    QDir dir(path);
    for (const QString &name : dir.entryList(QDir::Files)) {
        const QString suffix = QFileInfo(name).suffix().toLower();
        if (kMediaExts.contains(suffix) && !kImageExts.contains(suffix)
            && !kPlaylistExts.contains(suffix))
            return true;
    }
    for (const QString &sub : dir.entryList(QDir::Dirs | QDir::NoDotAndDotDot))
        if (folderContainsVideo(dir.absoluteFilePath(sub), depth + 1))
            return true;
    return false;
}

bool LocalFilesBackend::folderFullyWatched(const QString &path, const QVariantMap &history,
                                           int depth) const {
    if (depth > 5) return false;   // too deep to reason about — treat as not-all-watched
    QDir dir(path);
    bool anyVideo = false;
    for (const QString &name : dir.entryList(QDir::Files)) {
        const QString suffix = QFileInfo(name).suffix().toLower();
        if (!kMediaExts.contains(suffix) || kImageExts.contains(suffix)
            || kPlaylistExts.contains(suffix))
            continue;
        anyVideo = true;
        if (!isWatchedIn(history, dir.absoluteFilePath(name)))
            return false;   // an unwatched video — folder isn't fully played
    }
    for (const QString &sub : dir.entryList(QDir::Dirs | QDir::NoDotAndDotDot)) {
        const QString subPath = dir.absoluteFilePath(sub);
        if (!folderContainsVideo(subPath, depth + 1)) continue;   // no videos below — ignore
        anyVideo = true;
        if (!folderFullyWatched(subPath, history, depth + 1))
            return false;
    }
    return anyVideo;
}

// Gather a media folder's videos across its subfolders into one flat, enriched
// list (used when a show/movie folder has all its videos at the root). Depth-
// capped so a stray deep tree can't stall the scan; artwork/nfo files skipped.
void LocalFilesBackend::collectVideos(const QString &path, QVariantList &out, int depth) const {
    if (depth > 4) return;
    QDir dir(path);
    QStringList vidFiles = dir.entryList(QDir::Files, QDir::Name);
    naturalSort(vidFiles);
    for (const QString &name : vidFiles) {
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
    QStringList subDirs = dir.entryList(QDir::Dirs | QDir::NoDotAndDotDot, QDir::Name);
    naturalSort(subDirs);
    for (const QString &sub : subDirs)
        collectVideos(dir.absoluteFilePath(sub), out, depth + 1);
}

QVariantMap LocalFilesBackend::series_episodes(const QString &videoPath) {
    const QFileInfo fi(videoPath);
    QDir parent = fi.absoluteDir();
    QDir grand(parent);
    const bool haveGrand = grand.cdUp();
    const bool inSeason = isSeasonFolder(parent.dirName());
    // A tvshow.nfo marks the show root: its video subfolders are seasons even when
    // they carry irregular names (not "Season NN"); a flat show may have it too.
    const bool grandIsShow  = haveGrand && QFileInfo::exists(grand.filePath(QStringLiteral("tvshow.nfo")));
    const bool parentIsShow = QFileInfo::exists(parent.filePath(QStringLiteral("tvshow.nfo")));

    // Show root: the season/show folder's parent when the file is one season deep
    // (regular naming or nfo-marked), else the containing folder — a flat show, or
    // a movie folder.
    QString showRoot = parent.absolutePath();
    if ((inSeason || grandIsShow) && haveGrand)
        showRoot = grand.absolutePath();

    QVariantMap self;
    self["name"]     = fi.fileName();
    self["path"]     = fi.absoluteFilePath();
    self["isFolder"] = false;
    enrichVideoItem(self, fi.absoluteFilePath());

    // A series episode: sits in a season, under a tvshow.nfo, or its name/nfo
    // carries an episode number — but never if it is itself bonus content. A plain
    // movie (or an extra) carries no series, so callers won't auto-advance it.
    const bool selfIsExtra = isExtraVideo(fi.absoluteFilePath(), showRoot);
    const bool isSeries = !selfIsExtra
        && (inSeason || grandIsShow || parentIsShow || self.value("episode").toInt() > 0);
    if (!isSeries)
        return QVariantMap{{"episodes", QVariantList{self}}, {"index", 0}, {"isSeries", false}};

    // Every video under the show root in natural order (season-then-episode for
    // regular names, plain alphabetical for irregular ones), minus bonus content —
    // extras belong in Cast & Extras, not the episode rotation.
    QVariantList all;
    collectVideos(showRoot, all, 0);
    QVariantList episodes;
    for (const QVariant &v : all) {
        const QVariantMap m = v.toMap();
        if (!isExtraVideo(m.value("path").toString(), showRoot))
            episodes.append(m);
    }
    if (episodes.isEmpty()) episodes.append(self);

    int index = 0;
    const QString target = fi.absoluteFilePath();
    for (int i = 0; i < episodes.size(); ++i) {
        if (episodes.at(i).toMap().value("path").toString()
                .compare(target, Qt::CaseInsensitive) == 0) { index = i; break; }
    }
    return QVariantMap{{"episodes", episodes}, {"index", index}, {"isSeries", true}};
}

QVariantList LocalFilesBackend::get_cast_extras(const QString &videoPath) {
    const QFileInfo fi(videoPath);
    QDir parent = fi.absoluteDir();
    QDir grand(parent);
    const bool haveGrand = grand.cdUp();
    const bool inSeason = isSeasonFolder(parent.dirName());
    const bool grandIsShow = haveGrand && QFileInfo::exists(grand.filePath(QStringLiteral("tvshow.nfo")));

    // The show/movie root: the same resolution series_episodes uses, so extras are
    // gathered from the whole show, not just the current season folder.
    QString showRoot = parent.absolutePath();
    if ((inSeason || grandIsShow) && haveGrand)
        showRoot = grand.absolutePath();

    QVariantList out;

    // Extras first (playable): every bonus video under the show/movie root — the
    // non-episode files (Extras/Featurettes/Specials/... folders, -trailer/... names).
    QVariantList all;
    collectVideos(showRoot, all, 0);
    for (const QVariant &v : all) {
        const QVariantMap m = v.toMap();
        const QString p = m.value("path").toString();
        if (!isExtraVideo(p, showRoot))
            continue;
        const QFileInfo ei(p);
        // Sidecar artwork if any, else an already-generated frame from the cache;
        // otherwise empty and generate_extra_thumbs() fills it in asynchronously.
        QString img = m.value("thumb").toString();
        if (img.isEmpty()) img = m.value("art").toString();
        if (img.isEmpty()) {
            const QString cache = thumbCachePath(p);
            if (QFileInfo::exists(cache) && QFileInfo(cache).size() > 0)
                img = QUrl::fromLocalFile(cache).toString();
        }
        out.append(QVariantMap{
            {"kind",     QStringLiteral("extra")},
            {"title",    ei.completeBaseName()},
            {"subtitle", ei.absoluteDir().dirName()},   // the extras folder it lives in
            {"image",    img},
            {"path",     p},
        });
    }

    // Cast: actors from the show's tvshow.nfo, else the movie/per-file nfo.
    const QString base = fi.completeBaseName();
    const QStringList nfoCandidates = {
        QDir(showRoot).filePath(QStringLiteral("tvshow.nfo")),
        parent.filePath(base + QStringLiteral(".nfo")),
        parent.filePath(QStringLiteral("movie.nfo")),
        parent.filePath(parent.dirName() + QStringLiteral(".nfo")),
    };
    for (const QString &nfo : nfoCandidates) {
        if (!QFileInfo::exists(nfo))
            continue;
        const QVariantList actors = parseActors(nfo);
        for (const QVariant &a : actors) {
            const QVariantMap am = a.toMap();
            out.append(QVariantMap{
                {"kind",     QStringLiteral("cast")},
                {"title",    am.value("name")},
                {"subtitle", am.value("role")},
                {"image",    am.value("thumb")},
            });
        }
        if (!actors.isEmpty())
            break;   // first nfo with a cast wins
    }
    return out;
}

QString LocalFilesBackend::thumbCachePath(const QString &videoPath) const {
    QString local = videoPath;
    if (local.startsWith(QStringLiteral("file:"))) local = QUrl(local).toLocalFile();
    const QFileInfo fi(local);
    const QString key = fi.absoluteFilePath() + QStringLiteral("|")
                        + QString::number(fi.size()) + QStringLiteral("|")
                        + QString::number(fi.lastModified().toSecsSinceEpoch());
    const QString hash = QString::fromLatin1(
        QCryptographicHash::hash(key.toUtf8(), QCryptographicHash::Md5).toHex());
    return m_dataRoot + QStringLiteral("/thumbs/") + hash + QStringLiteral(".jpg");
}

void LocalFilesBackend::generate_extra_thumbs(const QVariantList &extras) {
    const QString ff = QStandardPaths::findExecutable(QStringLiteral("ffmpeg"));
    if (ff.isEmpty()) return;
    QDir().mkpath(m_dataRoot + QStringLiteral("/thumbs"));
    for (const QVariant &v : extras) {
        const QVariantMap m = v.toMap();
        if (m.value("kind").toString() != QStringLiteral("extra")) continue;
        if (!m.value("image").toString().isEmpty()) continue;   // already has artwork
        const QString path = m.value("path").toString();
        if (path.isEmpty()) continue;
        QString local = path;
        if (local.startsWith(QStringLiteral("file:"))) local = QUrl(local).toLocalFile();
        const QString outPath = thumbCachePath(local);
        if (QFileInfo::exists(outPath) && QFileInfo(outPath).size() > 0) {
            emit extraThumbReady(path, QUrl::fromLocalFile(outPath).toString());
            continue;
        }
        auto *proc = new QProcess(this);
        // The thumbnail filter picks a representative (non-black) frame from the
        // head of the file — fast and robust for clips of any length.
        const QStringList args = {
            QStringLiteral("-y"), QStringLiteral("-i"), local,
            QStringLiteral("-vf"), QStringLiteral("thumbnail,scale=360:-2"),
            QStringLiteral("-frames:v"), QStringLiteral("1"),
            QStringLiteral("-an"), QStringLiteral("-q:v"), QStringLiteral("4"),
            outPath
        };
        connect(proc, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished), this,
                [this, proc, path, outPath](int, QProcess::ExitStatus) {
            proc->deleteLater();
            if (QFileInfo::exists(outPath) && QFileInfo(outPath).size() > 0)
                emit extraThumbReady(path, QUrl::fromLocalFile(outPath).toString());
        });
        proc->start(ff, args);
    }
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

    QStringList subdirs = dir.entryList(QDir::Dirs | QDir::NoDotAndDotDot, QDir::Name);
    naturalSort(subdirs);
    const bool isMediaRoot = (clean.compare(root, Qt::CaseInsensitive) == 0);

    // Smart show/movie folders: a scraped folder (has .nfo/artwork) below the
    // media root presents as content, not a raw directory listing. The media
    // root itself always browses normally.
    if (!isMediaRoot && folderHasNfoOrArtwork(dir)) {
        // A subfolder stays a navigable folder when it looks like a season OR it
        // actually holds video anywhere below it — so a real CONTENT > SEASON >
        // FILE (or deeper) tree is preserved and browsed one level at a time,
        // never collapsed. Flattening is reserved for the true movie / flat-show
        // case where every video sits at the folder's own root.
        QStringList contentDirs;
        for (const QString &sub : subdirs)
            if (isSeasonFolder(sub) || folderContainsVideo(dir.absoluteFilePath(sub), 0))
                contentDirs.append(sub);

        if (!contentDirs.isEmpty()) {
            // Show these subfolders (seasons / nested groups), plus any loose
            // videos at the root — mixed layouts keep both.
            for (const QString &sub : contentDirs) {
                QVariantMap item;
                item["name"]     = sub;
                item["path"]     = dir.absoluteFilePath(sub);
                item["isFolder"] = true;
                item["isSeason"] = isSeasonFolder(sub);
                enrichFolderItem(item, item["path"].toString());
                result.append(item);
            }
            QStringList looseFiles = dir.entryList(QDir::Files, QDir::Name);
            naturalSort(looseFiles);
            for (const QString &name : looseFiles) {
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

        // Movie or flat show folder (all videos at the root): flatten to videos.
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

    QStringList browseFiles = dir.entryList(QDir::Files, QDir::Name);
    naturalSort(browseFiles);
    for (const QString &name : browseFiles) {
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

// Friendly name for an ISO 639-2 language code (ffprobe reports these). Falls back
// to the uppercased code for anything not in the common set.
static QString langLabel(const QString &code) {
    static const QHash<QString, QString> kNames = {
        {"eng","ENGLISH"}, {"jpn","JAPANESE"}, {"spa","SPANISH"}, {"fre","FRENCH"},
        {"fra","FRENCH"}, {"ger","GERMAN"}, {"deu","GERMAN"}, {"ita","ITALIAN"},
        {"kor","KOREAN"}, {"chi","CHINESE"}, {"zho","CHINESE"}, {"rus","RUSSIAN"},
        {"por","PORTUGUESE"}, {"dut","DUTCH"}, {"nld","DUTCH"}, {"pol","POLISH"},
        {"ara","ARABIC"}, {"hin","HINDI"}, {"tur","TURKISH"}, {"swe","SWEDISH"},
        {"nor","NORWEGIAN"}, {"dan","DANISH"}, {"fin","FINNISH"}, {"tha","THAI"},
        {"vie","VIETNAMESE"}, {"ind","INDONESIAN"}, {"heb","HEBREW"}, {"ukr","UKRAINIAN"},
        {"ces","CZECH"}, {"cze","CZECH"}, {"hun","HUNGARIAN"}, {"ell","GREEK"},
        {"gre","GREEK"}, {"ron","ROMANIAN"}, {"und","UNKNOWN"},
    };
    const QString c = code.toLower();
    return kNames.value(c, c.toUpper());
}

void LocalFilesBackend::probe_tracks(const QString &path) {
    const QString ff = QStandardPaths::findExecutable(QStringLiteral("ffprobe"));
    if (ff.isEmpty()) { emit tracksReady(path, QVariantMap{}); return; }

    QString local = path;
    if (local.startsWith("file:")) local = QUrl(local).toLocalFile();

    auto *proc = new QProcess(this);
    const QStringList args = {
        "-v", "quiet", "-print_format", "json", "-show_streams", local
    };
    connect(proc, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished), this,
            [this, proc, path](int, QProcess::ExitStatus) {
        const QByteArray out = proc->readAllStandardOutput();
        proc->deleteLater();
        const QJsonArray streams = QJsonDocument::fromJson(out).object()["streams"].toArray();
        // Distinct languages per kind, preserving file order.
        QVariantList audio, subtitle;
        QSet<QString> aSeen, sSeen;
        for (const auto &sv : streams) {
            const QJsonObject s = sv.toObject();
            const QString type = s["codec_type"].toString();
            QString lang = s["tags"].toObject()["language"].toString().toLower();
            if (lang.isEmpty()) lang = "und";
            if (type == "audio" && !aSeen.contains(lang)) {
                aSeen.insert(lang);
                audio.append(QVariantMap{{"lang", lang}, {"label", langLabel(lang)}});
            } else if (type == "subtitle" && !sSeen.contains(lang)) {
                sSeen.insert(lang);
                subtitle.append(QVariantMap{{"lang", lang}, {"label", langLabel(lang)}});
            }
        }
        emit tracksReady(path, QVariantMap{{"audio", audio}, {"subtitle", subtitle}});
    });
    proc->start(ff, args);
}

// Tag each entry with a "watched" flag: a video that has been played, or a folder
// whose whole video tree has. History is read once and shared across the items.
void LocalFilesBackend::enrichWatched(QVariantList &items) const {
    const QVariantMap history = loadHistory();
    for (int i = 0; i < items.size(); ++i) {
        QVariantMap m = items[i].toMap();
        const QString p = m.value("path").toString();
        if (m.value("isFolder").toBool()) {
            m["watched"] = folderFullyWatched(p, history, 0);
        } else {
            const QString suffix = QFileInfo(p).suffix().toLower();
            if (kMediaExts.contains(suffix) && !kImageExts.contains(suffix)
                && !kPlaylistExts.contains(suffix))
                m["watched"] = isWatchedIn(history, p);
        }
        items[i] = m;
    }
}

QVariantList LocalFilesBackend::getItems(const QString &path) {
    QVariantList items = scanItems(path, m_mediaRoot);
    enrichWatched(items);
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

void LocalFilesBackend::clear_cache() {
    // Drop both the in-memory and on-disk listing caches; the next browse of any
    // folder falls through to a fresh scanItems (and repopulates the cache).
    m_cacheLoaded = true;   // treat as loaded-but-empty so we don't re-read the file
    m_cache.clear();
    QFile::remove(cacheFilePath());
    qInfo("[LocalFiles] listing cache cleared");
}

void LocalFilesBackend::loadItems(const QString &path) {
    const QString clean = QDir(path).absolutePath();

    // Watch the folder now being browsed (a single active watch that follows
    // navigation), so content added while it's open refreshes it live.
    if (m_watcher) {
        if (!m_watchedFolder.isEmpty() && m_watchedFolder != clean)
            m_watcher->removePath(m_watchedFolder);
        m_watchedFolder = clean;
        if (QDir(clean).exists() && !m_watcher->directories().contains(clean))
            m_watcher->addPath(clean);
    }

    rescanAsync(clean);
}

void LocalFilesBackend::rescanAsync(const QString &clean) {
    const QString mediaRoot = m_mediaRoot;
    // Scan on a worker thread — network shares and spun-down disks can stall
    // for seconds, and the UI shows the LOADING splash (or the cached listing)
    // meanwhile. Result hops back to the main thread before touching state.
    auto future = QtConcurrent::run([this, clean, mediaRoot]() {
        QVariantList items = scanItems(clean, mediaRoot);
        enrichWatched(items);   // played-state marks, same as getItems
        QMetaObject::invokeMethod(this, [this, clean, items]() {
            updateCache(clean, items);
            emit itemsLoaded(clean, items);
        }, Qt::QueuedConnection);
    });
    Q_UNUSED(future)
}
