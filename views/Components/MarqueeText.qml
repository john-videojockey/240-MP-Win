import QtQuick

// Single-line label that scrolls horizontally (marquee) while `active` and the
// text is wider than the box; otherwise it shows elided. Lets a highlighted
// Cast & Extras card reveal a long title / character name in its narrow column.
Item {
    id: control

    property alias text: label.text
    property color color: "white"
    property real pixelSize: 12
    property bool active: false        // scroll when true (e.g. the focused card)

    clip: true
    implicitHeight: label.implicitHeight
    readonly property bool overflow: label.implicitWidth > width

    Text {
        id: label
        color: control.color
        font.family: root.globalFont
        font.pixelSize: control.pixelSize
        font.capitalization: Font.AllUppercase
        maximumLineCount: 1
        // Full width (unelided) while scrolling so the tail exists to reveal.
        elide: (control.active && control.overflow) ? Text.ElideNone : Text.ElideRight
        width: (control.active && control.overflow) ? implicitWidth : control.width

        // Pause, slide left to expose the tail, pause, slide back — repeat.
        SequentialAnimation on x {
            running: control.active && control.overflow
            loops: Animation.Infinite
            PauseAnimation { duration: 700 }
            NumberAnimation {
                to: Math.min(0, control.width - label.implicitWidth)
                duration: Math.max(600, (label.implicitWidth - control.width) * 12)
                easing.type: Easing.InOutQuad
            }
            PauseAnimation { duration: 900 }
            NumberAnimation { to: 0; duration: 450; easing.type: Easing.InOutQuad }
        }
    }

    // Snap back to the start when it stops scrolling (deselected).
    onActiveChanged: if (!active) label.x = 0
}
