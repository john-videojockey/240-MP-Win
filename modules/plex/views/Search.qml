import QtQuick
import Components

// Plex search — a two-pane live-search screen:
//   • Left 30%: an on-screen keyboard (navigable by remote/gamepad/touch; a physical
//     keyboard types straight in). Results update as you type (debounced).
//   • Right 70%: category tabs (All/Movies/Shows/Episodes) over a results list, each row
//     a cover on the left with the title/metadata beside it.
// Focus moves between three regions (keys / tabs / results); the root owns all keys.
FocusScope {
    id: searchRoot

    property var navParams: ({})
    property var navListState: navParams.navListState || ({})

    signal navigateTo(string path, var params, var listState)
    signal goBack()

    property string libraryName: navParams.libraryName || ""
    property string query: ""

    property string focusRegion: "keys"   // "keys" | "tabs" | "results"

    // --- Results / live search ---
    property var    allResults: []
    property string activeQuery: ""        // the query currently being searched (stale-drop)
    property bool   isSearching: false
    property int    pendingResultIndex: -1 // restored on the next results (nav return)

    property var tabs: [
        { label: "ALL",      type: "" },
        { label: "MOVIES",   type: "movie" },
        { label: "SHOWS",    type: "show" },
        { label: "EPISODES", type: "episode" },
        { label: "CAST",     type: "actor" }
    ]
    property int tabIndex: 0
    property var filtered: {
        var t = tabs[tabIndex].type
        if (t === "") return allResults
        var out = []
        for (var i = 0; i < allResults.length; i++)
            if (allResults[i].type === t) out.push(allResults[i])
        return out
    }
    property int resultIndex: 0
    function clampResult() { if (resultIndex > filtered.length - 1) resultIndex = Math.max(0, filtered.length - 1) }
    onFilteredChanged: clampResult()

    // --- Keyboard (single-char keys type themselves; word keys act) ---
    property var kbRows: [
        ["A","B","C","D","E","F"],
        ["G","H","I","J","K","L"],
        ["M","N","O","P","Q","R"],
        ["S","T","U","V","W","X"],
        ["Y","Z","0","1","2","3"],
        ["4","5","6","7","8","9"],
        ["SPACE","DEL","CLEAR"]
    ]
    property int kbRow: 0
    property int kbCol: 0
    property var kbGrid: {
        var g = []
        for (var r = 0; r < kbRows.length; r++) {
            var row = [], n = kbRows[r].length
            for (var c = 0; c < n; c++)
                row.push({ key: kbRows[r][c], row: r, col: c, n: n })
            g.push(row)
        }
        return g
    }
    function kbClamp() { if (kbCol > kbRows[kbRow].length - 1) kbCol = kbRows[kbRow].length - 1 }
    function activateKey() {
        var k = kbRows[kbRow][kbCol]
        if      (k === "SPACE") query += " "
        else if (k === "DEL")   query = query.slice(0, -1)
        else if (k === "CLEAR") query = ""
        else                    query += k
    }

    function selectResult() {
        var item = filtered[resultIndex]
        if (!item) return
        var st = { query: query, tabIndex: tabIndex, resultIndex: resultIndex, focusRegion: focusRegion,
                   kbRow: kbRow, kbCol: kbCol }
        if (item.type === "actor") {
            // Open the actor's filmography, merged across every library they appear in.
            if (item.keys && item.keys.length > 0)
                searchRoot.navigateTo("Items.qml", {
                    listType: "actor_titles", title: item.title, actorKeys: item.keys, libraryName: item.title
                }, st)
        } else if (item.type === "show")
            searchRoot.navigateTo("ItemShow.qml", { item: item, libraryName: libraryName }, st)
        else
            searchRoot.navigateTo("Item.qml", { item: item, libraryName: libraryName }, st)
    }

    // --- Live search (debounced; typing anywhere refines) ---
    Timer {
        id: searchDebounce
        interval: 350
        repeat: false
        onTriggered: {
            var q = searchRoot.query.replace(/^\s+|\s+$/g, "")
            searchRoot.activeQuery = q
            if (q === "") { searchRoot.allResults = []; searchRoot.isSearching = false; return }
            searchRoot.isSearching = true
            plexBackend.search(q)
        }
    }
    onQueryChanged: searchDebounce.restart()

    Connections {
        target: plexBackend
        function onSearchResultsReady(q, items) {
            if (q !== searchRoot.activeQuery) return   // a newer query has superseded this
            searchRoot.isSearching = false
            searchRoot.allResults = items
            if (searchRoot.pendingResultIndex >= 0) {
                searchRoot.resultIndex = Math.min(searchRoot.pendingResultIndex,
                                                  Math.max(0, searchRoot.filtered.length - 1))
                searchRoot.pendingResultIndex = -1
            } else {
                searchRoot.resultIndex = 0
            }
        }
    }

    Component.onCompleted: {
        if (navListState.tabIndex    !== undefined) tabIndex    = navListState.tabIndex
        if (navListState.focusRegion !== undefined) focusRegion = navListState.focusRegion
        if (navListState.kbRow       !== undefined) kbRow       = navListState.kbRow
        if (navListState.kbCol       !== undefined) kbCol       = navListState.kbCol
        if (navListState.resultIndex !== undefined) pendingResultIndex = navListState.resultIndex
        if (navListState.query       !== undefined) query = navListState.query   // triggers the search
        kbClamp()
    }

    focus: true
    Keys.onPressed: function(event) {
        // Global — work in any region.
        if (event.key === Qt.Key_Escape || event.key === Qt.Key_Back) { goBack(); event.accepted = true; return }
        if (event.key === Qt.Key_Backspace) { query = query.slice(0, -1); event.accepted = true; return }
        if (event.text.length === 1) {
            var c = event.text.toUpperCase()
            if ((c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c === " ") {
                query += c; event.accepted = true; return
            }
        }

        if (focusRegion === "keys") {
            if (event.key === Qt.Key_Left)  { if (kbCol > 0) kbCol-- }
            else if (event.key === Qt.Key_Right) {
                if (kbCol < kbRows[kbRow].length - 1) kbCol++
                else if (filtered.length > 0) { focusRegion = "results"; clampResult() }
            }
            else if (event.key === Qt.Key_Up)    { if (kbRow > 0) { kbRow--; kbClamp() } }
            else if (event.key === Qt.Key_Down)  { if (kbRow < kbRows.length - 1) { kbRow++; kbClamp() } }
            else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { activateKey() }
            event.accepted = true
        } else if (focusRegion === "results") {
            if (event.key === Qt.Key_Up)   { if (resultIndex > 0) resultIndex--; else focusRegion = "tabs" }
            else if (event.key === Qt.Key_Down) { if (resultIndex < filtered.length - 1) resultIndex++ }
            else if (event.key === Qt.Key_Left) { focusRegion = "keys" }
            else if (event.key === Qt.Key_PageDown) { resultIndex = Math.min(filtered.length - 1, resultIndex + 4) }
            else if (event.key === Qt.Key_PageUp)   { resultIndex = Math.max(0, resultIndex - 4) }
            else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { selectResult() }
            event.accepted = true
        } else if (focusRegion === "tabs") {
            if (event.key === Qt.Key_Left)  { if (tabIndex > 0) { tabIndex--; clampResult() } else focusRegion = "keys" }
            else if (event.key === Qt.Key_Right) { if (tabIndex < tabs.length - 1) { tabIndex++; clampResult() } }
            else if (event.key === Qt.Key_Down || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                if (filtered.length > 0) focusRegion = "results"
            }
            event.accepted = true
        }
    }

    // --- Geometry ---
    readonly property real contentX:   root.sw * 0.125
    readonly property real contentTop: root.sh * 0.22
    readonly property real contentW:   root.sw * 0.75
    readonly property real leftW:      contentW * 0.3
    readonly property real paneGap:    root.sw * 0.025
    readonly property real rightX:     contentX + leftW + paneGap
    readonly property real rightW:     contentW - leftW - paneGap
    readonly property real keyGap:     root.sw * 0.005

    // Header
    AppBar {
        iconSource: moduleRoot.moduleIcon
        title: moduleRoot.moduleName
        subtitle: "SEARCH"
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.125 //60
        anchors.leftMargin: root.sw * 0.125 //80
    }

    // ── Left pane: query + keyboard ───────────────────────────────────────────
    QtObject { id: cursor; property bool on: true }
    Timer { interval: 530; running: true; repeat: true; onTriggered: cursor.on = !cursor.on }
    Row {
        x: searchRoot.contentX
        y: searchRoot.contentTop
        spacing: root.sw * 0.003
        Text {
            text: searchRoot.query.length > 0 ? searchRoot.query : "TYPE TO SEARCH"
            color: searchRoot.query.length > 0 ? root.primaryColor : root.tertiaryColor
            font.family: root.globalFont
            font.capitalization: Font.AllUppercase
            font.pixelSize: root.sh * 0.045 //22
        }
        Rectangle {
            width: root.sw * 0.0093
            height: root.sh * 0.045
            color: root.primaryColor
            visible: searchRoot.query.length > 0 && cursor.on
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    Column {
        x: searchRoot.contentX
        y: searchRoot.contentTop + root.sh * 0.08
        spacing: root.sh * 0.014
        Repeater {
            model: searchRoot.kbGrid
            Row {
                spacing: searchRoot.keyGap
                Repeater {
                    model: modelData   // this row's keys, each { key, row, col, n }
                    Rectangle {
                        id: keyCell
                        property bool focused: searchRoot.focusRegion === "keys"
                                               && searchRoot.kbRow === modelData.row
                                               && searchRoot.kbCol === modelData.col
                        width: (searchRoot.leftW - (modelData.n - 1) * searchRoot.keyGap) / modelData.n
                        height: root.sh * 0.058
                        color: focused ? root.accentColor : "transparent"
                        border.color: focused ? root.accentColor : root.tertiaryColor
                        border.width: focused ? Math.max(2, Math.floor(root.sh * 0.00625)) : 1

                        Text {
                            anchors.centerIn: parent
                            text: modelData.key
                            color: keyCell.focused ? root.surfaceColor : root.primaryColor
                            font.family: root.globalFont
                            font.pixelSize: root.sh * 0.0291667 //14
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: {
                                searchRoot.focusRegion = "keys"
                                if (searchRoot.kbRow === modelData.row && searchRoot.kbCol === modelData.col)
                                    searchRoot.activateKey()
                                else { searchRoot.kbRow = modelData.row; searchRoot.kbCol = modelData.col }
                            }
                        }
                    }
                }
            }
        }
    }

    // ── Right pane: tabs + results ────────────────────────────────────────────
    Row {
        id: tabBar
        x: searchRoot.rightX
        y: searchRoot.contentTop
        spacing: root.sw * 0.02
        Repeater {
            model: searchRoot.tabs
            Item {
                id: tabItem
                width: tabLabel.implicitWidth
                height: root.sh * 0.05
                property bool active: searchRoot.tabIndex === index
                property bool foc: searchRoot.focusRegion === "tabs" && searchRoot.tabIndex === index
                Text {
                    id: tabLabel
                    text: modelData.label
                    color: tabItem.foc ? root.accentColor : (tabItem.active ? root.primaryColor : root.tertiaryColor)
                    font.family: root.globalFont
                    font.pixelSize: root.sh * 0.0333333 //16
                    anchors.verticalCenter: parent.verticalCenter
                }
                Rectangle {
                    visible: tabItem.active
                    anchors.top: tabLabel.bottom
                    anchors.left: tabLabel.left
                    anchors.right: tabLabel.right
                    anchors.topMargin: root.sh * 0.004
                    height: Math.max(2, Math.floor(root.sh * 0.003))
                    color: tabItem.foc ? root.accentColor : root.primaryColor
                }
                MouseArea {
                    anchors.fill: parent
                    onClicked: { searchRoot.tabIndex = index; searchRoot.focusRegion = "tabs"; searchRoot.clampResult() }
                }
            }
        }
    }

    // Status line (searching / empty)
    Text {
        x: searchRoot.rightX
        y: searchRoot.contentTop + root.sh * 0.09
        visible: searchRoot.filtered.length === 0
        text: searchRoot.isSearching ? "SEARCHING…"
              : (searchRoot.query.replace(/^\s+|\s+$/g,"") === "" ? "TYPE TO SEARCH" : "NO RESULTS")
        color: root.tertiaryColor
        font.family: root.globalFont
        font.pixelSize: root.sh * 0.0375 //18
    }

    ListView {
        id: resultsList
        x: searchRoot.rightX
        y: searchRoot.contentTop + root.sh * 0.075
        width: searchRoot.rightW
        height: root.sh * 0.56
        clip: true
        interactive: false
        model: searchRoot.filtered
        currentIndex: searchRoot.resultIndex
        onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)

        delegate: Item {
            id: resRow
            width: resultsList.width
            height: root.sh * 0.14
            property bool sel: resultsList.currentIndex === index && searchRoot.focusRegion === "results"

            Rectangle {
                anchors.fill: parent
                anchors.rightMargin: root.sw * 0.006
                color: resRow.sel ? root.accentColor : "transparent"
            }

            MouseArea {
                anchors.fill: parent
                onClicked: {
                    searchRoot.focusRegion = "results"
                    if (resultsList.currentIndex === index) searchRoot.selectResult()
                    else searchRoot.resultIndex = index
                }
            }

            Row {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: root.sw * 0.0078125
                spacing: root.sw * 0.0125

                Rectangle {   // cover — ~half the Continue Watching poster
                    width: root.sh * 0.08
                    height: root.sh * 0.12
                    anchors.verticalCenter: parent.verticalCenter
                    color: "transparent"
                    border.color: root.tertiaryColor
                    border.width: 1
                    Image {
                        anchors.fill: parent
                        anchors.margins: 1
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        property string artPath: modelData.poster || modelData.thumb || modelData.art || ""
                        source: artPath ? plexBackend.image_url(artPath, Math.round(width), Math.round(height)) : ""
                    }
                }

                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    width: resultsList.width - root.sh * 0.08 - root.sw * 0.03
                    spacing: root.sh * 0.008
                    Text {
                        width: parent.width
                        text: (modelData.type === "episode" && modelData.grandparentTitle)
                              ? (modelData.grandparentTitle + ": " + (modelData.title || ""))
                              : (modelData.title || "")
                        color: resRow.sel ? root.surfaceColor : root.primaryColor
                        font.family: root.globalFont
                        font.capitalization: Font.AllUppercase
                        elide: Text.ElideRight
                        font.pixelSize: root.sh * 0.0375 //18
                    }
                    Text {
                        text: (modelData.type || "").toUpperCase()
                              + (modelData.year ? "   " + modelData.year : "")
                        color: resRow.sel ? root.surfaceColor : root.tertiaryColor
                        font.family: root.globalFont
                        font.pixelSize: root.sh * 0.0291667 //14
                    }
                }
            }
        }
    }

    // Footer
    Text {
        text: root.hints.back + ":BACK " + root.hints.navigate + ":MOVE " + root.hints.select + ":SELECT"
        color: root.tertiaryColor
        font.family: root.globalFont
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.bottomMargin: root.sh * 0.1041667 //50
        anchors.leftMargin: root.sw * 0.125 //80
        font.pixelSize: root.sh * 0.0333333 //16
    }
}
