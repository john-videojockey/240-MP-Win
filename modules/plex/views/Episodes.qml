import QtQuick
import Components

// Episodes browser for a show: the synopsis on top, then one row per season
// (a "SEASON N" header + a horizontal strip of episode screenshots). UP/DOWN move
// between seasons, LEFT/RIGHT between episodes, ENTER opens an episode's info.
FocusScope {
    id: episodesRoot

    property var navParams: ({})
    signal navigateTo(string path, var params, var listState)
    signal goBack()

    property string showKey:          navParams.showKey || ""
    property string showTitle:        navParams.showTitle || ""
    property string currentRatingKey: navParams.currentRatingKey || ""
    property string summary: ""
    property string art:   navParams.art   || ""
    property string theme: navParams.theme || ""
    property var seasons: []          // [{ season, title, episodes:[...] }]

    property int seasonIdx: 0
    property int epIdx: 0

    property bool showThemes: false
    property int  themeVolume: 50

    focus: true

    function currentEpisodes() { var s = seasons[seasonIdx]; return (s && s.episodes) ? s.episodes : [] }
    function currentEpisode()  { return currentEpisodes()[epIdx] || null }

    Keys.onUpPressed: {
        if (seasonIdx > 0) { seasonIdx--; epIdx = Math.min(epIdx, currentEpisodes().length - 1) }
    }
    Keys.onDownPressed: {
        if (seasonIdx < seasons.length - 1) { seasonIdx++; epIdx = Math.min(epIdx, currentEpisodes().length - 1) }
    }
    Keys.onLeftPressed:  { if (epIdx > 0) epIdx-- }
    Keys.onRightPressed: { if (epIdx < currentEpisodes().length - 1) epIdx++ }
    Keys.onReturnPressed: {
        var ep = currentEpisode()
        if (ep) navigateTo("Item.qml", { item: ep }, { seasonIdx: seasonIdx, epIdx: epIdx })
    }
    Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
            goBack(); event.accepted = true
        }
    }

    // Fanart background + scanlines (opaque base so it dims toward the theme color).
    Rectangle { anchors.fill: parent; z: -2; visible: fanart.visible; color: root.surfaceColor }
    Image {
        id: fanart
        anchors.fill: parent
        z: -1
        visible: art !== "" && status === Image.Ready
        opacity: 0.3
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        source: art ? plexBackend.image_url(art, Math.round(width), Math.round(height)) : ""
    }
    Image {
        anchors.fill: parent; z: -1
        visible: fanart.visible
        fillMode: Image.Tile
        opacity: 0.6
        source: "../../../assets/images/scanlines.png"
    }

    AppBar {
        iconSource: moduleRoot.moduleIcon
        title: episodesRoot.showTitle
        subtitle: "EPISODES"
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.125
        anchors.leftMargin: root.sw * 0.125
    }

    // Synopsis — up to three whole lines; longer text auto-scrolls (by whole
    // lines, so a partial line is never left clipped) to stay readable hands-free,
    // mirroring the info screen's summary.
    Item {
        id: synopsis
        visible: synopsisText.text !== ""
        anchors.top: parent.top
        anchors.topMargin: root.sh * 0.235
        anchors.left: parent.left
        anchors.leftMargin: root.sw * 0.125
        width: root.sw * 0.75
        // Snap the viewport to a whole number of lines: derive the per-line height
        // from the laid-out text and cap at three lines. This makes the scroll step
        // line by line instead of nudging by the ~5% sliver a fixed pixel cap left.
        property real lineH: synopsisText.lineCount > 0
                             ? synopsisText.contentHeight / synopsisText.lineCount
                             : synopsisText.font.pixelSize * 1.3
        height: Math.min(3, synopsisText.lineCount) * lineH
        clip: true

        Text {
            id: synopsisText
            width: parent.width
            text: episodesRoot.summary
            color: root.secondaryColor
            font.family: root.globalFont
            wrapMode: Text.WordWrap
            font.pixelSize: root.sh * 0.0291667
        }

        SequentialAnimation {
            running: synopsisText.lineCount > 3
            loops: Animation.Infinite
            onRunningChanged: if (!running) synopsisText.y = 0
            PauseAnimation { duration: 3000 }
            NumberAnimation {
                target: synopsisText; property: "y"
                to: synopsis.height - synopsisText.contentHeight
                duration: Math.abs(to) * 120
            }
            PauseAnimation { duration: 4000 }
            PropertyAction { target: synopsisText; property: "y"; value: 0 }
        }
    }

    // Season rows
    ListView {
        id: seasonList
        model: episodesRoot.seasons
        anchors.top: synopsis.visible ? synopsis.bottom : synopsis.top
        anchors.topMargin: root.sh * 0.03
        anchors.left: parent.left
        anchors.leftMargin: root.sw * 0.125
        width: root.sw * 0.8
        anchors.bottom: parent.bottom
        anchors.bottomMargin: root.sh * 0.14
        clip: true
        spacing: root.sh * 0.02
        currentIndex: episodesRoot.seasonIdx
        preferredHighlightBegin: 0
        preferredHighlightEnd: height * 0.6
        highlightRangeMode: ListView.ApplyRange
        onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)

        delegate: Item {
            id: seasonDelegate
            width: seasonList.width
            height: seasonLabel.height + root.sh * 0.008 + epRow.height
            property int  seasonRowIndex:  index
            property bool isCurrentSeason: episodesRoot.seasonIdx === index

            Text {
                id: seasonLabel
                text: (modelData.title || ("SEASON " + modelData.season))
                      + ((modelData.year || 0) > 0 ? " (" + modelData.year + ")" : "")
                color: seasonDelegate.isCurrentSeason ? root.accentColor : root.secondaryColor
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                anchors.top: parent.top
                anchors.left: parent.left
                font.pixelSize: root.sh * 0.03
            }

            ListView {
                id: epRow
                model: modelData.episodes
                orientation: ListView.Horizontal
                anchors.top: seasonLabel.bottom
                anchors.topMargin: root.sh * 0.008
                anchors.left: parent.left
                anchors.right: parent.right
                height: root.sh * 0.205
                spacing: root.sw * 0.0125
                clip: true
                interactive: true
                flickableDirection: Flickable.HorizontalFlick
                currentIndex: seasonDelegate.isCurrentSeason ? episodesRoot.epIdx : -1
                onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)

                delegate: Item {
                    id: epDelegate
                    height: epRow.height
                    width: shotBox.width           // 16:9 screenshot governs the card
                    property bool sel: seasonDelegate.isCurrentSeason && episodesRoot.epIdx === index

                    Column {
                        anchors.fill: parent
                        spacing: root.sh * 0.006

                        Rectangle {
                            id: shotBox
                            height: epRow.height - epTitle.height - root.sh * 0.006
                            width: height * (16 / 9)
                            color: "transparent"
                            border.color: epDelegate.sel ? root.accentColor : root.tertiaryColor
                            border.width: epDelegate.sel ? Math.max(2, Math.floor(root.sh * 0.00625)) : 1

                            Image {
                                id: shot
                                anchors.fill: parent
                                anchors.margins: shotBox.border.width
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                source: modelData.thumb
                                        ? plexBackend.image_url(modelData.thumb, Math.round(width), Math.round(height))
                                        : ""
                            }
                            // Episode number, bottom-left.
                            Text {
                                text: "E" + (modelData.index != null ? modelData.index : "?")
                                color: root.primaryColor
                                font.family: root.globalFont
                                anchors.left: parent.left
                                anchors.bottom: parent.bottom
                                anchors.margins: root.sh * 0.008
                                font.pixelSize: root.sh * 0.0233333
                            }
                            // Watched check, top-right.
                            Rectangle {
                                visible: (modelData.viewCount || 0) > 0
                                width: root.sh * 0.026; height: width; radius: width / 2
                                color: root.accentColor
                                anchors.top: parent.top
                                anchors.right: parent.right
                                anchors.margins: root.sh * 0.008
                                Text {
                                    anchors.centerIn: parent
                                    text: "✓"; color: root.surfaceColor
                                    font.family: root.globalFont
                                    font.pixelSize: parent.height * 0.7
                                }
                            }
                        }
                        MarqueeText {
                            id: epTitle
                            width: shotBox.width
                            text: modelData.title || ""
                            color: epDelegate.sel ? root.accentColor : root.primaryColor
                            pixelSize: root.sh * 0.0208333
                            active: epDelegate.sel
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: {
                            if (seasonDelegate.isCurrentSeason && episodesRoot.epIdx === index)
                                inputManager.touchKey("select")
                            else {
                                episodesRoot.seasonIdx = seasonDelegate.seasonRowIndex
                                episodesRoot.epIdx = index
                            }
                        }
                    }
                }
            }
        }
    }

    // Footer
    Text {
        text: root.hints.back + ":BACK " + root.hints.navigate + ":SEASON "
              + root.hints.browse + ":EPISODE " + root.hints.select + ":OPEN"
        color: root.tertiaryColor
        font.family: root.globalFont
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.bottomMargin: root.sh * 0.1041667
        anchors.leftMargin: root.sw * 0.125
        font.pixelSize: root.sh * 0.0333333
    }

    Connections {
        target: plexBackend
        function onShowEpisodesReady(sk, data) {
            if (String(sk) !== String(episodesRoot.showKey)) return
            if (data.title)   episodesRoot.showTitle = data.title
            episodesRoot.summary = data.summary || ""
            if (data.art)   episodesRoot.art   = data.art
            if (data.theme) episodesRoot.theme = data.theme
            episodesRoot.seasons = data.seasons || []
            // Land on the episode we came from, if any.
            if (episodesRoot.currentRatingKey) {
                for (var si = 0; si < episodesRoot.seasons.length; si++) {
                    var eps = episodesRoot.seasons[si].episodes || []
                    for (var ei = 0; ei < eps.length; ei++) {
                        if (String(eps[ei].ratingKey) === String(episodesRoot.currentRatingKey)) {
                            episodesRoot.seasonIdx = si; episodesRoot.epIdx = ei; return
                        }
                    }
                }
            }
        }
    }

    Component.onCompleted: {
        if (showKey) plexBackend.load_show_episodes(showKey)
        var stv = appCore.get_setting(moduleRoot.moduleId, "show_themes")
        showThemes = (stv === true || stv === "ON")
        var tv = parseInt(appCore.get_setting(moduleRoot.moduleId, "theme_volume"))
        if (tv > 0) themeVolume = tv
        if (showThemes && theme) plexBackend.play_theme(theme, themeVolume)
    }
    // Keep the theme playing when returning to the info screen (which resumes it).
    Component.onDestruction: plexBackend.stop_theme_deferred()
}
