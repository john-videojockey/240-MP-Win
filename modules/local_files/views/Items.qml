import QtQuick
import Components

FocusScope {
    id: itemsRoot

    property var navParams: ({})
    property var navListState: navParams.navListState || ({})
    property string folderPath: navParams.folderPath || localFilesBackend.mediaRoot()
    property string folderName: navParams.folderName || ""

    signal navigateTo(string path, var params, var listState)
    signal goBack()

    property var items: []
    property bool isLoading: false
    // Guards the first-load index restore against the silent cache refresh.
    property bool loadedOnce: false

    // Browse View setting: "Cover" renders the folder as an art grid when the
    // backend found any artwork (poster.jpg/folder.jpg in subfolders,
    // TinyMediaManager "-poster"/"-thumb" sidecars, …). Folders with episode
    // nfo metadata use landscape 16:9 cards, matching the Plex module.
    property string browseView: (appCore.get_setting(moduleRoot.moduleId, "browse_view") || "Title")
    property bool coverMode: browseView === "Cover" && items.length > 0 && anyArt(items)
    property bool gridLandscape: coverMode && anyEpisodes(items)

    // Fanart hover background (shared module settings with the detail screen)
    property bool infoBg: true
    property real infoBgOpacity: 0.3

    function anyArt(arr) {
        for (var i = 0; i < arr.length; i++) {
            if (arr[i].thumb) return true
        }
        return false
    }

    function anyEpisodes(arr) {
        for (var i = 0; i < arr.length; i++) {
            if (arr[i].episode > 0) return true
        }
        return false
    }

    function displayTitle(it) {
        if (!it) return ""
        return it.title || it.name || ""
    }

    function isVideoFile(it) {
        return it && !it.isFolder
               && !localFilesBackend.isImage(it.path)
               && !localFilesBackend.isPlaylist(it.path)
    }

    function currentItem() {
        return items[coverMode ? coverGrid.currentIndex : fileList.currentIndex]
    }

    // Shared activation for both views: folders drill in, videos open the
    // detail screen, images and playlists keep their direct hand-off to mpv.
    function selectCurrent() {
        var idx = coverMode ? coverGrid.currentIndex : fileList.currentIndex
        var item = items[idx]
        if (!item) return
        if (item.isFolder) {
            navigateTo("Items.qml",
                { folderPath: item.path, folderName: item.name },
                { currentIndex: idx })
        } else if (isVideoFile(item)) {
            navigateTo("Detail.qml",
                { items: items, index: idx, folderName: folderName },
                { currentIndex: idx })
        } else {
            navigateTo("Player.qml",
                { filePath: item.path, title: item.name },
                { currentIndex: idx })
        }
    }

    focus: true
    Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
            goBack()
            event.accepted = true
        }
    }

    // ---
    // UI
    // ---

    // Hover fanart: the highlighted item's background art, debounced so
    // scrolling doesn't load an image per step. Same treatment and settings
    // as the Plex module.
    Timer {
        id: hoverArtDebounce
        interval: 250
        repeat: false
        onTriggered: {
            var it = itemsRoot.currentItem()
            hoverArt.source = (itemsRoot.infoBg && it && it.art) ? it.art : ""
        }
    }
    Connections {
        target: fileList
        function onCurrentIndexChanged() { if (itemsRoot.infoBg) hoverArtDebounce.restart() }
    }
    Connections {
        target: coverGrid
        function onCurrentIndexChanged() { if (itemsRoot.infoBg) hoverArtDebounce.restart() }
    }

    // Opaque base under the hover fanart so it dims toward the theme color, not
    // the app background bleeding through it. Fades in/out with the fanart.
    Rectangle {
        anchors.fill: parent
        z: -2
        color: root.surfaceColor
        opacity: hoverArt.opacity > 0 ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 200 } }
    }
    Image {
        id: hoverArt
        anchors.fill: parent
        z: -1
        visible: opacity > 0
        opacity: (itemsRoot.infoBg && status === Image.Ready) ? itemsRoot.infoBgOpacity : 0
        Behavior on opacity { NumberAnimation { duration: 200 } }
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
    }
    Image {
        anchors.fill: parent
        z: -1
        visible: hoverArt.visible
        opacity: Math.min(1, hoverArt.opacity * 2)
        fillMode: Image.Tile
        source: "../../../assets/images/scanlines.png"
    }

    // Header
    AppBar {
        iconSource: moduleRoot.moduleIcon
        title: moduleRoot.moduleName
        subtitle: folderName !== "" ? folderName : ""
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.125 //60
        anchors.leftMargin: root.sw * 0.125 //80
    }

    // Browser-pane loading splash (animated dots) — shown while the first
    // scan of an uncached folder is running.
    LoadingText {
        visible: itemsRoot.isLoading
        anchors.centerIn: parent
    }

    // Empty state
    Column {
        anchors.centerIn: parent
        spacing: root.sh * 0.0333333 //16
        visible: !itemsRoot.isLoading && items.length === 0
        Text {
            text: "No items found"
            color: root.secondaryColor
            font.family: root.globalFont
            font.capitalization: Font.AllUppercase
            horizontalAlignment: Text.AlignHCenter
            anchors.horizontalCenter: parent.horizontalCenter
            font.pixelSize: root.sh * 0.05 //24
        }
        Text {
            text: "Please add items in the local files media directory"
            color: root.tertiaryColor
            font.family: root.globalFont
            font.capitalization: Font.AllUppercase
            horizontalAlignment: Text.AlignHCenter
            anchors.horizontalCenter: parent.horizontalCenter
            font.pixelSize: root.sh * 0.0333333 //16
        }
    }

    // ── Cover browse view ─────────────────────────────────────────────
    Text {
        visible: coverMode
        text: itemsRoot.displayTitle(items[coverGrid.currentIndex])
              + ((items[coverGrid.currentIndex] || {}).isFolder ? "/" : "")
        color: root.primaryColor
        font.family: root.globalFont
        font.capitalization: Font.AllUppercase
        elide: Text.ElideRight
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.1875 //90
        anchors.leftMargin: root.sw * 0.125 //80
        width: root.sw * 0.75
        font.pixelSize: root.sh * 0.05 //24
    }

    GridView {
        id: coverGrid
        model: items
        visible: coverMode
        focus: coverMode
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.25 //120
        anchors.leftMargin: root.sw * 0.115625 //74
        width: root.sw * 0.76875 //492
        height: root.sh * 0.525 //252
        clip: true

        property real posterH: root.sh * 0.245
        property real posterW: posterH * (itemsRoot.gridLandscape ? 16 / 9 : 2 / 3)
        cellHeight: root.sh * 0.2625
        cellWidth: posterW + root.sw * 0.0078125 //5

        Keys.onReturnPressed: itemsRoot.selectCurrent()
        Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                itemsRoot.goBack()
                event.accepted = true
            }
        }

        delegate: Item {
            width: coverGrid.cellWidth
            height: coverGrid.cellHeight

            MouseArea {
                anchors.fill: parent
                onClicked: {
                    if (coverGrid.currentIndex === index) inputManager.touchKey("select")
                    else coverGrid.currentIndex = index
                }
            }

            Rectangle {
                id: posterBox
                width: coverGrid.posterW
                height: coverGrid.posterH
                color: "transparent"
                border.color: coverGrid.currentIndex === index ? root.accentColor : root.tertiaryColor
                border.width: coverGrid.currentIndex === index
                              ? Math.max(2, Math.floor(root.sh * 0.00625)) : 1

                Image {
                    id: posterImage
                    anchors.fill: parent
                    anchors.margins: posterBox.border.width
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    source: modelData.thumb || ""
                }

                Text {
                    visible: posterImage.status !== Image.Ready
                    anchors.fill: parent
                    anchors.margins: root.sw * 0.0078125 //5
                    text: itemsRoot.displayTitle(modelData) + (modelData.isFolder ? "/" : "")
                    color: coverGrid.currentIndex === index ? root.accentColor : root.secondaryColor
                    font.family: root.globalFont
                    font.capitalization: Font.AllUppercase
                    wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    elide: Text.ElideRight
                    font.pixelSize: root.sh * 0.0291667 //14
                }
            }
        }
    }

    // File list
    ListView {
        id: fileList
        model: items
        visible: !coverMode
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.25 //120
        anchors.leftMargin: root.sw * 0.115625 //74
        width: root.sw * 0.76875 //492
        height: root.sh * 0.525 //252
        clip: true
        focus: !coverMode

        // Explicit single-step nav (snappier than ListView's built-in
        // keyNavigation) plus PgUp/PgDown paging that keeps the cursor put.
        Keys.onUpPressed: if (currentIndex > 0) currentIndex--
        Keys.onDownPressed: if (currentIndex < count - 1) currentIndex++
        Keys.onReturnPressed: itemsRoot.selectCurrent()
        Keys.onPressed: function(event) {
            if (event.key === Qt.Key_PageDown) { NavUtil.page(fileList, 1); event.accepted = true }
            else if (event.key === Qt.Key_PageUp) { NavUtil.page(fileList, -1); event.accepted = true }
        }

        delegate: Item {
            width: fileList.width
            height: root.sh * 0.0583333 //28

            // Touch: first tap highlights the row, tapping the highlighted row
            // activates it via a synthesized Enter (same path as the keyboard).
            MouseArea {
                anchors.fill: parent
                onClicked: {
                    if (fileList.currentIndex === index) inputManager.touchKey("select")
                    else fileList.currentIndex = index
                }
            }

            Item {
                id: textClip
                width: Math.min(rowText.implicitWidth, fileList.width)
                height: parent.height
                clip: true

                Rectangle {
                    color: root.accentColor
                    anchors.fill: rowText
                    visible: fileList.currentIndex === index
                }

                Text {
                    id: rowText
                    text: itemsRoot.displayTitle(modelData) + (modelData.isFolder ? "/" : "")
                    color: fileList.currentIndex === index ? root.surfaceColor : root.primaryColor
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
                    running: (fileList.currentIndex === index) &&
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

    function applyItems(loaded, restoreIndex) {
        items = loaded
        if (items.length > 0) {
            var idx = Math.min(Math.max(0, restoreIndex), items.length - 1)
            fileList.currentIndex = idx
            fileList.positionViewAtIndex(idx, ListView.Contain)
            coverGrid.currentIndex = idx
            coverGrid.positionViewAtIndex(idx, GridView.Contain)
        }
        if (coverMode) coverGrid.forceActiveFocus()
        else fileList.forceActiveFocus()
        if (infoBg) hoverArtDebounce.restart()
    }

    // Fresh scan finished on the backend's worker thread. First entry into an
    // uncached folder clears the LOADING splash; when the cache was already
    // on screen this is the silent refresh, applied only if something actually
    // changed (keeping the user's highlight position).
    Connections {
        target: localFilesBackend
        function onItemsLoaded(path, loaded) {
            if (path !== folderPath) return
            isLoading = false
            if (!loadedOnce) {
                loadedOnce = true
                var restore = (navListState.currentIndex !== undefined) ? navListState.currentIndex : 0
                applyItems(loaded, restore)
                return
            }
            if (JSON.stringify(loaded) === JSON.stringify(items)) return
            applyItems(loaded, coverMode ? coverGrid.currentIndex : fileList.currentIndex)
        }
    }

    Component.onCompleted: {
        var bg = appCore.get_setting(moduleRoot.moduleId, "info_background")
        infoBg = (bg === undefined || bg === null || bg === "")
                 ? true : (bg === true || bg === "ON")
        var op = parseInt(appCore.get_setting(moduleRoot.moduleId, "info_background_opacity"))
        if (op > 0) infoBgOpacity = op / 100

        // Show the last known listing instantly (network shares and sleeping
        // disks can take seconds to answer), then refresh in the background.
        // No cache yet → LOADING splash until the scan lands.
        folderPath = String(folderPath)   // detach from navParams binding
        var cached = localFilesBackend.cachedItems(folderPath)
        if (cached.length > 0) {
            loadedOnce = true
            var restore = (navListState.currentIndex !== undefined) ? navListState.currentIndex : 0
            applyItems(cached, restore)
        } else {
            isLoading = true
        }
        localFilesBackend.loadItems(folderPath)
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
