import QtQuick
import QtQuick.Controls
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
            topPadding: 24

            // Download/connect icon
            Canvas {
                width: 20; height: 24
                anchors.horizontalCenter: parent.horizontalCenter
                onPaint: {
                    var ctx = getContext("2d")
                    ctx.clearRect(0, 0, width, height)
                    ctx.strokeStyle = "#9BE238"
                    ctx.lineWidth = 1.8
                    var cx = 10
                    ctx.beginPath(); ctx.moveTo(cx, 0); ctx.lineTo(cx, 16); ctx.stroke()
                    ctx.beginPath(); ctx.moveTo(cx - 5, 11); ctx.lineTo(cx, 16); ctx.lineTo(cx + 5, 11); ctx.stroke()
                    ctx.beginPath(); ctx.moveTo(cx - 8, 20); ctx.lineTo(cx + 8, 20); ctx.stroke()
                }
            }

            Item { width: 1; height: 10 }

            // ============= VIEWING STATE =============
            Column {
                visible: AppController.appMode === 2
                width: parent.width
                spacing: 6

                // --- Connection Lost State ---
                Column {
                    visible: AppController.connectionLost
                    width: parent.width
                    spacing: 8

                    Item { width: 1; height: 8 }

                    // Warning icon
                    Rectangle {
                        width: 40; height: 40; radius: 20
                        color: "#3d1f1e"
                        anchors.horizontalCenter: parent.horizontalCenter

                        Text {
                            anchors.centerIn: parent
                            text: "!"
                            color: "#FF453A"
                            font.pixelSize: 20
                            font.weight: Font.Bold
                            font.family: "sans-serif"
                        }
                    }

                    Text {
                        text: "Connection Lost"
                        color: "#ffffff"
                        font.pixelSize: 14
                        font.weight: Font.DemiBold
                        font.family: "sans-serif"
                        anchors.horizontalCenter: parent.horizontalCenter
                    }

                    Text {
                        text: "All reconnection attempts failed"
                        color: "#999999"
                        font.pixelSize: 12
                        font.family: "sans-serif"
                        anchors.horizontalCenter: parent.horizontalCenter
                    }

                    Item { width: 1; height: 4 }

                    PearButton {
                        width: parent.width - 20
                        height: 34
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: "Retry"
                        bgColor: "#9BE238"
                        textColor: "#141414"
                        hoverColor: "#abed5c"
                        pressColor: "#87c530"
                        fontSize: 13
                        onClicked: AppController.retryConnection()
                    }

                    PearButton {
                        width: parent.width - 20
                        height: 34
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: "Disconnect"
                        bgColor: "#2f2f2f"
                        textColor: "#ffffff"
                        fontSize: 12
                        onClicked: AppController.disconnect()
                    }
                }

                // --- Reconnecting Banner ---
                Rectangle {
                    visible: AppController.isReconnecting && !AppController.connectionLost
                    width: parent.width - 20
                    height: 44
                    anchors.horizontalCenter: parent.horizontalCenter
                    radius: 8
                    color: "#332a1c"
                    border.width: 1
                    border.color: "#4d3d1e"

                    Row {
                        anchors.centerIn: parent
                        spacing: 8

                        // Animated spinner
                        Rectangle {
                            width: 16; height: 16; radius: 8
                            color: "transparent"
                            border.width: 2
                            border.color: "#664e20"
                            anchors.verticalCenter: parent.verticalCenter

                            Rectangle {
                                width: 16; height: 16; radius: 8
                                color: "transparent"
                                border.width: 2
                                border.color: "transparent"
                                anchors.centerIn: parent

                                // Quarter arc
                                Rectangle {
                                    width: 4; height: 2; radius: 1
                                    color: "#FF9F0A"
                                    x: 10; y: 7
                                }

                                RotationAnimator on rotation {
                                    from: 0; to: 360
                                    duration: 1000
                                    loops: Animation.Infinite
                                    running: AppController.isReconnecting
                                }
                            }
                        }

                        Text {
                            text: "Reconnecting (" + AppController.reconnectAttempt + "/" + AppController.reconnectMaxAttempts + ")..."
                            color: "#FF9F0A"
                            font.pixelSize: 12
                            font.weight: Font.DemiBold
                            font.family: "sans-serif"
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                }

                // --- Normal connecting state ---
                Column {
                    visible: !AppController.connectionLost
                    width: parent.width
                    spacing: 6

                    Text {
                        text: AppController.isReconnecting ? "" : "Connecting..."
                        visible: text !== ""
                        color: "#ffffff"
                        font.pixelSize: 14
                        font.weight: Font.DemiBold
                        font.family: "sans-serif"
                        anchors.horizontalCenter: parent.horizontalCenter
                    }

                    Text {
                        text: AppController.statusText
                        color: "#b0b0b0"
                        font.pixelSize: 12
                        font.family: "sans-serif"
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: parent.width - 20
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                    }

                    // Connection phase detail from worklet
                    Text {
                        visible: AppController.connectStatus !== "" && !AppController.isReconnecting
                        text: AppController.connectStatus
                        color: "#8a8a8a"
                        font.pixelSize: 11
                        font.family: "sans-serif"
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: parent.width - 20
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                    }

                    Text {
                        visible: AppController.lastConnectCode !== ""
                        text: {
                            var code = AppController.lastConnectCode
                            return code.length > 40 ? code.substring(0, 37) + "..." : code
                        }
                        color: "#8a8a8a"
                        font.pixelSize: 10
                        font.family: "monospace"
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: parent.width - 20
                        horizontalAlignment: Text.AlignHCenter
                    }

                    // PIN entry
                    Column {
                        visible: AppController.viewerAwaitingPin
                        width: parent.width
                        spacing: 6

                        Item { width: 1; height: 6 }

                        Text {
                            text: "Enter PIN"
                            color: "#b0b0b0"
                            font.pixelSize: 10
                            font.family: "sans-serif"
                            anchors.horizontalCenter: parent.horizontalCenter
                        }

                        TextField {
                            id: pinInput
                            width: 140; height: 32
                            anchors.horizontalCenter: parent.horizontalCenter
                            color: "#ffffff"
                            font.pixelSize: 16
                            font.weight: Font.Bold
                            font.family: "monospace"
                            horizontalAlignment: TextInput.AlignHCenter
                            maximumLength: 10
                            inputMethodHints: Qt.ImhDigitsOnly
                            onAccepted: AppController.submitViewerPin(text)

                            background: Rectangle {
                                radius: 8
                                color: "#2a2a2a"
                                border.width: 1
                                border.color: "#2f2f2f"
                            }
                        }

                        PearButton {
                            width: 140; height: 32
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: "Submit PIN"
                            bgColor: "#9BE238"
                            textColor: "#141414"
                            fontSize: 12
                            onClicked: AppController.submitViewerPin(pinInput.text)
                        }
                    }

                    Item { width: 1; height: 12 }

                    PearButton {
                        width: parent.width - 20
                        height: 34
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: "Disconnect"
                        bgColor: "#2f2f2f"
                        textColor: "#ffffff"
                        fontSize: 12
                        onClicked: AppController.disconnect()
                    }
                }
            }

            // ============= INPUT FORM STATE =============
            Column {
                visible: AppController.appMode !== 2
                width: parent.width
                spacing: 10

                Text {
                    text: "Connect to Remote Desktop"
                    color: "#ffffff"
                    font.pixelSize: 14
                    font.weight: Font.DemiBold
                    font.family: "sans-serif"
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                // Input field
                TextField {
                    id: codeInput
                    width: parent.width - 20; height: 34
                    anchors.horizontalCenter: parent.horizontalCenter
                    placeholderText: "Enter connection code..."
                    placeholderTextColor: "#5a5a5a"
                    color: "#ffffff"
                    font.pixelSize: 12
                    font.family: "sans-serif"
                    onAccepted: AppController.connectToHost(text)

                    background: Rectangle {
                        radius: 8
                        color: "#2a2a2a"
                        border.width: 1
                        border.color: codeInput.activeFocus ? "#365d24" : "#2f2f2f"
                    }
                }

                PearButton {
                    width: parent.width - 20
                    height: 34
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "Connect"
                    bgColor: "#9BE238"
                    textColor: "#141414"
                    hoverColor: "#abed5c"
                    pressColor: "#87c530"
                    fontSize: 13
                    onClicked: {
                        if (codeInput.text.length > 0) {
                            text = "Connecting..."
                            AppController.connectToHost(codeInput.text)
                        } else {
                            text = "Enter a code first!"
                        }
                    }
                }

                Text {
                    visible: AppController.connectStatus !== ""
                    text: AppController.connectStatus
                    color: "#b0b0b0"
                    font.pixelSize: 12
                    font.family: "sans-serif"
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: parent.width - 20
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                }

                Item { width: 1; height: 2 }

                // Recent connections
                Column {
                    visible: AppController.recentConnections.rowCount() > 0
                    width: parent.width
                    spacing: 0

                    Text {
                        text: "RECENT"
                        color: "#8a8a8a"
                        font.pixelSize: 9
                        font.weight: Font.Bold
                        font.family: "sans-serif"
                        font.letterSpacing: 2
                        leftPadding: 10
                    }

                    Item { width: 1; height: 4 }

                    Repeater {
                        model: AppController.recentConnections

                        RecentConnectionRow {
                            width: root.width - 20
                            x: 10
                            displayLabel: model.displayLabel
                            timestamp: model.timestamp
                            pinned: model.pinned
                            onlineStatus: model.onlineStatus
                            onConnectClicked: AppController.connectToHost(model.code)
                            onDeleteClicked: AppController.deleteRecentConnection(index)
                            onPinClicked: AppController.togglePinRecentConnection(index)
                            onRenameClicked: {}
                        }
                    }
                }

                Item { width: 1; height: 8 }

                PearButton {
                    width: parent.width - 20
                    height: 34
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "Back"
                    bgColor: "#2f2f2f"
                    textColor: "#b0b0b0"
                    fontSize: 12
                    onClicked: AppController.currentPage = 0
                }
            }
        }
    }
}
