#pragma once
#include <QObject>
#include <QVariant>
#include <QVariantList>
#include <QVariantMap>

class QDir;

class LocalFilesBackend : public QObject {
    Q_OBJECT
public:
    explicit LocalFilesBackend(const QString &appRoot, const QString &dataRoot, QObject *parent = nullptr);

    Q_INVOKABLE QVariantList getItems(const QString &path);
    Q_INVOKABLE bool         isImage(const QString &path) const;
    Q_INVOKABLE bool         isPlaylist(const QString &path) const;
    Q_INVOKABLE bool         playlistContainsImages(const QString &path) const;
    Q_INVOKABLE QString      mediaRoot() const;
    Q_INVOKABLE void         setMediaRoot(const QString &path);

    Q_INVOKABLE QVariantMap getSavedPosition(const QString &filePath);
    Q_INVOKABLE void        savePosition(const QString &filePath, int positionMs, int playlistPos);
    Q_INVOKABLE void        clearPosition(const QString &filePath);
    Q_INVOKABLE void        get_resume_playback_options();
    Q_INVOKABLE void        get_auto_subtitles_options();
    Q_INVOKABLE void        get_subtitle_languages();
    Q_INVOKABLE void        get_image_duration_options();

signals:
    void dynamicOptionsReady(const QString &key, const QVariant &options);

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
    static QVariantMap parseNfo(const QString &nfoPath);
    void enrichFolderItem(QVariantMap &item, const QString &folderPath) const;
    void enrichVideoItem(QVariantMap &item, const QString &filePath) const;
};
