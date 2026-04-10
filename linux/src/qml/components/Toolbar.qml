import QtQuick

Rectangle {
    id: root

    signal connectClicked()
    signal quitClicked()

    height: 32
    color: "transparent"

    // Top separator
    Rectangle {
        width: parent.width; height: 1; y: 0
        color: "#2f2f2f"
    }

    Row {
        anchors.fill: parent
        anchors.topMargin: 1

        // Connect button
        Rectangle {
            width: parent.width / 2
            height: parent.height - 1
            color: connectMouse.pressed ? "#2f2f2f" :
                   connectMouse.containsMouse ? "#2a2a2a" : "transparent"

            Row {
                anchors.centerIn: parent
                spacing: 4

                // Display icon
                Canvas {
                    width: 11; height: 10
                    anchors.verticalCenter: parent.verticalCenter
                    onPaint: {
                        var ctx = getContext("2d")
                        ctx.clearRect(0, 0, width, height)
                        ctx.strokeStyle = "#888888"
                        ctx.lineWidth = 1.2
                        ctx.strokeRect(0.5, 0.5, 10, 7)
                        ctx.beginPath()
                        ctx.moveTo(5.5, 7.5); ctx.lineTo(5.5, 9.5); ctx.stroke()
                        ctx.beginPath()
                        ctx.moveTo(3, 9.5); ctx.lineTo(8, 9.5); ctx.stroke()
                    }
                }

                Text {
                    text: "Connect"
                    color: "#a0a0a0"
                    font.pixelSize: 11
                    font.weight: Font.Medium
                    font.family: "sans-serif"
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            MouseArea {
                id: connectMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.connectClicked()
            }
        }

        // Vertical separator
        Rectangle {
            width: 1; height: parent.height - 8; color: "#2f2f2f"
            anchors.verticalCenter: parent.verticalCenter
        }

        // Quit button
        Rectangle {
            width: parent.width / 2 - 1
            height: parent.height - 1
            color: quitMouse.pressed ? "#2f2f2f" :
                   quitMouse.containsMouse ? "#2a2a2a" : "transparent"

            Row {
                anchors.centerIn: parent
                spacing: 4

                // Power icon
                Canvas {
                    width: 10; height: 11
                    anchors.verticalCenter: parent.verticalCenter
                    onPaint: {
                        var ctx = getContext("2d")
                        ctx.clearRect(0, 0, width, height)
                        ctx.strokeStyle = "#888888"
                        ctx.lineWidth = 1.2
                        var cx = 5, cy = 6
                        ctx.beginPath()
                        ctx.arc(cx, cy, 4, -2.27, 0.7, false)
                        ctx.stroke()
                        ctx.beginPath()
                        ctx.moveTo(cx, cy - 1.5); ctx.lineTo(cx, cy - 5.5); ctx.stroke()
                    }
                }

                Text {
                    text: "Quit"
                    color: "#a0a0a0"
                    font.pixelSize: 11
                    font.weight: Font.Medium
                    font.family: "sans-serif"
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            MouseArea {
                id: quitMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.quitClicked()
            }
        }
    }
}
