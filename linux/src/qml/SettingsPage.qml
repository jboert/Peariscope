import QtQuick
import QtQuick.Controls
import Peariscope

Item {
    id: root

    property var accentList: ["#9BE238","#9B61DE","#0A84FF","#FF9F0A","#FF453A","#30D158","#BF5AF2","#FFD60A"]

    Flickable {
        anchors.fill: parent
        contentHeight: contentCol.height + 16
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
            id: contentCol
            width: parent.width
            leftPadding: 10
            rightPadding: 10
            topPadding: 12

            // ========== SECURITY ==========
            Text {
                text: "SECURITY"
                color: "#8a8a8a"
                font.pixelSize: 9
                font.weight: Font.Bold
                font.family: "sans-serif"
                font.letterSpacing: 2
            }

            Item { width: 1; height: 4 }

            SettingsRow {
                width: parent.width - 20
                title: "PIN Protection"
                subtitle: "Require PIN to connect"
                iconColor: "#FF453A"
                iconChar: "P"
                checked: AppController.settingPinProtection
                onToggled: AppController.settingPinProtection = !AppController.settingPinProtection
            }

            // PIN code field
            Item {
                visible: AppController.settingPinProtection
                width: parent.width - 20
                height: 34

                TextField {
                    id: pinCodeInput
                    x: 30
                    width: 100; height: 28
                    anchors.verticalCenter: parent.verticalCenter
                    text: AppController.settingPinCode
                    color: "#ffffff"
                    font.pixelSize: 13
                    font.weight: Font.Bold
                    font.family: "monospace"
                    maximumLength: 10
                    inputMethodHints: Qt.ImhDigitsOnly
                    onTextChanged: {
                        if (text !== AppController.settingPinCode)
                            AppController.settingPinCode = text
                    }

                    background: Rectangle {
                        radius: 6
                        color: "#2a2a2a"
                        border.width: 1
                        border.color: "#2f2f2f"
                    }
                }
            }

            // Max Viewers
            Item {
                width: parent.width - 20
                height: 42

                Rectangle {
                    id: maxIcon
                    width: 22; height: 22; radius: 11
                    color: "#0A84FF"
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    Text {
                        anchors.centerIn: parent
                        text: "#"; color: "#ffffff"
                        font.pixelSize: 9; font.weight: Font.Bold; font.family: "sans-serif"
                    }
                }

                Column {
                    anchors.left: maxIcon.right
                    anchors.leftMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    Text {
                        text: "Max Viewers"; color: "#ffffff"
                        font.pixelSize: 13; font.family: "sans-serif"
                    }
                    Text {
                        text: "Simultaneous connections"
                        color: "#8a8a8a"
                        font.pixelSize: 10; font.family: "sans-serif"
                    }
                }

                Row {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2

                    Rectangle {
                        width: 24; height: 24; radius: 6
                        color: minusArea.containsMouse ? "#3e3e3e" : "#2f2f2f"
                        Text {
                            anchors.centerIn: parent; text: "-"; color: "#ffffff"
                            font.pixelSize: 13; font.weight: Font.Bold; font.family: "sans-serif"
                        }
                        MouseArea {
                            id: minusArea; anchors.fill: parent; hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: { if (AppController.settingMaxPeers > 1) AppController.settingMaxPeers = AppController.settingMaxPeers - 1 }
                        }
                    }

                    Text {
                        width: 26; text: AppController.settingMaxPeers.toString()
                        color: "#ffffff"; font.pixelSize: 14; font.weight: Font.Bold
                        font.family: "monospace"
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter; height: 24
                    }

                    Rectangle {
                        width: 24; height: 24; radius: 6
                        color: plusArea.containsMouse ? "#3e3e3e" : "#2f2f2f"
                        Text {
                            anchors.centerIn: parent; text: "+"; color: "#ffffff"
                            font.pixelSize: 13; font.weight: Font.Bold; font.family: "sans-serif"
                        }
                        MouseArea {
                            id: plusArea; anchors.fill: parent; hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: { if (AppController.settingMaxPeers < 20) AppController.settingMaxPeers = AppController.settingMaxPeers + 1 }
                        }
                    }
                }
            }

            Item { width: 1; height: 6 }
            Rectangle { width: parent.width - 20; height: 1; color: "#2f2f2f" }
            Item { width: 1; height: 8 }

            // ========== STREAMING ==========
            Text {
                text: "STREAMING"
                color: "#8a8a8a"
                font.pixelSize: 9; font.weight: Font.Bold
                font.family: "sans-serif"; font.letterSpacing: 2
            }

            Item { width: 1; height: 4 }

            SettingsRow {
                width: parent.width - 20
                title: "New Code Each Session"
                subtitle: "Fresh seed phrase per share"
                iconColor: "#BF5AF2"; iconChar: "N"
                checked: AppController.settingNewCodeEachSession
                onToggled: AppController.settingNewCodeEachSession = !AppController.settingNewCodeEachSession
            }

            SettingsRow {
                width: parent.width - 20
                title: "Clipboard Sync"
                subtitle: "Share clipboard with viewers"
                iconColor: "#FF9F0A"; iconChar: "C"
                checked: AppController.settingClipboardSync
                onToggled: AppController.settingClipboardSync = !AppController.settingClipboardSync
            }

            SettingsRow {
                width: parent.width - 20
                title: "Share Audio"
                subtitle: "Stream system audio to viewers"
                iconColor: "#0A84FF"; iconChar: "A"
                checked: AppController.settingShareAudio
                onToggled: AppController.settingShareAudio = !AppController.settingShareAudio
            }

            Item { width: 1; height: 6 }
            Rectangle { width: parent.width - 20; height: 1; color: "#2f2f2f" }
            Item { width: 1; height: 8 }

            // ========== SYSTEM ==========
            Text {
                text: "SYSTEM"
                color: "#8a8a8a"
                font.pixelSize: 9; font.weight: Font.Bold
                font.family: "sans-serif"; font.letterSpacing: 2
            }

            Item { width: 1; height: 4 }

            SettingsRow {
                width: parent.width - 20
                title: "Auto-Share on Launch"
                subtitle: "Start sharing when app opens"
                iconColor: "#9BE238"; iconChar: "A"
                checked: AppController.settingShareOnStartup
                onToggled: AppController.settingShareOnStartup = !AppController.settingShareOnStartup
            }

            SettingsRow {
                width: parent.width - 20
                title: "Launch at Login"
                subtitle: "Start at system startup"
                iconColor: "#0A84FF"; iconChar: "L"
                checked: AppController.settingRunOnStartup
                onToggled: AppController.settingRunOnStartup = !AppController.settingRunOnStartup
            }

            Item { width: 1; height: 6 }
            Rectangle { width: parent.width - 20; height: 1; color: "#2f2f2f" }
            Item { width: 1; height: 8 }

            // ========== APPEARANCE ==========
            Text {
                text: "APPEARANCE"
                color: "#8a8a8a"
                font.pixelSize: 9; font.weight: Font.Bold
                font.family: "sans-serif"; font.letterSpacing: 2
            }

            Item { width: 1; height: 6 }

            Text {
                text: "Accent Color"
                color: "#ffffff"
                font.pixelSize: 13; font.family: "sans-serif"
            }

            Item { width: 1; height: 4 }

            // Color swatch grid
            Flow {
                width: parent.width - 20
                spacing: 8

                Repeater {
                    model: accentList.length
                    Rectangle {
                        width: 28; height: 28; radius: 14
                        color: accentList[index]
                        border.width: AppController.settingAccentColor === index ? 2 : 0
                        border.color: "#ffffff"

                        Rectangle {
                            visible: AppController.settingAccentColor === index
                            anchors.centerIn: parent
                            width: 8; height: 8; radius: 4
                            color: "#ffffff"
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                AppController.settingAccentColor = index
                                Theme.colorIndex = index
                            }
                        }
                    }
                }
            }

            Item { width: 1; height: 12 }
        }
    }
}
