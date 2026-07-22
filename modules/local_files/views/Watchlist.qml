import QtQuick
import Components

// Watchlist poster grid — the videos bookmarked from the Detail screen, presented
// like the Plex Watchlist: a fixed 8-across grid of portrait covers. Selecting one
// opens the shared Detail screen.
FocusScope {
    id: wlRoot

    property var navParams: ({})
    property var navListState: navParams.navListState || ({})

    signal navigateTo(string path, var params, var listState)
    signal goBack()

    property var items: []

    property bool infoBg: true
    property real infoBgOpacity: 0.3

    function currentItem() { return items[grid.currentIndex] }

    Component.onCompleted: {
        items = localFilesBackend.get_watchlist()
        var bg = appCore.get_setting(moduleRoot.moduleId, "info_background")
        infoBg = (bg === undefined || bg === null || bg === "")
                 ? true : (bg === true || bg === "ON")
        var op = parseInt(appCore.get_setting(moduleRoot.moduleId, "info_background_opacity"))
        if (op > 0) infoBgOpacity = op / 100

        if (items.length > 0) {
            var restore = (navListState.currentIndex !== undefined) ? navListState.currentIndex : 0
            grid.currentIndex = Math.min(restore, items.length - 1)
        }
        grid.forceActiveFocus()
        if (infoBg) hoverArtDebounce.restart()
    }

    function selectItem() {
        if (!currentItem()) return
        navigateTo("Detail.qml", {
            items: items, index: grid.currentIndex, folderName: "WATCHLIST"
        }, { currentIndex: grid.currentIndex })
    }

    focus: true

    // Hover fanart behind the grid (debounced), same as the browse view.
    Timer {
        id: hoverArtDebounce
        interval: 250
        repeat: false
        onTriggered: {
            var it = wlRoot.currentItem()
            hoverArt.source = (wlRoot.infoBg && it && it.art) ? it.art : ""
        }
    }
    Connections {
        target: grid
        function onCurrentIndexChanged() { if (wlRoot.infoBg) hoverArtDebounce.restart() }
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
        opacity: (wlRoot.infoBg && status === Image.Ready) ? wlRoot.infoBgOpacity : 0
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

    AppBar {
        iconSource: moduleRoot.moduleIcon
        title: moduleRoot.moduleName
        subtitle: "WATCHLIST"
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.125 //60
        anchors.leftMargin: root.sw * 0.125 //80
    }

    // Empty state (nothing bookmarked yet).
    Text {
        visible: items.length === 0
        text: "NOTHING IN YOUR WATCHLIST"
        color: root.secondaryColor
        font.family: root.globalFont
        anchors.centerIn: parent
        font.pixelSize: root.sh * 0.0375
    }

    // Highlighted item's title above the grid.
    Text {
        visible: items.length > 0
        text: {
            var it = items[grid.currentIndex]
            if (!it) return ""
            return it.title || it.name || ""
        }
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
        id: grid
        model: items
        visible: items.length > 0
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.25 //120
        anchors.leftMargin: root.sw * 0.115625 //74
        width: root.sw * 0.76875 //492
        height: root.sh * 0.525 //252
        clip: true

        // Fixed 8-across grid with the Home/Watchlist horizontal gap, matching the
        // Local Files Cover browse and the Plex Watchlist.
        property real gridCell: Math.floor(grid.width / 8)   // 8 columns, floor-safe
        property real posterW: gridCell - root.sw * 0.0125
        property real posterH: posterW * 1.5
        cellWidth: gridCell
        cellHeight: posterH + root.sh * 0.0175

        Keys.onReturnPressed: wlRoot.selectItem()
        Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                wlRoot.goBack()
                event.accepted = true
            }
        }

        delegate: Item {
            width: grid.cellWidth
            height: grid.cellHeight

            MouseArea {
                anchors.fill: parent
                onClicked: {
                    if (grid.currentIndex === index) inputManager.touchKey("select")
                    else grid.currentIndex = index
                }
            }

            Rectangle {
                id: posterBox
                width: grid.posterW
                height: grid.posterH
                color: "transparent"
                border.color: grid.currentIndex === index ? root.accentColor : root.tertiaryColor
                border.width: grid.currentIndex === index
                              ? Math.max(2, Math.floor(root.sh * 0.00625)) : 1

                Image {
                    id: posterImage
                    anchors.fill: parent
                    anchors.margins: posterBox.border.width
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    source: modelData.poster || modelData.thumb || ""
                }

                Text {
                    visible: posterImage.status !== Image.Ready
                    anchors.fill: parent
                    anchors.margins: root.sw * 0.0078125 //5
                    text: modelData.title || modelData.name || ""
                    color: grid.currentIndex === index ? root.accentColor : root.secondaryColor
                    font.family: root.globalFont
                    font.capitalization: Font.AllUppercase
                    wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    elide: Text.ElideRight
                    font.pixelSize: root.sh * 0.0233333
                }
            }
        }
    }

    Text {
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
