import QtQuick

Rectangle {
    id: root

    signal settingsClicked()

    height: 40
    color: "transparent"

    // App icon (22x22)
    Image {
        anchors.left: parent.left
        anchors.leftMargin: 10
        anchors.verticalCenter: parent.verticalCenter
        width: 22; height: 22
        source: "qrc:/Peariscope/assets/app-logo@3x.png"
        sourceSize: Qt.size(22, 22)
        fillMode: Image.PreserveAspectFit
        smooth: true
    }

    // "PEARISCOPE" — uppercase, letter-spaced, bold
    Text {
        anchors.left: parent.left
        anchors.leftMargin: 38
        anchors.verticalCenter: parent.verticalCenter
        text: "PEARISCOPE"
        color: "#ffffff"
        font.pixelSize: 13
        font.weight: Font.Bold
        font.family: "sans-serif"
        font.letterSpacing: 1
    }

    // Minimize button
    Rectangle {
        width: 26; height: 26; radius: 4
        anchors.right: settingsBtn.left
        anchors.rightMargin: 2
        anchors.verticalCenter: parent.verticalCenter
        color: minimizeMouse.containsMouse ? "#2f2f2f" : "transparent"

        Text {
            anchors.centerIn: parent
            text: "\u2013"  // en-dash as minimize icon
            color: "#a0a0a0"
            font.pixelSize: 16
            font.weight: Font.Bold
        }

        MouseArea {
            id: minimizeMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.Window.window.showMinimized()
        }
    }

    // Settings gear icon — gray, 14px
    Rectangle {
        id: settingsBtn
        width: 26; height: 26; radius: 4
        anchors.right: parent.right
        anchors.rightMargin: 10
        anchors.verticalCenter: parent.verticalCenter
        color: gearMouse.containsMouse ? "#2f2f2f" : "transparent"

        Canvas {
            anchors.centerIn: parent
            width: 14; height: 14
            onPaint: {
                var ctx = getContext("2d")
                ctx.clearRect(0, 0, width, height)
                ctx.strokeStyle = "#888888"
                ctx.lineWidth = 1.4
                var cx = width / 2, cy = height / 2
                ctx.beginPath()
                ctx.arc(cx, cy, 3.5, 0, Math.PI * 2)
                ctx.stroke()
                for (var i = 0; i < 8; i++) {
                    var angle = i * Math.PI / 4
                    ctx.beginPath()
                    ctx.moveTo(cx + 4 * Math.cos(angle), cy + 4 * Math.sin(angle))
                    ctx.lineTo(cx + 6 * Math.cos(angle), cy + 6 * Math.sin(angle))
                    ctx.stroke()
                }
            }
        }

        MouseArea {
            id: gearMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.settingsClicked()
        }
    }

    // Bottom separator
    Rectangle {
        anchors.bottom: parent.bottom
        width: parent.width; height: 1
        color: "#2f2f2f"
    }
}
