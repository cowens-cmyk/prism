import LightsCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            CueListView(model: model)
                .navigationSplitViewColumnWidth(min: 230, ideal: 270)
        } detail: {
            ZStack(alignment: .top) {
                if let cue = model.cue(model.selectedCueID) {
                    CueEditorView(model: model, cue: cue)
                        .id(cue.id)
                } else {
                    ContentUnavailableView("No cue selected", systemImage: "lightbulb.max")
                }
                VStack(spacing: 8) {
                    if !model.otherSources.isEmpty {
                        let names = model.otherSources.map(\.name).joined(separator: ", ")
                        Banner(text: "\(names) is also sending to the lights. Quit it so the two don't fight.", tint: .orange)
                    }
                    if let error = model.saveError {
                        Banner(text: error, tint: .red)
                    }
                }
                .padding(.top, 8)
                .animation(.spring(duration: 0.35), value: model.otherSources)
            }
        }
        .containerBackground(for: .window) {
            AmbientBackground(glows: model.ambientGlows, fade: model.ambientFade)
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
                .help("Turn everything off now (⇧⌘B)")
                .disabled(model.blackoutCue == nil)
            }
        }
        .tint(Theme.accent)
        .preferredColorScheme(model.colorScheme)
    }
}

/// A warning floating over the editor in tinted glass.
struct Banner: View {
    var text: String
    var tint: Color

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular.tint(tint.opacity(0.5)), in: .capsule)
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}

struct OutputStatus: View {
    var model: AppModel

    var body: some View {
        HStack(spacing: 16) {
            Label(output.text, systemImage: "dot.radiowaves.left.and.right")
                .foregroundStyle(output.ok ? Color.secondary : Color.orange)
            Label(screens, systemImage: "rectangle.on.rectangle")
                .foregroundStyle(.secondary)
            if let saved = model.lastSaved {
                Label("Saved \(saved.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .help("Every change saves by itself, to \(ShowStore.showFileName) on the Desktop.")
            }
        }
        .labelStyle(.titleAndIcon)
        .font(.callout)
        .padding(.horizontal, 8)
    }

    private var output: (text: String, ok: Bool) {
        guard model.outputEnabled else { return ("Output off", false) }
        let networks = model.activeNetworks
        if networks.isEmpty { return ("No network", false) }
        return ("Sending on " + networks.map(\.name).joined(separator: ", "), true)
    }

    private var screens: String {
        guard model.followsScreens else { return "Not following Screens" }
        if let wrong = model.wrongChannel, Date().timeIntervalSince(wrong.at) < 600 {
            return "Screens sends on channel \(wrong.channel), Prism listens on \(model.midiChannel)"
        }
        if let last = model.lastNote, Date().timeIntervalSince(last.at) < 3600 {
            let cue = model.show.cue(forNote: last.note)?.name ?? "note \(last.note)"
            return "Screens: \(cue)"
        }
        // Connected but silent is almost always Screens' own switch, off by
        // default on each Mac.
        return model.midiStatus.connected.isEmpty ? "Waiting for Screens" : "Screens connected, no cues yet"
    }
}
