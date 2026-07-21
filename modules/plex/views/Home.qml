import QtQuick
import Components

// Plex Home dashboard: Continue Watching (pinned) plus a "Recently Added" row
// per library, in the saved library order — the Plex module's landing screen.
// Rows are the same boxart style as the info screen's More Like This. Vertical
// navigation snaps the focused row to the top; a row's title opens the full
// library (or the Continue Watching list); an item opens its info screen.
FocusScope {
    id: homeRoot

    signal navigateTo(string path, var params, var listState)
    signal replaceWith(string path, var params)
    signal goBack()

    property var navParams: ({})
    // Saved cursor position handed back when returning from a pushed view, so
    // Home lands on the item that was opened rather than resetting to the top.
    property var navListState: navParams.navListState || ({})
    property int _restoreRow: -1
    property int _restoreCol: -1

    property var hubs: []
    property int rowIndex: 0
    property int colIndex: 1   // 0 = row title, 1..N = items[colIndex - 1]
    property bool isLoading: true

    // Hover fanart + theme music (shared settings with the info/browse screens).
    property bool infoBg: true
    property real infoBgOpacity: 0.3
    property bool showThemes: false
    property int  themeVolume: 50

    function currentHub() { return hubs[rowIndex] || null }
    function itemsFor(h) { return h ? (h.items || []) : [] }
    function currentItems() { return itemsFor(currentHub()) }
    // The poster currently under the cursor, or null when a row title is focused.
    function hoveredItem() { return colIndex <= 0 ? null : (currentItems()[colIndex - 1] || null) }

    // Cursor position to restore to on return.
    function navState() { return { rowIndex: rowIndex, colIndex: colIndex } }

    function openCurrent() {
        var h = currentHub()
        if (!h) return
        var st = navState()
        if (colIndex === 0) {
            // Title: open the full source.
            if (h.key === "continue_watching")
                homeRoot.navigateTo("Items.qml", {
                    listType: "continue_watching", title: "CONTINUE WATCHING", libraryName: h.title
                }, st)
            else
                homeRoot.navigateTo("Library.qml", {
                    libraryName: h.title, sectionId: h.key, sectionType: h.sectionType
                }, st)
            return
        }
        var it = currentItems()[colIndex - 1]
        if (!it) return
        // Route like browse does: shows open the season/episode view, everything
        // else (movies, episodes from Continue Watching) opens the item view.
        // Both load full detail/art from the item's ratingKey.
        var libName = (h.key !== "continue_watching") ? h.title : ""
        if (it.type === "show")
            homeRoot.navigateTo("ItemShow.qml", { item: it, libraryName: libName }, st)
        else
            homeRoot.navigateTo("Item.qml", { item: it, libraryName: libName }, st)
    }

    // Apply a saved/def cursor position after the model settles (deferred so a
    // model-driven currentIndex reset doesn't clobber it).
    function applyRestore() {
        rowList.currentIndex = _restoreRow
        rowIndex = _restoreRow
        var items = currentItems()
        colIndex = (_restoreCol >= 0) ? Math.max(0, Math.min(_restoreCol, items.length))
                                      : (items.length > 0 ? 1 : 0)
        if (infoBg || showThemes) hoverArtDebounce.restart()
    }

    Component.onCompleted: {
        var bg = appCore.get_setting(moduleRoot.moduleId, "info_background")
        infoBg = (bg === undefined || bg === null || bg === "") ? true : (bg === true || bg === "ON")
        var op = parseInt(appCore.get_setting(moduleRoot.moduleId, "info_background_opacity"))
        if (op > 0) infoBgOpacity = op / 100
        var stv = appCore.get_setting(moduleRoot.moduleId, "show_themes")
        showThemes = (stv === true || stv === "ON")
        var tv = parseInt(appCore.get_setting(moduleRoot.moduleId, "theme_volume"))
        if (tv > 0) themeVolume = tv
        plexBackend.load_home_hubs()
    }
    // Deferred stop on leave: entering an item's info screen (which starts the
    // same theme) carries over seamlessly; leaving elsewhere still stops it.
    Component.onDestruction: plexBackend.stop_theme_deferred()

    Connections {
        target: plexBackend
        function onHomeHubsReady(h) {
            homeRoot.hubs = h
            homeRoot.isLoading = false
            var rs = homeRoot.navListState
            homeRoot.navListState = ({})   // consume — later re-fetches start fresh
            if (rs && rs.rowIndex !== undefined && rs.rowIndex >= 0 && rs.rowIndex < h.length) {
                homeRoot._restoreRow = rs.rowIndex
                homeRoot._restoreCol = (rs.colIndex !== undefined) ? rs.colIndex : -1
            } else {
                homeRoot._restoreRow = 0
                homeRoot._restoreCol = -1
            }
            Qt.callLater(homeRoot.applyRestore)
        }
    }

    // Re-arm the hover fanart/theme whenever the cursor moves to a new poster.
    onRowIndexChanged: if (infoBg || showThemes) hoverArtDebounce.restart()
    onColIndexChanged: if (infoBg || showThemes) hoverArtDebounce.restart()

    // Hover fanart: the highlighted poster's background art, debounced so
    // scrolling doesn't fire a request per step. Opaque base beneath it so it
    // dims toward the theme color, not the app background bleeding through.
    Timer {
        id: hoverArtDebounce
        interval: 250
        repeat: false
        onTriggered: {
            var it = homeRoot.hoveredItem()
            hoverArt.source = (homeRoot.infoBg && it && it.art)
                    ? plexBackend.image_url(it.art, Math.round(root.sw), Math.round(root.sh))
                    : ""
            if (homeRoot.showThemes && it && it.theme)
                plexBackend.play_theme(it.theme, homeRoot.themeVolume)
            else
                plexBackend.stop_theme()
        }
    }
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
        opacity: (homeRoot.infoBg && status === Image.Ready) ? homeRoot.infoBgOpacity : 0
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

    focus: true

    Keys.onUpPressed:   if (rowList.currentIndex > 0) rowList.currentIndex--
    Keys.onDownPressed: if (rowList.currentIndex < hubs.length - 1) rowList.currentIndex++
    Keys.onLeftPressed:  if (colIndex > 0) colIndex--
    Keys.onRightPressed: if (colIndex < currentItems().length) colIndex++
    Keys.onReturnPressed: openCurrent()
    Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
            // Back from Home goes to the full library list (the original browsing
            // options), not out of the module. replaceWith keeps Home off the stack
            // so Back from the list then exits the module as before.
            homeRoot.replaceWith("Libraries.qml", {})
            event.accepted = true
        }
    }

    // Header
    AppBar {
        iconSource: moduleRoot.moduleIcon
        title: moduleRoot.moduleName
        subtitle: plexBackend.get_active_server_name()
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.125 //60
        anchors.leftMargin: root.sw * 0.125 //80
    }

    LoadingText {
        visible: homeRoot.isLoading
        anchors.centerIn: parent
    }

    Text {
        visible: !homeRoot.isLoading && homeRoot.hubs.length === 0
        text: "Nothing to show yet"
        color: root.secondaryColor
        font.family: root.globalFont
        font.capitalization: Font.AllUppercase
        anchors.centerIn: parent
        font.pixelSize: root.sh * 0.05
    }

    // Rows — a vertical list; the focused row is pinned to the top of the viewport.
    ListView {
        id: rowList
        model: homeRoot.hubs
        visible: !homeRoot.isLoading && homeRoot.hubs.length > 0
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: footer.top
        anchors.topMargin: root.sh * 0.25 //120
        anchors.leftMargin: root.sw * 0.115625 //74
        anchors.rightMargin: root.sw * 0.05
        anchors.bottomMargin: root.sh * 0.02
        clip: true
        interactive: true
        flickableDirection: Flickable.VerticalFlick
        spacing: root.sh * 0.025
        highlightMoveDuration: 220
        preferredHighlightBegin: 0
        preferredHighlightEnd: 0
        highlightRangeMode: ListView.StrictlyEnforceRange

        // Drive the custom rowIndex/colIndex model from currentIndex so touch and
        // keyboard share one path: StrictlyEnforceRange updates currentIndex as
        // rows settle under a flick, and the key handlers set it directly. Either
        // way, follow it and reset the column to the row's first poster.
        onCurrentIndexChanged: {
            homeRoot.rowIndex = currentIndex
            homeRoot.colIndex = homeRoot.currentItems().length > 0 ? 1 : 0
        }

        delegate: Item {
            id: hubRow
            width: rowList.width
            height: rowTitle.height + root.sh * 0.0083333 + boxart.height
            property int rowIdx: index
            property bool isCurrentRow: index === homeRoot.rowIndex

            Text {
                id: rowTitle
                text: modelData.title || ""
                color: (hubRow.isCurrentRow && homeRoot.colIndex === 0)
                       ? root.accentColor : root.secondaryColor
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                anchors.top: parent.top
                anchors.left: parent.left
                font.pixelSize: root.sh * 0.0375 //18
            }

            ListView {
                id: boxart
                model: modelData.items
                orientation: ListView.Horizontal
                anchors.top: rowTitle.bottom
                anchors.topMargin: root.sh * 0.0083333
                anchors.left: parent.left
                anchors.right: parent.right
                height: root.sh * 0.245   // matches the cover-grid poster height
                spacing: root.sw * 0.0125
                clip: true
                interactive: true
                flickableDirection: Flickable.HorizontalFlick
                currentIndex: hubRow.isCurrentRow ? (homeRoot.colIndex - 1) : -1
                onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)

                delegate: Item {
                    height: boxart.height
                    width: height * (2 / 3)   // portrait poster
                    property bool sel: hubRow.isCurrentRow && homeRoot.colIndex === index + 1

                    Rectangle {
                        id: pBox
                        anchors.fill: parent
                        color: "transparent"
                        border.color: sel ? root.accentColor : root.tertiaryColor
                        border.width: sel ? Math.max(2, Math.floor(root.sh * 0.00625)) : 1

                        Image {
                            anchors.fill: parent
                            anchors.margins: pBox.border.width
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            source: modelData.poster
                                    ? plexBackend.image_url(modelData.poster, Math.round(boxart.height * 2 / 3), Math.round(boxart.height))
                                    : ""
                        }
                        Text {
                            visible: !modelData.poster
                            anchors.fill: parent
                            anchors.margins: root.sw * 0.0078125
                            text: modelData.title || ""
                            color: root.secondaryColor
                            font.family: root.globalFont
                            font.capitalization: Font.AllUppercase
                            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                            elide: Text.ElideRight
                            font.pixelSize: root.sh * 0.025
                        }

                        // Watch-progress bar for in-progress items (Continue
                        // Watching), pinned to the poster's bottom edge.
                        Rectangle {
                            visible: (modelData.viewOffset || 0) > 0 && (modelData.duration || 0) > 0
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            anchors.margins: pBox.border.width
                            height: Math.max(2, Math.round(root.sh * 0.008))
                            color: Qt.rgba(0, 0, 0, 0.55)
                            Rectangle {
                                anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                                width: parent.width * Math.min(1, (modelData.viewOffset || 0) / Math.max(1, modelData.duration || 0))
                                color: root.accentColor
                            }
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: {
                            if (hubRow.isCurrentRow && homeRoot.colIndex === index + 1)
                                inputManager.touchKey("select")
                            else {
                                // Set the row via currentIndex (which resets colIndex
                                // to the first poster), then land on the tapped poster.
                                rowList.currentIndex = hubRow.rowIdx
                                homeRoot.colIndex = index + 1
                            }
                        }
                    }
                }
            }
        }
    }

    // Footer
    Text {
        id: footer
        text: root.hints.back + ":BACK " + root.hints.navigate + ":NAVIGATE " + root.hints.change + ":BROWSE " + root.hints.select + ":SELECT"
        color: root.tertiaryColor
        font.family: root.globalFont
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.bottomMargin: root.sh * 0.1041667 //50
        anchors.leftMargin: root.sw * 0.125 //80
        font.pixelSize: root.sh * 0.0333333 //16
    }
}
