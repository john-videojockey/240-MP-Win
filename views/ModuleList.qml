import QtQuick
import Components

FocusScope { 
    id: appRoot

    signal navigateTo(string path, var params, var listState)
    signal goBack()

    property var navParams: ({})
    property var navListState: ({})

    Component.onCompleted: {
        appCore.scan_for_modules()
    }

    Connections {
        target: appCore;
        function onModulesLoaded(moduleData) {
            // Trailing EXIT entry so touch/remote users can quit from the home
            // menu without digging into Settings (two-tap protects against an
            // accidental quit).
            var model = moduleData.concat([{ name: "Exit", entry_point: "__quit__" }])
            menuList.model = model
            var restore = (navListState.currentIndex !== undefined) ? navListState.currentIndex : 0
            menuList.currentIndex = Math.min(restore, model.length - 1)
            menuList.positionViewAtIndex(menuList.currentIndex, ListView.Contain)
        }
    }

    // Header
    AppBar {
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.125 //60
        anchors.leftMargin: root.sw * 0.125 //80
    }

    // Empty state (the synthetic EXIT row is always present)
    Column {
        anchors.centerIn: parent
        spacing: root.sh * 0.0333333 //16
        visible: menuList.count <= 1
        Text {
            text: "No modules enabled"
            color: root.secondaryColor
            font.family: root.globalFont
            font.capitalization: Font.AllUppercase
            horizontalAlignment: Text.AlignHCenter
            anchors.horizontalCenter: parent.horizontalCenter
            font.pixelSize: root.sh * 0.05 //24
        }
        Text {
            text: "Please enable one in settings"
            color: root.tertiaryColor
            font.family: root.globalFont
            font.capitalization: Font.AllUppercase
            horizontalAlignment: Text.AlignHCenter
            anchors.horizontalCenter: parent.horizontalCenter
            font.pixelSize: root.sh * 0.0333333 //16
        }
    }

    ListView {
        id: menuList;
        model: [];
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.25 //120
        anchors.leftMargin: root.sw * 0.115625 //74
        width: root.sw * 0.76875 //492
        height: root.sh * 0.525 //252
        clip: true;
        focus: true;

        delegate: Item {
            width: menuList.width;
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

            Item {
                id: textClipContainer;
                width: Math.min(rowText.implicitWidth, menuList.width);
                height: parent.height;
                clip: true;

                Rectangle {
                    color: root.accentColor;
                    anchors.fill: rowText;
                    visible: menuList.currentIndex === index;
                }

                Text {
                    id: rowText;
                    text: modelData.name;
                    color: menuList.currentIndex === index ? root.surfaceColor : root.primaryColor;
                    font.family: root.globalFont;
                    font.capitalization: Font.AllUppercase;
                    anchors.verticalCenter: parent.verticalCenter
                    x: 0
                    topPadding: root.sh * 0.0041667 //2
                    leftPadding: root.sw * 0.009375 //6
                    rightPadding: root.sw * 0.009375 //6
                    bottomPadding: root.sh * 0.00625 //3
                    font.pixelSize: root.sh * 0.05 //24
                }

                SequentialAnimation {
                    id: marqueeAnim;
                    running: (menuList.currentIndex === index) && (rowText.implicitWidth > textClipContainer.width);
                    loops: Animation.Infinite;

                    onRunningChanged: {
                        if (!running) rowText.x = 0;
                    }

                    PauseAnimation { 
                        duration: 1500;
                    }
                    
                    NumberAnimation {
                        target: rowText;
                        property: "x";
                        to: textClipContainer.width - rowText.implicitWidth;
                        duration: Math.abs(to) * 20;
                    }

                    PauseAnimation { 
                        duration: 2000;
                    }

                    PropertyAction { 
                        target: rowText; 
                        property: "x"; 
                        value: 0;
                    }
                }
            }
        }
        
        Keys.onReturnPressed: {
            var selectedModulePath = menuList.model[menuList.currentIndex].entry_point
            if (selectedModulePath === "__quit__") {
                Qt.quit()
                return
            }
            console.log("Routing to: " + selectedModulePath)
            appRoot.navigateTo(selectedModulePath, {}, { currentIndex: menuList.currentIndex })
        }

        Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                appRoot.navigateTo("views/Settings.qml", {}, { currentIndex: menuList.currentIndex })
                event.accepted = true
            }
        }
    }

    // --- FOOTER ---
    Text {
        id: footer
        text: root.hints.back + ":SETTINGS " + root.hints.navigate + ":NAVIGATE " + root.hints.select + ":SELECT"
        color: root.tertiaryColor;
        font.family: root.globalFont;
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.bottomMargin: root.sh * 0.1041667 //50
        anchors.leftMargin: root.sw * 0.125 //80
        font.pixelSize: root.sh * 0.0333333 //16
    }
}