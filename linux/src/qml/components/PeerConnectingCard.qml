import QtQuick

PearCard {
    id: root

    property string peerKey: ""
    property string pin: ""

    signal approveClicked()
    signal rejectClicked()

    height: 160

    Column {
        anchors.fill: parent
        spacing: 6

        Text {
            text: "Peer Connecting"
            color: "#ffffff"
            font.pixelSize: 13
            font.weight: Font.DemiBold
            font.family: "sans-serif"
            anchors.horizontalCenter: parent.horizontalCenter
        }

        // Peer key pill
        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            height: 18
            width: keyText.width + 14
            radius: 9
            color: "#2f2f2f"

            Text {
                id: keyText
                anchors.centerIn: parent
                text: root.peerKey.substring(0, 20)
                color: "#b0b0b0"
                font.pixelSize: 9
                font.family: "monospace"
            }
        }

        // Large PIN
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.pin
            color: "#9BE238"
            font.pixelSize: 28
            font.weight: Font.Bold
            font.family: "monospace"
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Verify this PIN matches the viewer"
            color: "#8a8a8a"
            font.pixelSize: 10
            font.family: "sans-serif"
        }

        // Buttons
        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 8
            width: parent.width

            PearButton {
                width: (parent.width - 8) / 2
                height: 32
                text: "Reject"
                bgColor: "#2f2f2f"
                textColor: "#ffffff"
                fontSize: 12
                onClicked: root.rejectClicked()
            }

            PearButton {
                width: (parent.width - 8) / 2
                height: 32
                text: "Approve"
                bgColor: "#9BE238"
                textColor: "#141414"
                fontSize: 12
                onClicked: root.approveClicked()
            }
        }
    }
}
