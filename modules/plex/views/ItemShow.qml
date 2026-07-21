import QtQuick
import Components

FocusScope {
    id: showRoot

    property var navParams: ({})

    signal navigateTo(string path, var params, var listState)
    signal goBack()

    property var item: navParams.item || {}
    property string libraryName: navParams.libraryName || ""

    property var seasons: []
    property bool isLoading: false

    // Focus rows: 0 = play button, 1 = season list
    property int focusRow: 0
    // Row-0 columns: 0 = PLAY/RSUM, 1 = WATCHLIST bookmark (shown when the show has
    // a plex:// GUID — new Plex agent). onWatchlist drives the filled/outline glyph.
    property int  playCol: 0
    property string watchlistGuid: item.guid || ""
    property bool watchlistAvailable: watchlistGuid.indexOf("plex://") === 0
    property bool onWatchlist: false
    property bool watchlistBusy: false

    onFocusRowChanged: if (focusRow === 0) playCol = 0

    function toggleWatchlist() {
        if (!watchlistAvailable || watchlistBusy) return
        watchlistBusy = true
        onWatchlist = !onWatchlist            // optimistic; reverted on failure
        plexBackend.set_watchlist(watchlistGuid, onWatchlist)
    }

    // When true, the next childrenLoaded signal carries episodes to play, not seasons to display
    property bool playOnLoad: false
    property bool waitingForOnDeck: false

    Connections {
        target: plexBackend

        function onWatchlistStateReady(guid, on) {
            if (guid === showRoot.watchlistGuid) {
                showRoot.onWatchlist = on
                showRoot.watchlistBusy = false
            }
        }

        function onChildrenLoaded(loadedItems) {
            if (showRoot.playOnLoad) {
                showRoot.playOnLoad = false
                showRoot.playBestEpisodeFromList(loadedItems)
            } else {
                showRoot.isLoading = false
                showRoot.seasons = loadedItems
                if (loadedItems.length > 0) seasonList.currentIndex = 0
            }
        }

        function onInProgressEpisodeLoaded(episodeItem) {
            if (!showRoot.waitingForOnDeck) return
            showRoot.waitingForOnDeck = false
            if (episodeItem && episodeItem.ratingKey) {
                // Found an in-progress episode — RSUM it directly
                showRoot.navigateTo("Item.qml", { item: episodeItem, libraryName: showRoot.libraryName }, {})
            } else {
                // No in-progress episode — fall back to first-unwatched logic
                showRoot.startPlayFallback()
            }
        }

        function onErrorOccurred(msg) {
            showRoot.isLoading = false
            showRoot.playOnLoad = false
            showRoot.waitingForOnDeck = false
            console.log("[ShowItem] Error: " + msg)
        }
    }

    function startPlayFallback() {
        if (seasons.length === 0) return
        var targetSeason = null
        for (var i = 0; i < seasons.length; i++) {
            if (seasons[i].viewedLeafCount < seasons[i].leafCount) {
                targetSeason = seasons[i]; break
            }
        }
        if (!targetSeason) targetSeason = seasons[0]
        showRoot.playOnLoad = true
        plexBackend.load_children(targetSeason.ratingKey)
    }

    function playBestEpisodeFromList(epList) {
        if (epList.length === 0) return
        var target = null
        for (var i = 0; i < epList.length; i++) {
            if (epList[i].viewOffset > 0) { target = epList[i]; break }
        }
        if (!target) {
            for (var j = 0; j < epList.length; j++) {
                if (!epList[j].viewCount || epList[j].viewCount === 0) { target = epList[j]; break }
            }
        }
        if (!target) target = epList[0]
        showRoot.navigateTo("Item.qml", { item: target, libraryName: libraryName }, {})
    }

    // Fanart background (shared module settings with the info screen)
    property bool infoBg: true
    property real infoBgOpacity: 0.3

    Component.onCompleted: {
        isLoading = true
        focusRow = 0
        if (item.ratingKey) plexBackend.load_children(item.ratingKey)
        if (watchlistAvailable) { watchlistBusy = true; plexBackend.check_watchlist(watchlistGuid) }

        var bg = appCore.get_setting(moduleRoot.moduleId, "info_background")
        infoBg = (bg === undefined || bg === null || bg === "")
                 ? true : (bg === true || bg === "ON")
        var op = parseInt(appCore.get_setting(moduleRoot.moduleId, "info_background_opacity"))
        if (op > 0) infoBgOpacity = op / 100
    }

    focus: true

    Keys.onUpPressed: {
        if (focusRow === 1) {
            if (seasonList.currentIndex > 0) {
                seasonList.currentIndex--
            } else {
                focusRow = 0
            }
        }
    }
    Keys.onDownPressed: {
        if (focusRow === 0) {
            if (seasons.length > 0) focusRow = 1
        } else {
            if (seasonList.currentIndex < seasons.length - 1)
                seasonList.currentIndex++
        }
    }
    Keys.onLeftPressed:  { if (focusRow === 0 && playCol > 0) playCol-- }
    Keys.onRightPressed: { if (focusRow === 0 && playCol < 1 && watchlistAvailable) playCol++ }
    Keys.onReturnPressed: {
        if (focusRow === 0) {
            if (playCol === 1 && watchlistAvailable) { showRoot.toggleWatchlist(); return }
            if (seasons.length === 0) return
            showRoot.waitingForOnDeck = true
            plexBackend.load_on_deck_for(item.ratingKey)
        } else {
            var season = seasons[seasonList.currentIndex]
            if (!season) return
            showRoot.navigateTo("ItemSeason.qml", {
                item: season,
                showTitle: item.title,
                libraryName: libraryName
            }, { currentIndex: seasonList.currentIndex })
        }
    }
    Keys.onPressed: function(event) {
        // PgUp/PgDown page the season list a screenful at a time (only while it
        // holds the highlight), cursor kept in place.
        if (focusRow === 1 && event.key === Qt.Key_PageDown) { NavUtil.page(seasonList, 1); event.accepted = true; return }
        if (focusRow === 1 && event.key === Qt.Key_PageUp) { NavUtil.page(seasonList, -1); event.accepted = true; return }
        if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
            goBack()
            event.accepted = true
        }
    }

    // ---
    // UI
    // ---

    // Show fanart behind the seasons screen — same treatment as the info screen.
    // Opaque base beneath it so the fanart dims toward the theme surface color, not
    // the app background bleeding through the semi-transparent fanart.
    Rectangle {
        anchors.fill: parent
        z: -2
        visible: fanart.visible
        color: root.surfaceColor
    }
    Image {
        id: fanart
        anchors.fill: parent
        z: -1
        visible: showRoot.infoBg && status === Image.Ready
        opacity: showRoot.infoBgOpacity
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        source: (showRoot.infoBg && item.art)
                ? plexBackend.image_url(item.art, Math.round(root.sw), Math.round(root.sh))
                : ""
    }
    Image {
        anchors.fill: parent
        z: -1
        visible: fanart.visible
        fillMode: Image.Tile
        source: "../../../assets/images/scanlines.png"
        opacity: 0.6
    }

    AppBar {
        iconSource: moduleRoot.moduleIcon
        title: moduleRoot.moduleName
        subtitle: libraryName
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.125 //60
        anchors.leftMargin: root.sw * 0.125 //80
    }

    LoadingText {
        visible: isLoading
        anchors.centerIn: parent
    }

    Item {
        visible: !isLoading
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.25 //120
        anchors.leftMargin: root.sw * 0.115625 //74
        width: root.sw * 0.76875 //492
        height: root.sh * 0.525 //252
        clip: true

        Row {
            id: showDetails
            height: root.sh * 0.2916667 //140
            spacing: root.sw * 0.0375 //24

            // PLAY / RSUM + Watchlist bookmark (row-0 columns).
            Row {
                spacing: root.sw * 0.0046875 //3

                // PLAY / RSUM button
                Rectangle {
                    id: playButton
                    property bool sel: focusRow === 0 && showRoot.playCol === 0
                    color: sel ? root.accentColor : root.surfaceColor
                    border.color: sel ? root.accentColor : root.tertiaryColor
                    width: root.sw * 0.1875 //120
                    height: root.sh * 0.1166667 //56
                    border.width: root.sh * 0.003125 //2

                    // Touch: first tap focuses the PLAY button, tapping it while focused
                    // activates it via a synthesized Enter (same path as the keyboard).
                    MouseArea {
                        anchors.fill: parent
                        onClicked: {
                            if (playButton.sel) inputManager.touchKey("select")
                            else { focusRow = 0; showRoot.playCol = 0 }
                        }
                    }

                    Text {
                        anchors.centerIn: parent
                        text: (item.viewOffset && item.viewOffset > 0) ? "RSUM \u25BA" : "PLAY \u25BA"
                        color: playButton.sel ? root.surfaceColor : root.primaryColor
                        font.family: root.globalFont
                        font.pixelSize: root.sh * 0.05 //24
                    }
                }

                // Watchlist bookmark toggle.
                Rectangle {
                    id: watchlistBtn
                    visible: showRoot.watchlistAvailable
                    property bool sel: focusRow === 0 && showRoot.playCol === 1
                    width: root.sw * 0.05
                    height: root.sh * 0.1166667 //56
                    color: sel ? root.accentColor : root.surfaceColor
                    border.color: sel ? root.accentColor : root.tertiaryColor
                    border.width: root.sh * 0.003125 //2

                    MouseArea {
                        anchors.fill: parent
                        onClicked: { if (watchlistBtn.sel) showRoot.toggleWatchlist()
                                     else { focusRow = 0; showRoot.playCol = 1 } }
                    }
                    // Bookmark glyph: outline when not on the watchlist, filled when on it.
                    Canvas {
                        id: bookmark
                        anchors.centerIn: parent
                        width: parent.width * 0.34
                        height: parent.height * 0.42
                        property bool filled: showRoot.onWatchlist
                        property color col: watchlistBtn.sel ? root.surfaceColor : root.accentColor
                        onFilledChanged: requestPaint()
                        onColChanged: requestPaint()
                        onWidthChanged: requestPaint()
                        onHeightChanged: requestPaint()
                        onPaint: {
                            var ctx = getContext("2d")
                            ctx.reset()
                            var w = width, h = height
                            var lw = Math.max(1.5, w * 0.16)
                            var notch = h * 0.26
                            var x0 = lw / 2, y0 = lw / 2, x1 = w - lw / 2, y1 = h - lw / 2
                            ctx.beginPath()
                            ctx.moveTo(x0, y0)
                            ctx.lineTo(x1, y0)
                            ctx.lineTo(x1, y1)
                            ctx.lineTo(w / 2, y1 - notch)
                            ctx.lineTo(x0, y1)
                            ctx.closePath()
                            if (filled) { ctx.fillStyle = col; ctx.fill() }
                            else { ctx.strokeStyle = col; ctx.lineWidth = lw
                                   ctx.lineJoin = "round"; ctx.stroke() }
                        }
                    }
                }
            }

            Column {
                topPadding: root.sh * 0.0083333 //4
                width: root.sw * 0.54375 //348
                spacing: root.sh * 0.0166667 //8

                //Name
                Text {
                    text: item.title || ""
                    color: root.primaryColor
                    font.family: root.globalFont
                    font.capitalization: Font.AllUppercase
                    elide: Text.ElideRight
                    width: parent.width
                    font.pixelSize: root.sh * 0.05 //24
                }

                // Seasons & Year
                Text {
                    text: {
                        var parts = []
                        var sc = seasons.length
                        if (item.year) parts.push(String(item.year))
                        if (sc > 0) parts.push(sc + (sc === 1 ? " SEASON" : " SEASONS"))
                        return parts.join(" - ")
                    }
                    color: root.secondaryColor
                    font.family: root.globalFont
                    font.capitalization: Font.AllUppercase
                    elide: Text.ElideRight
                    width: parent.width
                    font.pixelSize: root.sh * 0.0333333 //16
                }

                Item {
                    id: summaryContainer
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: root.sh * 0.1375 //66
                    clip: true

                    Text {
                        id: summaryText
                        anchors.left: parent.left
                        anchors.right: parent.right
                        text: item.summary || ""
                        color: root.primaryColor
                        font.family: root.globalFont
                        wrapMode: Text.WordWrap
                        font.pixelSize: root.sh * 0.0291667 //14
                        lineHeight: 1.3
                    }

                    SequentialAnimation {
                        running: item.summary !== null && summaryText.implicitHeight > summaryContainer.height
                        loops: Animation.Infinite
                        onRunningChanged: if (!running) summaryText.y = 0
                        PauseAnimation { duration: 3000 }
                        NumberAnimation {
                            target: summaryText; property: "y"
                            to: summaryContainer.height - summaryText.implicitHeight
                            duration: Math.abs(to) * 120
                        }
                        PauseAnimation { duration: 4000 }
                        PropertyAction { target: summaryText; property: "y"; value: 0 }
                    }
                }
            }
        }

        // Seasons
        Text {
            id: seasonListLabel
            anchors.top: showDetails.bottom
            text: "Seasons:"
            color: root.secondaryColor
            font.family: root.globalFont
            font.capitalization: Font.AllUppercase
            anchors.topMargin: root.sh * 0.0145833 //7
            leftPadding: root.sw * 0.009375 //6;
            rightPadding: root.sw * 0.009375 //6;
            font.pixelSize: root.sh * 0.0291667 //14
        }

        // Season List
        ListView {
            id: seasonList
            model: seasons
            anchors.top: seasonListLabel.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.topMargin: root.sh * 0.0145833 //7
            height: root.sh * 0.175 //84
            clip: true

            delegate: Item {
                width: seasonList.width
                height: root.sh * 0.0583333 //28

                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        if (focusRow === 1 && seasonList.currentIndex === index) {
                            inputManager.touchKey("select")
                        } else {
                            focusRow = 1
                            seasonList.currentIndex = index
                        }
                    }
                }

                Item {
                    id: textClip
                    width: Math.min(rowText.implicitWidth, seasonList.width)
                    height: parent.height
                    clip: true

                    Rectangle {
                        color: root.accentColor
                        anchors.fill: rowText
                        visible: seasonList.currentIndex === index && focusRow === 1
                    }

                    Text {
                        id: rowText
                        text: modelData.title || ""
                        color: (seasonList.currentIndex === index && focusRow === 1)
                               ? root.surfaceColor : root.primaryColor
                        font.family: root.globalFont
                        font.capitalization: Font.AllUppercase
                        anchors.verticalCenter: parent.verticalCenter
                        x: 0
                        topPadding: root.sh * 0.0041667 //2
                        leftPadding: root.sw * 0.009375 //6
                        rightPadding: root.sw * 0.009375 //6
                        bottomPadding: root.sh * 0.00625 //3
                        font.pixelSize: root.sh * 0.05 //24
                    }

                    SequentialAnimation {
                        running: (seasonList.currentIndex === index) &&
                                 (focusRow === 1) &&
                                 (rowText.implicitWidth > textClip.width)
                        loops: Animation.Infinite
                        onRunningChanged: if (!running) rowText.x = 0
                        PauseAnimation { duration: 1500 }
                        NumberAnimation {
                            target: rowText; property: "x"
                            to: textClip.width - rowText.implicitWidth
                            duration: Math.abs(to) * 20
                        }
                        PauseAnimation { duration: 2000 }
                        PropertyAction { target: rowText; property: "x"; value: 0 }
                    }
                }
            }
        }
    }

    // Footer
    Text {
        id: footer
        text: root.hints.back + ":BACK " + root.hints.navigate + ":NAVIGATE " + root.hints.select + ":SELECT"
        color: root.tertiaryColor
        font.family: root.globalFont
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.bottomMargin: root.sh * 0.1041667 //50
        anchors.leftMargin: root.sw * 0.125 //80
        font.pixelSize: root.sh * 0.0333333 //16
    }
}
