import AppKit
import LightsCore
import SwiftUI

@main
struct PrismApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        Window("Prism", id: "main") {
            ContentView(model: delegate.model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1240, height: 900)
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
        #if DEBUG
        // Screenshots at a set size: HL_WINDOW=1300x1040.
        if let size = ProcessInfo.processInfo.environment["HL_WINDOW"]?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.titled) }?
                    .setFrame(NSRect(x: 40, y: 20, width: size[0], height: size[1]), display: true)
            }
        }
        #endif
    }

    /// A stray ⌘Q mid-service would hand the room to whatever the nodes do
    /// without a source (often black), so a quit asks first while a cue is
    /// up. A restart, shutdown or log out goes straight through.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.liveCueID != nil, model.outputEnabled, !Self.systemIsGoingDown() else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit Prism?"
        alert.informativeText = "The lights stop getting cues from this Mac."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    private static func systemIsGoingDown() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == kCoreEventClass, event.eventID == kAEQuitApplication,
              let reason = event.attributeDescriptor(forKeyword: kAEQuitReason)?.enumCodeValue
        else { return false }
        return [kAEShutDown, kAERestart, kAEReallyLogOut, kAELogOut].map { OSType($0) }.contains(reason)
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    /// Closing the window leaves the lights where they are; the Dock icon
    /// brings it back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
