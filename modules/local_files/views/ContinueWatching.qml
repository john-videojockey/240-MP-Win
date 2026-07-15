import QtQuick
import Components

// Continue Watching poster grid, presented like the Plex hub: portrait covers
// (never the video's own frame) with a resume-progress bar. Selecting one opens
// the shared Detail screen, which resumes playback.
FocusScope {
    id: cwRoot

    property var navParams: ({})
    property var navListState: navParams.navListState || ({})

    signal navigateTo(string path, var params, var listState)
    signal goBack()

    property var items: []

    property bool infoBg: true
    property real infoBgOpacity: 0.3

    function currentItem() { return items[grid.currentIndex] }

    Component.onCompleted: {
        items = localFilesBackend.get_continue_watching()
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
            items: items, index: grid.currentIndex, folderName: "CONTINUE WATCHING"
        }, { currentIndex: grid.currentIndex })
    }

    focus: true

    // Hover fanart behind the grid (debounced), same as the browse view.
    Timer {
        id: hoverArtDebounce
        interval: 250
        repeat: false
        onTriggered: {
            var it = cwRoot.currentItem()
            hoverArt.source = (cwRoot.infoBg && it && it.art) ? it.art : ""
        }
    }
    Connections {
        target: grid
        function onCurrentIndexChanged() { if (cwRoot.infoBg) hoverArtDebounce.restart() }
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
        opacity: (cwRoot.infoBg && status === Image.Ready) ? cwRoot.infoBgOpacity : 0
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
        subtitle: "CONTINUE WATCHING"
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.125 //60
        anchors.leftMargin: root.sw * 0.125 //80
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
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.25 //120
        anchors.leftMargin: root.sw * 0.115625 //74
        width: root.sw * 0.76875 //492
        height: root.sh * 0.525 //252
        clip: true

        property real posterH: root.sh * 0.245
        property real posterW: posterH * 2 / 3
        cellHeight: root.sh * 0.2625
        cellWidth: posterW + root.sw * 0.0078125 //5

        Keys.onReturnPressed: cwRoot.selectItem()
        Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                cwRoot.goBack()
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
                    font.pixelSize: root.sh * 0.0291667 //14
                }

                // Resume progress bar along the bottom edge.
                Rectangle {
                    visible: modelData.duration > 0 && modelData.viewOffset > 0
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.margins: posterBox.border.width
                    height: Math.max(2, Math.floor(root.sh * 0.005))
                    color: Qt.rgba(0, 0, 0, 0.6)

                    Rectangle {
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: parent.width * Math.min(1, (modelData.viewOffset || 0)
                                                           / Math.max(1, modelData.duration || 1))
                        color: root.accentColor
                    }
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
