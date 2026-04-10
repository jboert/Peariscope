import QtQuick

Rectangle {
    id: root

    property string displayLabel: ""
    property string timestamp: ""
    property bool pinned: false
    property int onlineStatus: 0

    signal connectClicked()
    signal deleteClicked()
    signal pinClicked()
    signal renameClicked()

    height: 42
    color: hoverArea.containsMouse ? "#2a2a2a" : "transparent"
    radius: 6

    Behavior on color { ColorAnimation { duration: 80 } }

    // Full-width hover detection (behind everything)
    MouseArea {
        id: hoverArea
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
    }

    // Clickable area (excludes action buttons)
    MouseArea {
        id: mouseArea
        anchors.fill: parent
        anchors.rightMargin: 76
        hoverEnabled: false
        cursorShape: Qt.PointingHandCursor
        onClicked: root.connectClicked()
    }

    // Online status dot
    Rectangle {
        id: statusDot
        width: 6; height: 6; radius: 3
        color: root.onlineStatus === 1 ? "#9BE238" : "#505050"
        anchors.left: parent.left
        anchors.leftMargin: 4
        anchors.verticalCenter: parent.verticalCenter
    }

    // Name and timestamp
    Column {
        anchors.left: statusDot.right
        anchors.leftMargin: 8
        anchors.right: actionRow.left
        anchors.rightMargin: 6
        anchors.verticalCenter: parent.verticalCenter
        spacing: 1

        Text {
            text: root.displayLabel
            color: "#ffffff"
            font.pixelSize: 12
            font.weight: root.displayLabel === root.timestamp ? Font.Normal : Font.DemiBold
            font.family: "sans-serif"
            elide: Text.ElideRight
            width: parent.width
        }
        Text {
            text: root.timestamp
            color: "#8a8a8a"
            font.pixelSize: 9
            font.family: "sans-serif"
        }
    }

    // Action buttons
    Row {
        id: actionRow
        anchors.right: parent.right
        anchors.rightMargin: 2
        anchors.verticalCenter: parent.verticalCenter
        spacing: 2
        visible: hoverArea.containsMouse

        Rectangle {
            width: 22; height: 22; radius: 4
            color: root.pinned ? "#9BE238" : "#2f2f2f"
            Text {
                anchors.centerIn: parent
                text: "\u{1F4CC}"
                font.pixelSize: 9
                color: root.pinned ? "#141414" : "#b0b0b0"
            }
            MouseArea {
                id: pinBtnArea
                anchors.fill: parent; hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.pinClicked()
            }
        }

        Rectangle {
            width: 22; height: 22; radius: 4
            color: renameBtnArea.containsMouse ? "#3e3e3e" : "#2f2f2f"
            Text {
                anchors.centerIn: parent; text: "\u270F"; font.pixelSize: 9
                color: "#b0b0b0"
            }
            MouseArea {
                id: renameBtnArea
                anchors.fill: parent; hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.renameClicked()
            }
        }

        Rectangle {
            width: 22; height: 22; radius: 4
            color: delBtnArea.containsMouse ? "#3e3e3e" : "#2f2f2f"
            Text {
                anchors.centerIn: parent; text: "\u2715"; font.pixelSize: 9
                color: "#FF453A"
            }
            MouseArea {
                id: delBtnArea
                anchors.fill: parent; hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.deleteClicked()
            }
        }
    }
}
