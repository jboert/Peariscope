import QtQuick

Item {
    id: root

    property string value: "0"
    property string label: ""

    width: 80
    height: 36

    Column {
        anchors.centerIn: parent
        spacing: 1

        Text {
            text: root.value
            color: "#ffffff"
            font.pixelSize: 14
            font.family: "sans-serif"
            anchors.horizontalCenter: parent.horizontalCenter
        }
        Text {
            text: root.label
            color: "#cccccc"
            font.pixelSize: 9
            font.family: "sans-serif"
            anchors.horizontalCenter: parent.horizontalCenter
        }
    }
}
