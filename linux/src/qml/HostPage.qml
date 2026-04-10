import QtQuick
import Peariscope

Item {
    id: root

    Flickable {
        anchors.fill: parent
        contentHeight: contentCol.height + 16
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
            id: contentCol
            width: parent.width
            topPadding: 10

            // ============= IDLE STATE =============
            Item {
                visible: AppController.appMode === 0
                width: parent.width
                height: idleCol.height

                Column {
                    id: idleCol
                    width: parent.width
                    spacing: 10

                    Item { width: 1; height: 20 }

                    // App logo
                    Image {
                        width: 64; height: 64
                        anchors.horizontalCenter: parent.horizontalCenter
                        source: "qrc:/Peariscope/assets/app-logo@3x.png"
                        sourceSize: Qt.size(64, 64)
                        fillMode: Image.PreserveAspectFit
                        smooth: true
                    }

                    Text {
                        text: "Peariscope"
                        color: "#ffffff"
                        font.pixelSize: 15
                        font.weight: Font.DemiBold
                        font.family: "sans-serif"
                        anchors.horizontalCenter: parent.horizontalCenter
                    }

                    Text {
                        text: "P2P Remote Desktop"
                        color: "#8a8a8a"
                        font.pixelSize: 12
                        font.family: "sans-serif"
                        anchors.horizontalCenter: parent.horizontalCenter
                    }

                    Item { width: 1; height: 12 }

                    PearButton {
                        width: parent.width - 40
                        height: 38
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: "Start Sharing"
                        bgColor: "#9BE238"
                        textColor: "#141414"
                        hoverColor: "#abed5c"
                        pressColor: "#87c530"
                        fontSize: 13
                        onClicked: AppController.startHosting()
                    }
                }
            }

            // ============= HOSTING STATE =============
            Item {
                visible: AppController.appMode === 1
                width: parent.width
                height: hostingCol.height

                Column {
                    id: hostingCol
                    width: parent.width
                    spacing: 6

                    // SHARING badge
                    Item {
                        width: parent.width; height: 24
                        PearBadge {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: "SHARING"
                            showDot: true
                        }
                    }

                    // Stats row — bordered container, monospaced values
                    Rectangle {
                        width: parent.width - 20
                        height: 48
                        anchors.horizontalCenter: parent.horizontalCenter
                        color: "transparent"
                        radius: 10
                        border.width: 1
                        border.color: "#2f2f2f"

                        Row {
                            anchors.fill: parent

                            // FPS
                            Item {
                                width: parent.width / 3; height: parent.height
                                Column {
                                    anchors.centerIn: parent
                                    spacing: 1
                                    Text {
                                        text: Math.round(AppController.currentFps).toString()
                                        color: "#ffffff"
                                        font.pixelSize: 15
                                        font.weight: Font.DemiBold
                                        font.family: "monospace"
                                        anchors.horizontalCenter: parent.horizontalCenter
                                    }
                                    Text {
                                        text: "FPS"
                                        color: "#8a8a8a"
                                        font.pixelSize: 9
                                        font.weight: Font.Bold
                                        font.family: "sans-serif"
                                        font.letterSpacing: 0.5
                                        anchors.horizontalCenter: parent.horizontalCenter
                                    }
                                }
                            }

                            // BPS
                            Item {
                                width: parent.width / 3; height: parent.height
                                Column {
                                    anchors.centerIn: parent
                                    spacing: 1
                                    Text {
                                        text: (AppController.currentBitrate / 1000000).toFixed(1) + "M"
                                        color: "#ffffff"
                                        font.pixelSize: 15
                                        font.weight: Font.DemiBold
                                        font.family: "monospace"
                                        anchors.horizontalCenter: parent.horizontalCenter
                                    }
                                    Text {
                                        text: "BPS"
                                        color: "#8a8a8a"
                                        font.pixelSize: 9
                                        font.weight: Font.Bold
                                        font.family: "sans-serif"
                                        font.letterSpacing: 0.5
                                        anchors.horizontalCenter: parent.horizontalCenter
                                    }
                                }
                            }

                            // VIEWERS
                            Item {
                                width: parent.width / 3; height: parent.height
                                Column {
                                    anchors.centerIn: parent
                                    spacing: 1
                                    Text {
                                        text: AppController.peerCount.toString()
                                        color: "#ffffff"
                                        font.pixelSize: 15
                                        font.weight: Font.DemiBold
                                        font.family: "monospace"
                                        anchors.horizontalCenter: parent.horizontalCenter
                                    }
                                    Text {
                                        text: "VIEWERS"
                                        color: "#8a8a8a"
                                        font.pixelSize: 9
                                        font.weight: Font.Bold
                                        font.family: "sans-serif"
                                        font.letterSpacing: 0.5
                                        anchors.horizontalCenter: parent.horizontalCenter
                                    }
                                }
                            }
                        }
                    }

                    Item { width: 1; height: 2 }

                    // Connection Code Card — side-by-side: QR left, info right
                    Rectangle {
                        id: codeCard
                        width: parent.width - 20
                        height: AppController.isCodeRevealed ? 160 : 80
                        anchors.horizontalCenter: parent.horizontalCenter
                        color: "#2a2a2a"
                        radius: 10
                        border.width: 1
                        border.color: "#2f2f2f"

                        Behavior on height { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

                        Row {
                            anchors.fill: parent
                            anchors.margins: 10
                            spacing: 10

                            // QR code (left side, ~80x80)
                            Item {
                                visible: AppController.isCodeRevealed && AppController.qrMatrixSize > 0
                                width: 80; height: parent.height

                                Canvas {
                                    id: qrCanvas
                                    anchors.centerIn: parent
                                    width: 80; height: 80

                                    property string matrix: AppController.qrMatrix
                                    property int matrixSize: AppController.qrMatrixSize
                                    onMatrixChanged: requestPaint()
                                    onMatrixSizeChanged: requestPaint()

                                    onPaint: {
                                        var ctx = getContext("2d")
                                        ctx.clearRect(0, 0, width, height)
                                        if (matrixSize <= 0 || matrix.length < matrixSize * matrixSize) return
                                        var modPx = Math.floor(width / (matrixSize + 2))
                                        if (modPx < 1) modPx = 1
                                        var totalPx = modPx * (matrixSize + 2)
                                        var ox = (width - totalPx) / 2, oy = (height - totalPx) / 2
                                        ctx.fillStyle = "#ffffff"
                                        ctx.fillRect(ox, oy, totalPx, totalPx)
                                        ctx.fillStyle = "#000000"
                                        var offset = modPx
                                        for (var my = 0; my < matrixSize; my++) {
                                            for (var mx = 0; mx < matrixSize; mx++) {
                                                if (matrix.charAt(my * matrixSize + mx) === '1')
                                                    ctx.fillRect(ox + offset + mx * modPx, oy + offset + my * modPx, modPx, modPx)
                                            }
                                        }
                                    }
                                }
                            }

                            // Right side: label + code
                            Column {
                                width: parent.width - (AppController.isCodeRevealed && AppController.qrMatrixSize > 0 ? 90 : 0)
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 4

                                Text {
                                    text: "Connection Code"
                                    color: "#8a8a8a"
                                    font.pixelSize: 12
                                    font.weight: Font.Medium
                                    font.family: "sans-serif"
                                }

                                Text {
                                    visible: AppController.isCodeRevealed && AppController.connectionCode !== ""
                                    text: {
                                        var words = AppController.connectionCode.split(/[\s-]+/)
                                        var lines = []
                                        for (var i = 0; i < words.length; i += 4)
                                            lines.push(words.slice(i, i + 4).join(" "))
                                        return lines.join("\n")
                                    }
                                    color: "#9BE238"
                                    font.pixelSize: 11
                                    font.family: "monospace"
                                    lineHeight: 1.4
                                    width: parent.width
                                }

                                Text {
                                    visible: !AppController.isCodeRevealed
                                    text: "Tap eye to reveal"
                                    color: "#8a8a8a"
                                    font.pixelSize: 12
                                    font.family: "sans-serif"
                                }
                            }
                        }

                        // Action buttons row — bottom right
                        Row {
                            anchors.bottom: parent.bottom
                            anchors.bottomMargin: 8
                            anchors.right: parent.right
                            anchors.rightMargin: 10
                            spacing: 6

                            // Eye (reveal/hide)
                            Rectangle {
                                width: 28; height: 28; radius: 6
                                color: AppController.isCodeRevealed ? "#9BE238" :
                                       eyeArea.containsMouse ? "#3e3e3e" : "#323232"

                                Canvas {
                                    anchors.centerIn: parent
                                    width: 11; height: 11
                                    onPaint: {
                                        var ctx = getContext("2d")
                                        ctx.clearRect(0, 0, width, height)
                                        var ic = AppController.isCodeRevealed ? "#141414" : "#ffffff"
                                        ctx.strokeStyle = ic
                                        ctx.lineWidth = 1.2
                                        var cx = 5.5, cy = 5.5
                                        ctx.beginPath()
                                        ctx.moveTo(0, cy)
                                        ctx.bezierCurveTo(2, cy - 4, 9, cy - 4, 11, cy)
                                        ctx.stroke()
                                        ctx.beginPath()
                                        ctx.moveTo(11, cy)
                                        ctx.bezierCurveTo(9, cy + 4, 2, cy + 4, 0, cy)
                                        ctx.stroke()
                                        ctx.beginPath()
                                        ctx.arc(cx, cy, 2.5, 0, Math.PI * 2)
                                        ctx.stroke()
                                        ctx.fillStyle = ic
                                        ctx.beginPath()
                                        ctx.arc(cx, cy, 1, 0, Math.PI * 2)
                                        ctx.fill()
                                        if (!AppController.isCodeRevealed) {
                                            ctx.lineWidth = 1.5
                                            ctx.beginPath()
                                            ctx.moveTo(1, 9)
                                            ctx.lineTo(10, 2)
                                            ctx.stroke()
                                        }
                                    }
                                }
                                MouseArea {
                                    id: eyeArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: AppController.toggleCodeReveal()
                                }
                            }

                            // Copy
                            Rectangle {
                                width: 28; height: 28; radius: 6
                                color: copyArea.containsMouse ? "#3e3e3e" : "#323232"
                                Canvas {
                                    anchors.centerIn: parent
                                    width: 11; height: 11
                                    onPaint: {
                                        var ctx = getContext("2d")
                                        ctx.clearRect(0, 0, width, height)
                                        ctx.strokeStyle = "#ffffff"
                                        ctx.lineWidth = 1.2
                                        ctx.strokeRect(3, 0, 8, 8)
                                        ctx.strokeRect(0, 3, 8, 8)
                                    }
                                }
                                MouseArea {
                                    id: copyArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: AppController.copyConnectionCode()
                                }
                            }

                            // Refresh
                            Rectangle {
                                width: 28; height: 28; radius: 6
                                color: newCodeArea.containsMouse ? "#3e3e3e" : "#323232"
                                Canvas {
                                    anchors.centerIn: parent
                                    width: 11; height: 11
                                    onPaint: {
                                        var ctx = getContext("2d")
                                        ctx.clearRect(0, 0, width, height)
                                        ctx.strokeStyle = "#ffffff"
                                        ctx.lineWidth = 1.3
                                        var cx = 5.5, cy = 5.5
                                        ctx.beginPath()
                                        ctx.arc(cx, cy, 4, Math.PI * 1.22, Math.PI * 2.11, false)
                                        ctx.stroke()
                                        ctx.beginPath()
                                        ctx.arc(cx, cy, 4, Math.PI * 0.22, Math.PI * 1.11, false)
                                        ctx.stroke()
                                        ctx.beginPath()
                                        ctx.moveTo(cx + 3.5, cy - 2)
                                        ctx.lineTo(cx + 5.5, cy - 3.5)
                                        ctx.lineTo(cx + 2.5, cy - 4.5)
                                        ctx.stroke()
                                    }
                                }
                                MouseArea {
                                    id: newCodeArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: AppController.generateNewCode()
                                }
                            }
                        }
                    }

                    Item { width: 1; height: 2 }

                    // Codec/Resolution row
                    Row {
                        width: parent.width - 20
                        anchors.horizontalCenter: parent.horizontalCenter
                        height: 22

                        // H.265 (active) — green dim bg, green text
                        Rectangle {
                            width: 44; height: 20; radius: 10
                            color: "#1f3318"
                            Text {
                                anchors.centerIn: parent
                                text: "H.265"
                                color: "#9BE238"
                                font.pixelSize: 9
                                font.weight: Font.Bold
                                font.family: "monospace"
                            }
                        }

                        // Resolution (center)
                        Text {
                            width: parent.width - 88
                            height: 20
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                            text: AppController.captureWidth > 0
                                  ? AppController.captureWidth + "x" + AppController.captureHeight : "--"
                            color: "#8a8a8a"
                            font.pixelSize: 11
                            font.family: "monospace"
                        }

                        // H.264 (inactive) — subtle gray bg, secondary text
                        Rectangle {
                            width: 44; height: 20; radius: 10
                            color: "#2a2a2a"
                            Text {
                                anchors.centerIn: parent
                                text: "H.264"
                                color: "#666666"
                                font.pixelSize: 9
                                font.family: "monospace"
                            }
                        }
                    }

                    Item { width: 1; height: 2 }

                    // Peer Connecting Card
                    PeerConnectingCard {
                        visible: AppController.hasPendingPeer
                        width: parent.width - 20
                        anchors.horizontalCenter: parent.horizontalCenter
                        peerKey: AppController.pendingPeerKey
                        pin: AppController.pendingPeerPin
                        onApproveClicked: AppController.approvePeer()
                        onRejectClicked: AppController.rejectPeer()
                    }
                }
            }

            // Spacer
            Item { width: 1; height: 8 }

            // Stop Sharing button (hosting only)
            PearButton {
                visible: AppController.appMode === 1
                width: parent.width - 20
                height: 36
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Stop Sharing"
                bgColor: "#cc3333"
                textColor: "#ffffff"
                hoverColor: "#dd4444"
                pressColor: "#aa2222"
                fontSize: 13
                onClicked: AppController.stopHosting()
            }
        }
    }
}
