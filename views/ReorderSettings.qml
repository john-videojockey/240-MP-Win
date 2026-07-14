import QtQuick
import Components

// Reorder a module's sources (Plex: libraries). Select a row to "pick it up",
// then move it with up/down; select again to drop. The order is saved live to
// the setting key as an array of the options' bare keys, so a module backend can
// read it and apply the ordering. Options come from the same options_slot as the
// paired multiselect (e.g. getLibraries).
FocusScope {
    id: reorderRoot

    signal goBack()

    property var navParams: ({})
    property string moduleId: navParams.moduleId || ""
    property string settingKey: navParams.settingKey || ""
    property string settingLabel: navParams.settingLabel || ""
    // Key the options_slot emits on dynamicOptionsReady (may differ from settingKey
    // when a slot is shared with another setting — e.g. getLibraries emits "libraries").
    property string optionsKey: navParams.optionsKey || settingKey

    property int grabbed: -1     // index currently picked up, or -1

    // Bare key for an option. Prefer the explicit "key" field; fall back to the
    // trailing segment of a server-scoped id ("<machineId>_<key>") so this still
    // works if the slot only provides ids.
    function bareKey(o) {
        if (o.key !== undefined && o.key !== "") return o.key
        var id = o.id || ""
        var us = id.lastIndexOf("_")
        return us >= 0 ? id.substring(us + 1) : id
    }

    function applyOrder(options) {
        var allSettings = appCore.get_settings()
        var moduleConfig = (allSettings.modules && allSettings.modules[moduleId]) ? allSettings.modules[moduleId] : {}
        var saved = moduleConfig[settingKey] || []
        var byKey = ({})
        for (var i = 0; i < options.length; i++) byKey[bareKey(options[i])] = options[i]
        var ordered = []
        var used = ({})
        for (var j = 0; j < saved.length; j++) {
            var o = byKey[saved[j]]
            if (o && !used[saved[j]]) { ordered.push(o); used[saved[j]] = true }
        }
        for (var k = 0; k < options.length; k++)
            if (!used[bareKey(options[k])]) ordered.push(options[k])

        libModel.clear()
        for (var m = 0; m < ordered.length; m++)
            libModel.append({ key: bareKey(ordered[m]), label: ordered[m].label || "" })
        if (libModel.count > 0) optionsList.currentIndex = 0
    }

    function persist() {
        var keys = []
        for (var i = 0; i < libModel.count; i++) keys.push(libModel.get(i).key)
        appCore.save_setting(moduleId, settingKey, keys)
    }

    // Move the picked-up row by one slot, carrying the cursor and grab with it.
    // ListModel.move reorders in place (no view reset), so scroll and cursor follow.
    function move(dir) {
        var from = optionsList.currentIndex
        var to = from + dir
        if (to < 0 || to >= libModel.count) return
        libModel.move(from, to, 1)
        optionsList.currentIndex = to
        optionsList.positionViewAtIndex(to, ListView.Contain)
        grabbed = to
        persist()
    }

    ListModel { id: libModel }

    Connections {
        target: appCore
        function onDynamicOptionsReady(mid, key, options) {
            if (mid !== reorderRoot.moduleId || key !== reorderRoot.optionsKey) return
            reorderRoot.applyOrder(options)
        }
    }

    Component.onCompleted: {
        var schema = appCore.get_module_settings_schema(moduleId)
        for (var i = 0; i < schema.length; i++) {
            if (schema[i].key === settingKey && schema[i].options_slot) {
                appCore.invoke_module_action(moduleId, schema[i].options_slot)
                break
            }
        }
    }

    // Header
    AppBar {
        iconSource: "../../assets/images/settings.svg"
        title: "Settings"
        subtitle: moduleId.split(".").pop().toUpperCase() + " / " + settingLabel
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.125 //60
        anchors.leftMargin: root.sw * 0.125 //80
    }

    ListView {
        id: optionsList
        model: libModel
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.25 //120
        anchors.leftMargin: root.sw * 0.115625 //74
        width: root.sw * 0.76875 //492
        height: root.sh * 0.525 //252
        clip: true
        focus: true

        // Smoothly slide rows past each other while reordering.
        move: Transition { NumberAnimation { properties: "y"; duration: 150 } }
        moveDisplaced: Transition { NumberAnimation { properties: "y"; duration: 150 } }

        Keys.onUpPressed: {
            if (reorderRoot.grabbed >= 0) reorderRoot.move(-1)
            else if (currentIndex > 0) { currentIndex--; positionViewAtIndex(currentIndex, ListView.Contain) }
        }
        Keys.onDownPressed: {
            if (reorderRoot.grabbed >= 0) reorderRoot.move(1)
            else if (currentIndex < count - 1) { currentIndex++; positionViewAtIndex(currentIndex, ListView.Contain) }
        }

        Keys.onReturnPressed: {
            reorderRoot.grabbed = (reorderRoot.grabbed < 0) ? currentIndex : -1
        }

        Keys.onPressed: function(event) {
            if (event.key === Qt.Key_PageDown) { NavUtil.page(optionsList, 1); event.accepted = true; return }
            if (event.key === Qt.Key_PageUp) { NavUtil.page(optionsList, -1); event.accepted = true; return }
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                // Drop first, then leave — a dangling grab shouldn't leak out.
                if (reorderRoot.grabbed >= 0) { reorderRoot.grabbed = -1; event.accepted = true; return }
                reorderRoot.goBack()
                event.accepted = true
            }
        }

        delegate: Item {
            width: optionsList.width
            height: root.sh * 0.0583333 //28

            Rectangle {
                anchors.fill: parent
                // Focused: accent fill. Picked-up: primary fill (a distinct "held" look).
                color: reorderRoot.grabbed === index ? root.primaryColor
                       : optionsList.currentIndex === index ? root.accentColor : "transparent"

                // Touch: tap focuses; tapping the focused row picks it up / drops it.
                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        if (optionsList.currentIndex === index) inputManager.touchKey("select")
                        else optionsList.currentIndex = index
                    }
                }

                Text {
                    text: model.label || ""
                    color: (optionsList.currentIndex === index || reorderRoot.grabbed === index)
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

                // Grab handle / position indicator on the right.
                Text {
                    text: reorderRoot.grabbed === index ? "▲▼" : "≡"
                    color: (optionsList.currentIndex === index || reorderRoot.grabbed === index)
                           ? root.surfaceColor : root.tertiaryColor
                    font.family: root.globalFont
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.right: parent.right
                    anchors.rightMargin: root.sw * 0.009375 //6
                    topPadding: root.sh * 0.0041667 //2
                    bottomPadding: root.sh * 0.00625 //3
                    font.pixelSize: root.sh * 0.0375 //18
                }
            }
        }
    }

    // --- HELP TEXT ---
    Rectangle {
        id: rowHelpBackground
        property color baseColor: root.primaryColor
        color: Qt.rgba(baseColor.r, baseColor.g, baseColor.b, 0.2)
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.bottomMargin: root.sh * 0.1583333 //76
        anchors.leftMargin: root.sw * 0.125 //80
        width: root.sw * 0.75 //480
        height: root.sh * 0.0583333 //28
        clip: true
        Text {
            text: reorderRoot.grabbed >= 0 ? "Move with up/down, select to drop"
                                           : "Select a source to pick it up and move it"
            color: root.primaryColor
            font.family: root.globalFont
            font.pixelSize: root.sh * 0.0291667 //14
            anchors.fill: parent
            anchors.margins: root.sw * 0.0125 //6
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }

    // --- FOOTER ---
    Text {
        id: footer
        text: root.hints.back + ":BACK " + root.hints.navigate + ":MOVE " + root.hints.select + (reorderRoot.grabbed >= 0 ? ":DROP" : ":PICK UP")
        color: root.tertiaryColor
        font.family: root.globalFont
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.bottomMargin: root.sh * 0.1041667 //50
        anchors.leftMargin: root.sw * 0.125 //80
        font.pixelSize: root.sh * 0.0333333 //16
    }
}
