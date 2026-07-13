import QtQuick
import Components

// Local Files landing screen — Continue Watching + Browse, mirroring the way
// Plex opens onto its hub list. Shown only when there is something to resume;
// otherwise Root.qml goes straight to the folder browser.
FocusScope {
    id: homeRoot

    property var navParams: ({})
    property var navListState: navParams.navListState || ({})

    signal navigateTo(string path, var params, var listState)
    signal goBack()

    property var rows: []

    function rebuild() {
        var r = []
        if (localFilesBackend.has_continue_watching())
            r.push({ key: "continue_watching", label: "Continue Watching" })
        r.push({ key: "browse", label: "Browse" })
        rows = r
    }

    function selectRow() {
        var row = rows[menuList.currentIndex]
        if (!row) return
        if (row.key === "continue_watching")
            navigateTo("ContinueWatching.qml", {}, { currentIndex: menuList.currentIndex })
        else
            navigateTo("Items.qml", {}, { currentIndex: menuList.currentIndex })
    }

    // Rebuild on every entry (including returning from playback) so a freshly
    // watched item shows up, or the row disappears once nothing is in progress.
    Component.onCompleted: {
        rebuild()
        var restore = (navListState.currentIndex !== undefined) ? navListState.currentIndex : 0
        menuList.currentIndex = Math.min(restore, Math.max(0, rows.length - 1))
        menuList.forceActiveFocus()
    }

    focus: true

    AppBar {
        iconSource: moduleRoot.moduleIcon
        title: moduleRoot.moduleName
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.125 //60
        anchors.leftMargin: root.sw * 0.125 //80
    }

    ListView {
        id: menuList
        model: rows
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.25 //120
        anchors.leftMargin: root.sw * 0.115625 //74
        width: root.sw * 0.76875 //492
        height: root.sh * 0.525 //252
        clip: true
        focus: true

        Keys.onUpPressed: if (currentIndex > 0) currentIndex--
        Keys.onDownPressed: if (currentIndex < count - 1) currentIndex++
        Keys.onReturnPressed: homeRoot.selectRow()
        Keys.onPressed: function(event) {
            // PgUp/PgDown page by one screenful, keeping the cursor in place.
            if (event.key === Qt.Key_PageDown) { NavUtil.page(menuList, 1); event.accepted = true; return }
            if (event.key === Qt.Key_PageUp) { NavUtil.page(menuList, -1); event.accepted = true; return }
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                homeRoot.goBack()
                event.accepted = true
            }
        }

        delegate: Item {
            width: menuList.width
            height: root.sh * 0.0583333 //28

            // Touch: first tap highlights the row, tapping the highlighted row
            // activates it via a synthesized Enter (same path as the keyboard).
            MouseArea {
                anchors.fill: parent
                onClicked: {
                    if (menuList.currentIndex === index) inputManager.touchKey("select")
                    else menuList.currentIndex = index
                }
            }

            Rectangle {
                anchors.fill: rowText
                color: root.accentColor
                visible: menuList.currentIndex === index
            }

            Text {
                id: rowText
                text: modelData.label
                color: menuList.currentIndex === index ? root.surfaceColor : root.primaryColor
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                anchors.verticalCenter: parent.verticalCenter
                topPadding: root.sh * 0.0041667 //2
                leftPadding: root.sw * 0.009375 //6
                rightPadding: root.sw * 0.009375 //6
                bottomPadding: root.sh * 0.00625 //3
                font.pixelSize: root.sh * 0.05 //24
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
