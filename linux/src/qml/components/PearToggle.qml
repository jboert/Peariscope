import QtQuick

Item {
    id: root

    property bool checked: false
    signal toggled()

    width: 40
    height: 22

    Rectangle {
        id: track
        anchors.fill: parent
        radius: height / 2
        color: root.checked ? "#9BE238" : "#2f2f2f"
        border.width: root.checked ? 0 : 1
        border.color: "#323232"

        Behavior on color { ColorAnimation { duration: 150 } }

        Rectangle {
            id: knob
            width: parent.height - 6
            height: width
            radius: width / 2
            color: "#ffffff"
            y: 3
            x: root.checked ? parent.width - width - 3 : 3

            Behavior on x { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
        }
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: {
            root.checked = !root.checked
            root.toggled()
        }
    }
}
