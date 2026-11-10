import Darwin
import LightsCore
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var confirmReset = false
    @State private var unicastDraft = ""
    @FocusState private var unicastFocused: Bool

    var body: some View {
        Form {
            Section("Look") {
                Picker("Appearance", selection: $model.appearance) {
                    Text("Dark").tag("dark")
                    Text("Light").tag("light")
                    Text("Match the Mac").tag("system")
                }
            }
            Section("Lights") {
                Toggle("Send to the lights", isOn: $model.outputEnabled)
                Picker("Network", selection: $model.networkChoice) {
                    Text("All networks").tag("all")
                    ForEach(model.networks) { network in
                        Text("\(network.name) – \(network.address)").tag(network.name)
                    }
                }
                TextField("Node addresses", text: $unicastDraft, prompt: Text("Optional, e.g. 10.0.0.50"))
                    .focused($unicastFocused)
                    .onSubmit { model.unicastText = unicastDraft }
                    .onChange(of: unicastFocused) { _, focused in if !focused { model.unicastText = unicastDraft } }
                if !invalidAddresses.isEmpty {
                    Text("Not an IP address: \(invalidAddresses.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text("sACN universes \(model.rig.universes.map(String.init).joined(separator: " and ")), the same as Lightkey sent. Node addresses are only needed for a node that ignores multicast.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Screens") {
                Toggle("Follow Screens", isOn: $model.followsScreens)
                Picker("MIDI channel", selection: $model.midiChannel) {
                    Text("Any").tag(0)
                    ForEach(1...16, id: \.self) { Text("\($0)").tag($0) }
                }
                Toggle("Listen to every MIDI input", isOn: $model.listensToAllMIDI)
                LabeledContent("Connected") {
                    Text(model.midiStatus.connected.isEmpty ? "Nothing yet" : model.midiStatus.connected.joined(separator: ", "))
                }
                LabeledContent("Screens on another Mac") {
                    Text(networkMIDIHint)
                        .textSelection(.enabled)
                }
                Text("In Screens, open Settings › Lightkey & MIDI. Pick This Mac, or Another Mac with the address above. Use the same MIDI channel as here, turn on “Change Lightkey scenes with the service”, and use Add Cue… to add a Recognition row.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Show") {
                Button("Start Over from the Lightkey Cues…") { confirmReset = true }
                    .confirmationDialog(
                        "Replace every cue with the ones imported from Lightkey?",
                        isPresented: $confirmReset
                    ) {
                        Button("Replace Cues", role: .destructive) { model.resetShow() }
                    } message: {
                        Text("Your changes and pictures are lost.")
                    }
                LabeledContent("Show file") {
                    Text(model.store.showURL.path)
                        .textSelection(.enabled)
                        .font(.caption)
                }
            }
        }
        .onAppear { unicastDraft = model.unicastText }
        .onDisappear { model.unicastText = unicastDraft }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(AmbientBackground(glows: model.ambientGlows, fade: model.ambientFade))
        .tint(Theme.accent)
        .preferredColorScheme(model.colorScheme)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var invalidAddresses: [String] {
        unicastDraft.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init).filter { entry in
            var addr = in_addr()
            return inet_pton(AF_INET, entry, &addr) != 1
        }
    }

    private var networkMIDIHint: String {
        let addresses = model.networks.map(\.address).joined(separator: " or ")
        let port = model.midiStatus.networkPort
        return addresses.isEmpty ? "No network" : "\(addresses), port \(port == 0 ? 5004 : port)"
    }
}
