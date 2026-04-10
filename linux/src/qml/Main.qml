import QtQuick
import QtQuick.Controls
import Peariscope

Window {
    id: root

    width: 320
    height: 420 + (AppController.hasPendingPeer && AppController.appMode === 1 ? 170 : 0)
    flags: Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint | Qt.Tool
    color: "#1e1e1e"
    visible: AppController.popupVisible

    Behavior on height { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
    onHeightChanged: positionAtBottomRight()

    onVisibleChanged: {
        if (visible) {
            requestActivate()
        }
    }

    Connections {
        target: AppController
        function onPeerWantsApproval() {
            // Restore window if minimized and bring to front
            root.show()
            root.raise()
            root.requestActivate()
            positionAtBottomRight()
        }
    }

    Component.onCompleted: {
        positionAtBottomRight()
        Theme.colorIndex = AppController.settingAccentColor
    }

    function positionAtBottomRight() {
        x = Screen.width - width - 12
        y = 36
    }

    Rectangle {
        id: background
        anchors.fill: parent
        radius: 12
        color: "#1e1e1e"
        border.width: 1
        border.color: "#2f2f2f"
        clip: true

        Header {
            id: header
            anchors.top: parent.top
            width: parent.width
            onSettingsClicked: {
                if (AppController.currentPage === 2)
                    AppController.currentPage = 0
                else
                    AppController.currentPage = 2
            }
        }

        Rectangle {
            id: updateBanner
            anchors.top: header.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: AppController.updateAvailable ? 36 : 0
            visible: AppController.updateAvailable
            color: "#2d5a27"
            clip: true

            Behavior on height { NumberAnimation { duration: 200 } }

            Row {
                anchors.centerIn: parent
                spacing: 8

                Text {
                    text: "Update available" + (AppController.updateVersion ? " (v" + AppController.updateVersion + ")" : "")
                    color: "#b0b0b0"
                    font.pixelSize: 11
                    anchors.verticalCenter: parent.verticalCenter
                }

                Rectangle {
                    width: 60
                    height: 22
                    radius: 4
                    color: "#4a8c3f"
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                        text: "Restart"
                        color: "white"
                        font.pixelSize: 10
                        font.bold: true
                        anchors.centerIn: parent
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: AppController.applyUpdate()
                    }
                }
            }
        }

        Loader {
            id: pageLoader
            anchors.top: updateBanner.bottom
            anchors.bottom: toolbar.top
            anchors.left: parent.left
            anchors.right: parent.right

            sourceComponent: {
                switch (AppController.currentPage) {
                    case 0: return hostPage
                    case 1: return connectPage
                    case 2: return settingsPage
                    default: return hostPage
                }
            }
        }

        Toolbar {
            id: toolbar
            anchors.bottom: parent.bottom
            width: parent.width
            onConnectClicked: {
                if (AppController.currentPage === 1)
                    AppController.currentPage = 0
                else
                    AppController.currentPage = 1
            }
            onQuitClicked: AppController.quit()
        }
    }

    Component {
        id: hostPage
        HostPage {}
    }
    Component {
        id: connectPage
        ConnectPage {}
    }
    Component {
        id: settingsPage
        SettingsPage {}
    }

    // Mini approval popup — shown when main window is closed and a peer wants approval
    Window {
        id: miniApproval
        width: 300
        height: 180
        flags: Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint | Qt.Tool
        color: "#1e1e1e"
        visible: AppController.hasPendingPeer && !root.visible

        Component.onCompleted: positionMiniPopup()
        onVisibleChanged: if (visible) positionMiniPopup()

        function positionMiniPopup() {
            var sx = Screen.desktopAvailableWidth
            var sy = Screen.desktopAvailableHeight
            miniApproval.x = sx - width - 12
            miniApproval.y = sy - height - 12
        }

        Rectangle {
            anchors.fill: parent
            radius: 12
            color: "#1e1e1e"
            border.width: 1
            border.color: "#2f2f2f"
            clip: true

            PeerConnectingCard {
                anchors.fill: parent
                anchors.margins: 10
                peerKey: AppController.pendingPeerKey
                pin: AppController.pendingPeerPin
                onApproveClicked: AppController.approvePeer()
                onRejectClicked: AppController.rejectPeer()
            }
        }
    }
}
