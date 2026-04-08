import SwiftUI
import PeariscopeCore

@main
struct PeariscopeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        let _ = NSLog("[app] PeariscopeApp.body evaluated")
        MenuBarExtra("Peariscope", systemImage: "display") {
            PopoverContentView(
                networkManager: appDelegate.networkManager,
                hostSession: appDelegate.hostSession,
                onOpenViewer: { appDelegate.openViewerWindow() },
                onQuit: { NSApplication.shared.terminate(nil) }
            )
            .frame(width: 340)
        }
        .menuBarExtraStyle(.window)
    }
}
