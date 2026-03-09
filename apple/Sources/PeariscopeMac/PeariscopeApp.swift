import SwiftUI
import PeariscopeCore

@main
struct PeariscopeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // MenuBarExtra is the SwiftUI-native way to create a menu bar app.
        // The .window style gives us a popover-like panel.
        MenuBarExtra {
            PopoverContentView(
                networkManager: appDelegate.networkManager,
                hostSession: appDelegate.hostSession,
                onOpenViewer: { appDelegate.openViewerWindow() },
                onQuit: { NSApplication.shared.terminate(nil) }
            )
            .frame(width: 340)
        } label: {
            // This gets replaced by AppDelegate's status item icon
            Image(systemName: "display")
        }
        .menuBarExtraStyle(.window)
    }
}
