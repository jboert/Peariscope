import QtQuick

Rectangle {
    id: root
    color: "#2a2a2a"
    radius: 10
    border.width: 1
    border.color: "#2f2f2f"

    default property alias content: contentItem.data

    Item {
        id: contentItem
        anchors.fill: parent
        anchors.margins: 10
    }
}
