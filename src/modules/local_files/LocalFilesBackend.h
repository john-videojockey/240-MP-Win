#pragma once
#include <QObject>
#include <QVariant>
#include <QVariantList>
#include <QVariantMap>

class QDir;
class QFileSystemWatcher;
class QTimer;

class LocalFilesBackend : public QObject {
    Q_OBJECT
public:
    explicit LocalFilesBackend(const QString &appRoot, const QString &dataRoot, QObject *parent = nullptr);

    Q_INVOKABLE QVariantList getItems(const QString &path);
    // Async pair for the browse view: cachedItems returns the last known
    // listing instantly (in-memory, falling back to the on-disk cache) so the
    // UI can render immediately even when the media lives on a network share
    // or a spun-down disk; loadItems rescans on a worker thread and emits
    // itemsLoaded when fresh data is ready.
    Q_INVOKABLE QVariantList cachedItems(const QString &path);
    Q_INVOKABLE void         loadItems(const QString &path);
    Q_INVOKABLE bool         isImage(const QString &path) const;
    Q_INVOKABLE bool         isPlaylist(const QString &path) const;
    Q_INVOKABLE bool         playlistContainsImages(const QString &path) const;
    Q_INVOKABLE QString      mediaRoot() const;
    Q_INVOKABLE void         setMediaRoot(const QString &path);
    // Settings "Clear Cache" action: drop the listing cache (memory + disk) so
    // the next browse rescans from disk. Invoked by name via invoke_module_action.
    Q_INVOKABLE void         clear_cache();

    Q_INVOKABLE QVariantMap getSavedPosition(const QString &filePath);
    Q_INVOKABLE void        savePosition(const QString &filePath, int positionMs,
                                         int playlistPos, int durationMs = -1);
    Q_INVOKABLE void        clearPosition(const QString &filePath);
    // Detail-view Watched button: mark an item played (drops it from Continue
    // Watching) or unplayed.
    Q_INVOKABLE void        set_watched(const QString &filePath, bool watched);
    Q_INVOKABLE bool        is_watched(const QString &filePath);
    // Detail-view Tracked button: remove from / restore to Continue Watching
    // without changing the resume position.
    Q_INVOKABLE void        set_tracked(const QString &filePath, bool tracked);
    // In-progress items (partially watched, not near-complete), newest first,
    // enriched with artwork/nfo for the Continue Watching grid.
    Q_INVOKABLE QVariantList get_continue_watching();
    // Cheap boolean (no artwork enrichment) for deciding whether to show the
    // Continue Watching row / landing — safe to call on the UI thread.
    Q_INVOKABLE bool         has_continue_watching();

    // Watchlist: an on-device bookmark list (a "watchlisted" flag in the history,
    // keyed by video path). set/is toggle & report it; has_watchlist gates the
    // landing entry; get_watchlist returns the bookmarked items enriched for a grid.
    Q_INVOKABLE void         set_watchlisted(const QString &filePath, bool on);
    Q_INVOKABLE bool         is_watchlisted(const QString &filePath);
    Q_INVOKABLE bool         has_watchlist();
    Q_INVOKABLE QVariantList  get_watchlist();
    // Ordered list of every episode in the show `videoPath` belongs to, across all
    // its season folders — powers PREV/NEXT and finish->next-episode, including
    // crossing from the end of one season into the next. Returns
    // { episodes: [...], index: <current pos>, isSeries: bool }; isSeries is false
    // for a plain movie (episodes = just itself), so callers don't auto-advance it.
    Q_INVOKABLE QVariantMap  series_episodes(const QString &videoPath);
    // Cast & Extras cards for the info screen: the show/movie's nfo actors, plus
    // its bonus videos (Extras/Featurettes/Specials/... folders and -trailer/…
    // named files) as playable "extra" cards. Extras come first, each carrying its
    // "path" so the view can hand it straight to the player.
    Q_INVOKABLE QVariantList get_cast_extras(const QString &videoPath);
    // For each "extra" card without artwork, generate a poster frame with ffmpeg
    // (cached under DATA_ROOT/thumbs), emitting extraThumbReady(path, url) as each
    // finishes so the info screen can fill the card in. No-op without ffmpeg.
    Q_INVOKABLE void         generate_extra_thumbs(const QVariantList &extras);
    Q_INVOKABLE void        get_resume_playback_options();
    Q_INVOKABLE void        get_auto_subtitles_options();
    Q_INVOKABLE void        get_subtitle_languages();
    Q_INVOKABLE void        get_image_duration_options();

    // Probe a video's audio/subtitle tracks with ffprobe (async). Emits
    // tracksReady(path, {audio:[{lang,label}], subtitle:[{lang,label}]}) with the
    // distinct languages present, so the info screen can offer a per-show
    // language choice. Empty map if ffprobe isn't available or the probe fails.
    Q_INVOKABLE void        probe_tracks(const QString &path);

signals:
    void dynamicOptionsReady(const QString &key, const QVariant &options);
    void itemsLoaded(const QString &path, const QVariantList &items);
    void tracksReady(const QString &path, const QVariant &tracks);
    void extraThumbReady(const QString &path, const QString &thumbUrl);

public slots:
    void onSettingChanged(const QString &moduleId, const QString &key, const QVariant &value);

private:
    QString m_appRoot;
    QString m_dataRoot;
    QString m_mediaRoot;

    QString      historyFilePath() const;
    QVariantMap  loadHistory() const;
    void         saveHistory(const QVariantMap &history);

    // Kodi/TinyMediaManager-style artwork + metadata discovery, merged into
    // getItems entries so the views can render posters, fanart, and titles.
    static QString findArtFile(const QDir &dir, const QStringList &baseNames);
    // First image in dir whose base name ends with one of the given suffixes
    // (e.g. "-poster") — for TinyMediaManager sidecars named after the title
    // ("MovieName-poster.jpg") rather than the generic "poster.jpg".
    static QString findSuffixArtFile(const QDir &dir, const QStringList &suffixes);
    static QVariantMap parseNfo(const QString &nfoPath);
    // Walk up from a video's folder (to the media root) for the closest show/
    // season .nfo, so an episode with no metadata of its own can still inherit
    // show-level plot/year/title as a fallback.
    QVariantMap parentNfoMeta(const QDir &startDir) const;
    void enrichFolderItem(QVariantMap &item, const QString &folderPath) const;
    void enrichVideoItem(QVariantMap &item, const QString &filePath) const;
    // Cache path (DATA_ROOT/thumbs/<hash>.jpg) for a generated extra thumbnail,
    // keyed by the file's path + size + mtime so it regenerates if the file changes.
    QString thumbCachePath(const QString &videoPath) const;

    // Smart show/movie folder handling: a "media folder" (one carrying .nfo or
    // scraper artwork) presents as content. Any subfolder that looks like a season
    // OR actually holds video (see folderContainsVideo) is shown as a navigable
    // folder, alongside loose videos at the root; only a folder whose videos are
    // all at its root is flattened. collectVideos gathers videos recursively.
    static bool isSeasonFolder(const QString &name);
    static bool folderHasNfoOrArtwork(const QDir &dir);
    bool folderContainsVideo(const QString &path, int depth) const;
    void collectVideos(const QString &path, QVariantList &out, int depth) const;
    // True if the folder tree holds at least one video and every video in it has
    // been watched (per the given history) — drives the "all played" folder mark.
    bool folderFullyWatched(const QString &path, const QVariantMap &history, int depth) const;
    // Tag each item with a "watched" flag (played video / fully-played folder).
    void enrichWatched(QVariantList &items) const;

    // Listing cache. m_cache mirrors the on-disk file; updateCache persists.
    QString cacheFilePath() const;
    void ensureCacheLoaded();
    void updateCache(const QString &path, const QVariantList &items);
    QVariantList scanItems(const QString &path, const QString &mediaRoot) const;
    // Scan `path` on a worker thread, then update the cache and emit itemsLoaded
    // on the main thread. Shared by loadItems and the folder watcher.
    void rescanAsync(const QString &path);

    QVariantMap m_cache;         // canonical path -> items (QVariantList)
    bool m_cacheLoaded = false;

    // Live folder watch: while the browse view shows a folder, that folder is
    // watched so a video/subfolder added (or removed) in it refreshes the listing
    // without leaving and re-entering. Only the current folder is watched, and
    // rapid bursts (a multi-file copy) are coalesced by a short debounce.
    QFileSystemWatcher *m_watcher        = nullptr;
    QTimer             *m_rescanDebounce = nullptr;
    QString             m_watchedFolder;
};
