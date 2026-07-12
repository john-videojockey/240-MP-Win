import QtQuick

// "LOADING" with dots cycling every third of a second while visible.
// Trailing spaces keep the width constant (VCR OSD Mono is monospace), so a
// centered instance doesn't jitter as the dots animate.
Text {
    id: loadingText

    property int dotCount: 3

    text: "LOADING" + ".".repeat(dotCount) + " ".repeat(3 - dotCount)
    color: root.tertiaryColor
    font.family: root.globalFont
    font.pixelSize: root.sh * 0.05 //24

    Timer {
        interval: 333
        running: loadingText.visible
        repeat: true
        onTriggered: loadingText.dotCount = (loadingText.dotCount + 1) % 4
    }
}
