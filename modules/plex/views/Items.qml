import QtQuick
import Components

// Reusable list view — handles all listType values via navParams.
FocusScope {
    id: itemListRoot

    property var navParams: ({})
    property var navListState: navParams.navListState || ({})

    signal navigateTo(string path, var params, var listState)
    signal goBack()

    property string listType: navParams.listType || ""
    property string listTitle: navParams.title || ""
    property string sectionId: navParams.sectionId || ""
    property string hubKey: navParams.hubKey || ""
    property string ratingKey: navParams.ratingKey || ""
    property string categoryKey: navParams.categoryKey || ""
    property string libraryName: navParams.libraryName || ""

    property var items: []
    property bool isLoading: false
    property string errorMessage: ""

    property bool showLetterNav: listType === "library_all"
    property bool letterNavActive: false
    property var letterIndex: []

    // Browse View setting: "Cover" renders media lists as an art grid with the
    // highlighted title shown above it. Pure movie/show lists use portrait
    // posters; lists containing episodes (e.g. Continue Watching) use
    // landscape 16:9 cards instead — episode stills are 16:9, and cropping
    // them into portrait would discard most of the frame. Structural lists
    // (hubs, categories, playlists-of-lists, …) keep the title list.
    property string browseView: (appCore.get_setting(moduleRoot.moduleId, "browse_view") || "Title")
    property bool coverMode: browseView === "Cover" && items.length > 0 && itemsAreCovers(items)
    // Continue Watching always uses portrait posters (show/season cover, not
    // the episode screenshot); other episode-bearing lists use landscape cards.
    property bool gridLandscape: coverMode && anyEpisodes(items) && listType !== "continue_watching"

    // Fanart hover background (shared module settings with the info screen)
    property bool infoBg: true
    property real infoBgOpacity: 0.3
    // Theme music on hover (same settings as the info screen).
    property bool showThemes: false
    property int  themeVolume: 50

    function itemsAreCovers(arr) {
        for (var i = 0; i < arr.length; i++) {
            var t = arr[i].type
            if (t !== "movie" && t !== "show" && t !== "episode") return false
        }
        return true
    }

    function anyEpisodes(arr) {
        for (var i = 0; i < arr.length; i++) {
            if (arr[i].type === "episode") return true
        }
        return false
    }

    // The item currently highlighted in whichever view is active.
    function currentItem() {
        return items[coverMode ? coverGrid.currentIndex : itemList.currentIndex]
    }

    // Shared post-load bookkeeping: both views track the same current index so
    // the saved list position round-trips regardless of the browse view.
    function applyLoadedItems(loadedItems) {
        isLoading = false
        items = loadedItems
        if (showLetterNav)
            letterIndex = buildLetterIndex(loadedItems)
        if (loadedItems.length > 0) {
            var restore = (navListState.currentIndex !== undefined) ? navListState.currentIndex : 0
            var idx = Math.min(restore, loadedItems.length - 1)
            itemList.currentIndex = idx
            itemList.positionViewAtIndex(idx, ListView.Contain)
            coverGrid.currentIndex = idx
            coverGrid.positionViewAtIndex(idx, GridView.Contain)
        }
        if (infoBg || showThemes) hoverArtDebounce.restart()
    }

    function sortKey(title) {
        var t = (title || "").toLowerCase()
        var articles = ["the ", "a ", "an "]
        for (var i = 0; i < articles.length; i++) {
            if (t.indexOf(articles[i]) === 0) { t = t.substring(articles[i].length); break }
        }
        var ch = t.charAt(0).toUpperCase()
        return (ch >= 'A' && ch <= 'Z') ? ch : '#'
    }

    function buildLetterIndex(itemArr) {
        var seen = {}
        var result = []
        for (var i = 0; i < itemArr.length; i++) {
            var letter = sortKey(itemArr[i].title || "")
            if (!seen[letter]) {
                seen[letter] = true
                result.push({ letter: letter, firstIndex: i })
            }
        }
        result.sort(function(a, b) {
            if (a.letter === '#') return -1
            if (b.letter === '#') return 1
            return a.letter < b.letter ? -1 : 1
        })
        return result
    }

    // ----------------------------------------------------------------
    // Signal connections from backend
    // ----------------------------------------------------------------

    Connections {
        target: plexBackend

        function onItemsLoaded(loadedItems) {
            var consuming = ["library_all", "hub_items", "collection_items",
                             "playlist_items", "category_items", "continue_watching"]
            if (consuming.indexOf(itemListRoot.listType) >= 0)
                itemListRoot.applyLoadedItems(loadedItems)
        }

        function onContinueWatchingLoaded(loadedItems) {
            if (itemListRoot.listType === "continue_watching")
                itemListRoot.applyLoadedItems(loadedItems)
        }

        function onHubsLoaded(loadedHubs) {
            if (itemListRoot.listType === "hubs")
                itemListRoot.applyLoadedItems(loadedHubs)
        }

        function onCollectionsLoaded(loadedItems) {
            if (itemListRoot.listType === "collections")
                itemListRoot.applyLoadedItems(loadedItems)
        }

        function onPlaylistsLoaded(loadedItems) {
            if (itemListRoot.listType === "playlists")
                itemListRoot.applyLoadedItems(loadedItems)
        }

        function onCategoriesLoaded(loadedItems) {
            if (itemListRoot.listType === "categories")
                itemListRoot.applyLoadedItems(loadedItems)
        }

        function onErrorOccurred(msg) {
            if (itemListRoot.listType !== "") {
                itemListRoot.isLoading = false
                itemListRoot.errorMessage = msg
            }
            console.log("[ItemList] Error: " + msg)
        }
    }

    // ----------------------------------------------------------------
    // Select item — navigate based on type
    // ----------------------------------------------------------------

    function selectItem() {
        var idx = coverMode ? coverGrid.currentIndex : itemList.currentIndex
        var item = items[idx]
        if (!item) return

        // Intermediate lists that navigate deeper
        if (listType === "hubs") {
            // Hub selected → load items for that hub
            itemListRoot.navigateTo("Items.qml", {
                listType: "hub_items",
                title: item.title,
                hubKey: item.hubKey || item.key,
                libraryName: libraryName
            }, { currentIndex: idx })
            return
        }

        if (listType === "collections") {
            itemListRoot.navigateTo("Items.qml", {
                listType: "collection_items",
                title: item.title,
                ratingKey: item.ratingKey,
                libraryName: libraryName
            }, { currentIndex: idx })
            return
        }

        if (listType === "playlists") {
            itemListRoot.navigateTo("Items.qml", {
                listType: "playlist_items",
                title: item.title,
                ratingKey: item.ratingKey,
                libraryName: libraryName
            }, { currentIndex: idx })
            return
        }

        if (listType === "categories") {
            // Boolean filters (e.g. hdr) have no directory listing — apply directly
            var catKey = (item.filterType === "boolean") ? item.key + "=1" : item.key
            itemListRoot.navigateTo("Items.qml", {
                listType: "category_items",
                title: item.title,
                sectionId: sectionId,
                categoryKey: catKey,
                libraryName: libraryName
            }, { currentIndex: idx })
            return
        }

        // For category_items the items are sub-filter values (e.g. genre names),
        // not actual media. Navigate further if type is 'genre_item'.
        if (item.type === "genre_item") {
            // item.ratingKey is actually the filter value key from the server
            // Use it to load actual media items
            itemListRoot.navigateTo("Items.qml", {
                listType: "category_items",
                title: item.title,
                sectionId: item._sectionId || sectionId,
                categoryKey: item._filterKey + "=" + encodeURIComponent(item.ratingKey),
                libraryName: libraryName
            }, { currentIndex: idx })
            return
        }

        // TV Show → go to Show detail view
        if (item.type === "show") {
            itemListRoot.navigateTo("ItemShow.qml", {
                item: item,
                libraryName: libraryName
            }, { currentIndex: idx })
            return
        }

        // Actual media item (movie, episode, other) → go to detail
        itemListRoot.navigateTo("Item.qml", {
            item: item,
            libraryName: libraryName
        }, { currentIndex: idx })
    }

    // ----------------------------------------------------------------
    // Data loading on appear
    // ----------------------------------------------------------------

    Component.onCompleted: {
        var bg = appCore.get_setting(moduleRoot.moduleId, "info_background")
        infoBg = (bg === undefined || bg === null || bg === "")
                 ? true : (bg === true || bg === "ON")
        var op = parseInt(appCore.get_setting(moduleRoot.moduleId, "info_background_opacity"))
        if (op > 0) infoBgOpacity = op / 100
        var stv = appCore.get_setting(moduleRoot.moduleId, "show_themes")
        showThemes = (stv === true || stv === "ON")
        var tv = parseInt(appCore.get_setting(moduleRoot.moduleId, "theme_volume"))
        if (tv > 0) themeVolume = tv

        isLoading = true
        errorMessage = ""
        if (listType === "library_all")
            plexBackend.load_library_all(sectionId)
        else if (listType === "hub_items")
            plexBackend.load_items_for_hub(hubKey)
        else if (listType === "hubs")
            plexBackend.load_section_hubs(sectionId)
        else if (listType === "collections")
            plexBackend.load_collections(sectionId)
        else if (listType === "collection_items")
            plexBackend.load_collection_items(ratingKey)
        else if (listType === "playlists")
            plexBackend.load_playlists(sectionId)
        else if (listType === "playlist_items")
            plexBackend.load_playlist_items(ratingKey)
        else if (listType === "categories")
            plexBackend.load_categories(sectionId)
        else if (listType === "category_items")
            plexBackend.load_category_items(sectionId, categoryKey)
        else if (listType === "continue_watching")
            plexBackend.load_continue_watching()
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
    // scrolling a long list doesn't fire a request per step. Same fit-to-
    // height full-bleed + scanline treatment as the info screen, sharing its
    // settings. z below every sibling so all content stacks above.
    Timer {
        id: hoverArtDebounce
        interval: 250
        repeat: false
        onTriggered: {
            var it = itemListRoot.currentItem()
            hoverArt.source = (itemListRoot.infoBg && it && it.art)
                    ? plexBackend.image_url(it.art, Math.round(root.sw), Math.round(root.sh))
                    : ""
            // Play the hovered item's theme (if enabled and it has one).
            if (itemListRoot.showThemes && it && it.theme)
                plexBackend.play_theme(it.theme, itemListRoot.themeVolume)
            else
                plexBackend.stop_theme()
        }
    }
    // Restart the debounce whenever the highlight moves in either view — needed
    // for the hover fanart and/or the hover theme.
    Connections {
        target: itemList
        function onCurrentIndexChanged() {
            if (itemListRoot.infoBg || itemListRoot.showThemes) hoverArtDebounce.restart()
        }
    }
    Connections {
        target: coverGrid
        function onCurrentIndexChanged() {
            if (itemListRoot.infoBg || itemListRoot.showThemes) hoverArtDebounce.restart()
        }
    }
    // Deferred stop on leave: entering an item's info screen (which starts the
    // same theme) carries over seamlessly; leaving to a themeless screen still
    // stops it after the short delay.
    Component.onDestruction: plexBackend.stop_theme_deferred()

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
        opacity: (itemListRoot.infoBg && status === Image.Ready) ? itemListRoot.infoBgOpacity : 0
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
        subtitle: libraryName
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.125 //60
        anchors.leftMargin: root.sw * 0.125 //80
    }

    // Loading / empty / error states
    LoadingText {
        visible: isLoading
        anchors.centerIn: parent
    }
    Text {
        visible: !isLoading && errorMessage !== ""
        text: errorMessage
        color: root.tertiaryColor
        font.family: root.globalFont
        anchors.centerIn: parent
        wrapMode: Text.WordWrap
        horizontalAlignment: Text.AlignHCenter
        font.pixelSize: root.sh * 0.05 //24
    }
    Text {
        visible: !isLoading && errorMessage === "" && items.length === 0
        text: "NO ITEMS FOUND"
        color: root.tertiaryColor
        font.family: root.globalFont
        anchors.centerIn: parent
        font.pixelSize: root.sh * 0.05 //24
    }

    // ── Cover browse view ─────────────────────────────────────────────
    // Poster grid for movie/show lists; the highlighted item's title sits
    // above the grid (there is no room for one under each poster).
    Text {
        visible: coverMode
        text: {
            var it = items[coverGrid.currentIndex]
            if (!it) return ""
            var base = (it.type === "episode" && it.grandparentTitle)
                       ? (it.grandparentTitle + ": " + (it.title || ""))
                       : (it.title || "")
            return it.editionTitle ? (base + " (" + it.editionTitle + ")") : base
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

        // Two rows; cell aspect picks the column count. Portrait 2:3 posters
        // for movie/show lists, landscape 16:9 cards when episodes are mixed
        // in (their stills are 16:9; movies then show their fanart instead).
        property real posterH: root.sh * 0.245
        property real posterW: posterH * (itemListRoot.gridLandscape ? 16 / 9 : 2 / 3)
        cellHeight: root.sh * 0.2625
        cellWidth: posterW + root.sw * 0.0078125 //5

        // Arrow keys use GridView's built-in flow-aware navigation.
        Keys.onReturnPressed: itemListRoot.selectItem()
        Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                itemListRoot.goBack()
                event.accepted = true
            }
        }

        delegate: Item {
            width: coverGrid.cellWidth
            height: coverGrid.cellHeight

            // Touch: first tap highlights the poster, tapping the highlighted
            // poster activates it (same two-tap pattern as the lists).
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

                // Landscape cards: an episode's still IS 16:9; movies/shows in
                // the same list use their (16:9) fanart. Portrait cells always
                // use the poster.
                // Portrait cells prefer the poster (show/season cover) so
                // Continue Watching episodes show a cover, not a screenshot.
                property string artPath: itemListRoot.gridLandscape
                        ? (modelData.type === "episode"
                           ? (modelData.thumb || modelData.art || "")
                           : (modelData.art || modelData.thumb || ""))
                        : (modelData.poster || modelData.thumb || "")

                Image {
                    id: posterImage
                    anchors.fill: parent
                    anchors.margins: posterBox.border.width
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    source: posterBox.artPath
                            ? plexBackend.image_url(posterBox.artPath,
                                                    Math.round(width), Math.round(height))
                            : ""
                }

                // Poster-less items (or art still loading) show the title.
                Text {
                    visible: posterImage.status !== Image.Ready
                    anchors.fill: parent
                    anchors.margins: root.sw * 0.0078125 //5
                    text: modelData.title || ""
                    color: coverGrid.currentIndex === index ? root.accentColor : root.secondaryColor
                    font.family: root.globalFont
                    font.capitalization: Font.AllUppercase
                    wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    elide: Text.ElideRight
                    font.pixelSize: root.sh * 0.0291667 //14
                }

                // Watch-progress bar for in-progress items (Continue Watching),
                // pinned to the poster's bottom edge.
                Rectangle {
                    visible: (modelData.viewOffset || 0) > 0 && (modelData.duration || 0) > 0
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.margins: posterBox.border.width
                    height: Math.max(2, Math.round(root.sh * 0.008))
                    color: Qt.rgba(0, 0, 0, 0.55)
                    Rectangle {
                        anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                        width: parent.width * Math.min(1, (modelData.viewOffset || 0) / Math.max(1, modelData.duration || 0))
                        color: root.accentColor
                    }
                }
            }
        }
    }

    // Body
    ListView {
        id: itemList
        model: items
        visible: !coverMode
        opacity: letterNavActive ? 0.3 : 1
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.25 //120
        anchors.leftMargin: root.sw * 0.115625 //74
        width: showLetterNav ? root.sw * 0.671875 : root.sw * 0.76875 //430 or 492
        height: root.sh * 0.525 //252
        clip: true
        focus: !coverMode

        Keys.onUpPressed: if (currentIndex > 0) currentIndex--
        Keys.onDownPressed: if (currentIndex < count - 1) currentIndex++
        Keys.onReturnPressed: itemListRoot.selectItem()
        Keys.onPressed: function(event) {
            // PgUp/PgDown page the list a screenful at a time, cursor kept in place.
            if (event.key === Qt.Key_PageDown) { NavUtil.page(itemList, 1); event.accepted = true; return }
            if (event.key === Qt.Key_PageUp) { NavUtil.page(itemList, -1); event.accepted = true; return }
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                itemListRoot.goBack()
                event.accepted = true
            } else if (event.key === Qt.Key_Right && showLetterNav && letterIndex.length > 0) {
                var curLetter = sortKey((items[itemList.currentIndex] && items[itemList.currentIndex].title) || "")
                for (var i = 0; i < letterIndex.length; i++) {
                    if (letterIndex[i].letter === curLetter) { letterList.currentIndex = i; break }
                }
                letterNavActive = true
                letterList.forceActiveFocus()
                event.accepted = true
            }
        }

        delegate: Item {
            width: itemList.width
            height: root.sh * 0.0583333 //28

            // Touch: first tap highlights the row (leaving letter nav if it is
            // active), tapping the highlighted row activates it via a
            // synthesized Enter (same path as the keyboard).
            MouseArea {
                anchors.fill: parent
                onClicked: {
                    if (letterNavActive) {
                        letterNavActive = false
                        itemList.forceActiveFocus()
                        itemList.currentIndex = index
                        return
                    }
                    if (itemList.currentIndex === index) inputManager.touchKey("select")
                    else itemList.currentIndex = index
                }
            }

            Item {
                id: textClip
                width: Math.min(rowText.implicitWidth, itemList.width)
                height: parent.height
                clip: true

                Rectangle {
                    color: root.accentColor
                    anchors.fill: rowText
                    visible: itemList.currentIndex === index && !letterNavActive
                }

                Text {
                    id: rowText
                    text: {
                        var base = (modelData.type === "episode" && modelData.grandparentTitle)
                                   ? (modelData.grandparentTitle + ": " + (modelData.title || ""))
                                   : (modelData.title || "")
                        return modelData.editionTitle ? base + " (" + modelData.editionTitle + ")" : base
                    }
                    color: (itemList.currentIndex === index && !letterNavActive)
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
                    running: (itemList.currentIndex === index) &&
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

    // Letter navigation panel (title list only — the grid has no room for it)
    ListView {
        id: letterList
        model: letterIndex
        visible: showLetterNav && !coverMode && letterIndex.length > 0
        opacity: letterNavActive ? 1.0 : 0.3
        anchors.left: itemList.right
        anchors.leftMargin: root.sw * 0.0375 //24
        anchors.top: itemList.top
        width: root.sw * 0.0328125 //21
        height: itemList.height
        clip: true
        focus: false

        Keys.onUpPressed: {
            if (currentIndex > 0) {
                currentIndex--
                itemList.currentIndex = letterIndex[currentIndex].firstIndex
                itemList.positionViewAtIndex(itemList.currentIndex, ListView.Beginning)
            }
        }
        Keys.onDownPressed: {
            if (currentIndex < count - 1) {
                currentIndex++
                itemList.currentIndex = letterIndex[currentIndex].firstIndex
                itemList.positionViewAtIndex(itemList.currentIndex, ListView.Beginning)
            }
        }
        Keys.onReturnPressed: {
            letterNavActive = false
            itemList.forceActiveFocus()
        }
        Keys.onLeftPressed: {
            letterNavActive = false
            itemList.forceActiveFocus()
        }
        Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                letterNavActive = false
                itemList.forceActiveFocus()
                event.accepted = true
            }
        }

        delegate: Item {
            width: letterList.width
            height: root.sh * 0.04375 //21

            Rectangle {
                color: root.accentColor
                anchors.fill: parent
                visible: letterList.currentIndex === index && letterNavActive
            }

            Text {
                text: modelData.letter
                color: (letterList.currentIndex === index && letterNavActive)
                       ? root.surfaceColor : root.primaryColor
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                font.pixelSize: root.sh * 0.0354167 //17
                anchors.verticalCenter: parent.verticalCenter
                anchors.right: parent.right
                rightPadding: root.sw * 0.009375 //6
                topPadding: root.sh * 0.0041667 //2
                bottomPadding: root.sh * 0.00625 //3
            }
        }
    }

    // Footer
    Text {
        id: footer
        text: showLetterNav
              ? root.hints.back + ":BACK " + root.hints.navigate + ":NAVIGATE " + root.hints.browse + ":BROWSE " + root.hints.select + ":SELECT"
              : root.hints.back + ":BACK " + root.hints.navigate + ":NAVIGATE " + root.hints.select + ":SELECT"
        color: root.tertiaryColor
        font.family: root.globalFont
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.bottomMargin: root.sh * 0.1041667 //50
        anchors.leftMargin: root.sw * 0.125 //80
        font.pixelSize: root.sh * 0.0333333 //16
    }
}
