import LightsCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            CueListView(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            VStack(spacing: 0) {
                if !model.otherSources.isEmpty {
                    ConflictBanner(sources: model.otherSources)
                }
                if let error = model.saveError {
                    Banner(text: error, color: .red)
                }
                if let cue = model.cue(model.selectedCueID) {
                    CueEditorView(model: model, cue: cue)
                        .id(cue.id)
                } else {
                    ContentUnavailableView("No cue selected", systemImage: "lightbulb")
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .status) {
                OutputStatus(model: model)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if let cue = model.blackoutCue { model.go(cue) }
                } label: {
                    Label("Blackout", systemImage: "moon.fill")
                }
                .help("Fade everything out (⇧⌘B)")
                .disabled(model.blackoutCue == nil)
            }
        }
    }
}

/// Two consoles on the same lights flicker between each other's looks.
struct ConflictBanner: View {
    var sources: [SACNMonitor.Source]

    var body: some View {
        let names = sources.map(\.name).joined(separator: ", ")
        Banner(
            text: "\(names) is also sending to the lights. Quit it so the two don't fight.",
            color: .orange)
    }
}

struct Banner: View {
    var text: String
    var color: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text)
            Spacer()
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(color.opacity(0.18))
        .foregroundStyle(color == .orange ? Color.primary : color)
    }
}

struct OutputStatus: View {
    var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            Label(output.text, systemImage: "dot.radiowaves.left.and.right")
                .foregroundStyle(output.ok ? Color.secondary : Color.orange)
            Label(screens, systemImage: "rectangle.on.rectangle")
                .foregroundStyle(.secondary)
        }
        .labelStyle(.titleAndIcon)
        .font(.callout)
    }

    private var output: (text: String, ok: Bool) {
        guard model.outputEnabled else { return ("Output off", false) }
        let networks = model.activeNetworks
        if networks.isEmpty { return ("No network", false) }
        return ("Sending on " + networks.map(\.name).joined(separator: ", "), true)
    }

    private var screens: String {
        guard model.followsScreens else { return "Not following Screens" }
        if let last = model.lastNote, Date().timeIntervalSince(last.at) < 3600 {
            let cue = model.show.cue(forNote: last.note)?.name ?? "note \(last.note)"
            return "Screens: \(cue)"
        }
        return model.midiStatus.connected.isEmpty ? "Waiting for Screens" : "Listening for Screens"
    }
}
