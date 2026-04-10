import QtQuick

Rectangle {
    id: root

    property string text: ""
    property color bgColor: "#1f3318"
    property color textColor: "#9BE238"
    property bool showDot: false

    height: 22
    width: badgeRow.width + 20
    radius: height / 2
    color: bgColor

    Row {
        id: badgeRow
        anchors.centerIn: parent
        spacing: 5

        // Green dot with subtle glow
        Item {
            visible: root.showDot
            width: 6; height: 6
            anchors.verticalCenter: parent.verticalCenter

            // Glow
            Rectangle {
                anchors.centerIn: parent
                width: 10; height: 10; radius: 5
                color: "#2d4d1e"
            }
            Rectangle {
                anchors.centerIn: parent
                width: 6; height: 6; radius: 3
                color: root.textColor
            }
        }

        Text {
            text: root.text
            color: root.textColor
            font.pixelSize: 11
            font.weight: Font.Medium
            font.family: "sans-serif"
            font.letterSpacing: 2
        }
    }
}
