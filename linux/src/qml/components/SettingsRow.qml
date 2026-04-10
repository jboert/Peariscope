import QtQuick

Item {
    id: root

    property string title: ""
    property string subtitle: ""
    property color iconColor: "#9BE238"
    property string iconChar: ""
    property bool checked: false

    signal toggled()

    height: 42
    width: parent ? parent.width : 300

    // Icon circle
    Rectangle {
        id: iconCircle
        width: 22; height: 22; radius: 11
        color: root.iconColor
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter

        Text {
            anchors.centerIn: parent
            text: root.iconChar
            color: "#ffffff"
            font.pixelSize: 9
            font.weight: Font.Bold
            font.family: "sans-serif"
        }
    }

    // Labels
    Column {
        anchors.left: iconCircle.right
        anchors.leftMargin: 8
        anchors.verticalCenter: parent.verticalCenter
        anchors.right: toggle.left
        anchors.rightMargin: 6

        Text {
            text: root.title
            color: "#ffffff"
            font.pixelSize: 13
            font.family: "sans-serif"
            elide: Text.ElideRight
            width: parent.width
        }
        Text {
            visible: root.subtitle !== ""
            text: root.subtitle
            color: "#8a8a8a"
            font.pixelSize: 10
            font.family: "sans-serif"
            elide: Text.ElideRight
            width: parent.width
        }
    }

    // Toggle
    PearToggle {
        id: toggle
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        checked: root.checked
        onToggled: root.toggled()
    }
}
