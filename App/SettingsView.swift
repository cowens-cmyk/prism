import Darwin
import LightsCore
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var confirmReset = false
    @State private var unicastDraft = ""
    @State private var hostDraft = ""
    @State private var keyDraft = ""
    @State private var checkResult: String?
    @State private var confirmNewKey = false
    @State private var copied = false
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
            Section("Songs match Screens' background") {
                TextField("Screens Mac", text: $hostDraft, prompt: Text("127.0.0.1 or booth-mac.local"))
                    .onSubmit { model.screensHost = hostDraft }
                SecureField("Access key", text: $keyDraft)
                    .onSubmit { model.screensKey = keyDraft }
                HStack {
                    Button("Check") {
                        model.screensHost = hostDraft
                        model.screensKey = keyDraft
                        checkResult = "Checking…"
                        Task {
                            let result = await model.screensAPI.check()
                            checkResult = switch result {
                            case .success: "Connected to Screens."
                            case .failure(let failure): failure.message
                            }
                        }
                    }
                    if let checkResult {
                        Text(checkResult)
                            .font(.callout)
                            .foregroundStyle(checkResult == "Connected to Screens." ? .green : .secondary)
                    }
                }
                Text("In Screens: Settings › Integrations › Remote & API. Turn it on, then Manage Keys… and create a Watch key for Prism. Use 127.0.0.1 when Screens runs on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Claude") {
                Toggle("Let Claude control Prism", isOn: $model.claudeEnabled)
                if model.claudeEnabled {
                    LabeledContent("Status") { Text(model.claudeState) }
                    LabeledContent("Address") {
                        Text(model.claudeURL)
                            .textSelection(.enabled)
                    }
                    HStack {
                        Button(copied ? "Copied" : "Copy Setup Command") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(model.claudeSetupCommand, forType: .string)
                            copied = true
                        }
                        Button("New Key…") { confirmNewKey = true }
                            .confirmationDialog("Make a new key?", isPresented: $confirmNewKey) {
                                Button("New Key", role: .destructive) {
                                    model.newClaudeKey()
                                    copied = false
                                }
                            } message: {
                                Text("Claude stops reaching Prism until the setup command is run again with the new key.")
                            }
                    }
                }
                Text("Run the copied command in Terminal on the Mac with Claude Code, then ask Claude to change the lights. The key is in the command: anyone with it can change the lights.")
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
        .onAppear {
            unicastDraft = model.unicastText
            hostDraft = model.screensHost
            keyDraft = model.screensKey
        }
        .onDisappear {
            model.unicastText = unicastDraft
            model.screensHost = hostDraft
            model.screensKey = keyDraft
        }
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
