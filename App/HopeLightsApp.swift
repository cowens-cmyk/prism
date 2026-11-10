import AppKit
import LightsCore
import SwiftUI

@main
struct HopeLightsApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        Window("Hope Lights", id: "main") {
            ContentView(model: delegate.model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Cue") { delegate.model.addCue() }
                    .keyboardShortcut("n")
            }
            CommandMenu("Cue") {
                Button("Go") { delegate.model.go(id: delegate.model.selectedCueID) }
                    .keyboardShortcut(.return, modifiers: .command)
                Button("Blackout") { if let cue = delegate.model.blackoutCue { delegate.model.go(cue) } }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
            }
        }
        Settings {
            SettingsView(model: delegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    /// Closing the window leaves the lights where they are; the Dock icon
    /// brings it back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
