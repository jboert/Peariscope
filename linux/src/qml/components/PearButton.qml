import QtQuick

Rectangle {
    id: root

    property string text: ""
    property color bgColor: "#2f2f2f"
    property color textColor: "#ffffff"
    property color hoverColor: "#3e3e3e"
    property color pressColor: "#2a2a2a"
    property int fontSize: 13
    property bool bold: true

    signal clicked()

    height: 36
    radius: 8
    color: mouseArea.pressed ? pressColor
         : mouseArea.containsMouse ? hoverColor
         : bgColor

    Behavior on color { ColorAnimation { duration: 80 } }

    Text {
        anchors.centerIn: parent
        text: root.text
        color: root.textColor
        font.pixelSize: root.fontSize
        font.weight: root.bold ? Font.DemiBold : Font.Normal
        font.family: "sans-serif"
    }

    MouseArea {
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.clicked()
    }
}
