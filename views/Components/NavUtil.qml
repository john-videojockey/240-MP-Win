pragma Singleton
import QtQuick

// Shared list navigation helpers. page() jumps a ListView by one screenful in
// the given direction (+1 down / -1 up) while keeping the highlighted row at
// the same on-screen position, so paging through a long file/folder list feels
// like flipping pages rather than scrolling row by row.
QtObject {
    function page(list, dir) {
        if (!list || list.count <= 0) return
        var rowH = list.contentHeight / list.count   // fixed-height rows
        if (rowH <= 0) return
        var pageSize = Math.max(1, Math.floor(list.height / rowH))
        var onScreen = list.currentIndex * rowH - list.contentY   // cursor's y within the viewport
        var ni = Math.max(0, Math.min(list.count - 1, list.currentIndex + dir * pageSize))
        list.currentIndex = ni
        var maxY = Math.max(0, list.contentHeight - list.height)
        list.contentY = Math.max(0, Math.min(maxY, ni * rowH - onScreen))
    }
}
