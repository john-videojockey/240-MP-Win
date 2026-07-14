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
    signal goBack()

    property var navParams: ({})

    property var hubs: []
    property int rowIndex: 0
    property int colIndex: 1   // 0 = row title, 1..N = items[colIndex - 1]
    property bool isLoading: true

    function currentHub() { return hubs[rowIndex] || null }
    function itemsFor(h) { return h ? (h.items || []) : [] }
    function currentItems() { return itemsFor(currentHub()) }

    function openCurrent() {
        var h = currentHub()
        if (!h) return
        if (colIndex === 0) {
            // Title: open the full source.
            if (h.key === "continue_watching")
                homeRoot.navigateTo("Items.qml", {
                    listType: "continue_watching", title: "CONTINUE WATCHING", libraryName: h.title
                }, {})
            else
                homeRoot.navigateTo("Library.qml", {
                    libraryName: h.title, sectionId: h.key, sectionType: h.sectionType
                }, {})
            return
        }
        var it = currentItems()[colIndex - 1]
        if (it) homeRoot.navigateTo("Item.qml", { item: it }, {})
    }

    Component.onCompleted: plexBackend.load_home_hubs()

    Connections {
        target: plexBackend
        function onHomeHubsReady(h) {
            homeRoot.hubs = h
            homeRoot.rowIndex = 0
            homeRoot.colIndex = homeRoot.currentItems().length > 0 ? 1 : 0
            homeRoot.isLoading = false
        }
    }

    focus: true

    Keys.onUpPressed:   if (rowIndex > 0) { rowIndex--; colIndex = currentItems().length > 0 ? 1 : 0 }
    Keys.onDownPressed: if (rowIndex < hubs.length - 1) { rowIndex++; colIndex = currentItems().length > 0 ? 1 : 0 }
    Keys.onLeftPressed:  if (colIndex > 0) colIndex--
    Keys.onRightPressed: if (colIndex < currentItems().length) colIndex++
    Keys.onReturnPressed: openCurrent()
    Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
            homeRoot.goBack()
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
        currentIndex: homeRoot.rowIndex
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: footer.top
        anchors.topMargin: root.sh * 0.25 //120
        anchors.leftMargin: root.sw * 0.115625 //74
        anchors.rightMargin: root.sw * 0.05
        anchors.bottomMargin: root.sh * 0.02
        clip: true
        interactive: false
        spacing: root.sh * 0.025
        highlightMoveDuration: 220
        preferredHighlightBegin: 0
        preferredHighlightEnd: 0
        highlightRangeMode: ListView.StrictlyEnforceRange

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
                interactive: false
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
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: {
                            if (hubRow.isCurrentRow && homeRoot.colIndex === index + 1)
                                inputManager.touchKey("select")
                            else { homeRoot.rowIndex = hubRow.rowIdx; homeRoot.colIndex = index + 1 }
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
