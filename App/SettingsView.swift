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
    private let updater = AppUpdater.shared
    @FocusState private var unicastFocused: Bool
    @State private var tab = SettingsView.firstTab

    // One tab per area, the usual Mac Settings window. All the sections in one
    // form made the window taller than the booth display, and a Settings
    // window can't be resized.
    var body: some View {
        TabView(selection: $tab) {
            page { look; updates; show }
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("General")
            page { lights }
                .tabItem { Label("Lights", systemImage: "lightbulb") }
                .tag("Lights")
            page { screensMIDI }
                .tabItem { Label("Screens", systemImage: "play.rectangle") }
                .tag("Screens")
            page { songs }
                .tabItem { Label("Songs", systemImage: "music.note") }
                .tag("Songs")
            page { claude }
                .tabItem { Label("Claude", systemImage: "sparkle") }
                .tag("Claude")
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
        .tint(Theme.accent)
        .preferredColorScheme(model.colorScheme)
    }

    /// Each page is as tall as its own sections, capped so it scrolls rather
    /// than running off a small display.
    private func page<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Form { content() }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(AmbientBackground(glows: model.ambientGlows, fade: model.ambientFade))
            .frame(width: 520)
            .frame(maxHeight: 560)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var look: some View {
        Section("Look") {
            Picker("Appearance", selection: $model.appearance) {
                Text("Dark").tag("dark")
                Text("Light").tag("light")
                Text("Match the Mac").tag("system")
            }
        }
    }

    private var lights: some View {
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
    }

    private var screensMIDI: some View {
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
            if model.followsScreens, !model.midiStatus.connected.isEmpty, model.lastNote == nil {
                Text("Screens is connected but hasn't sent a cue. In Screens: Settings › Integrations › Prism & MIDI, turn on “Change Prism scenes with the service” under Lighting cues. Then present a plan item, or press Send on a row there.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            Text("In Screens, open Settings › Integrations › Prism & MIDI. Pick This Mac, or Another Mac with the address above. Use the same MIDI channel as here, turn on “Change Prism scenes with the service”, and use Add Cue… to add a Recognition row. Any slide can cue a scene: right-click it › Prism.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var songs: some View {
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
            LabeledContent("Plan check") {
                HStack {
                    if let check = model.backgroundCheck {
                        Text("\(check.at.formatted(date: .omitted, time: .shortened)): \(check.text)")
                            .font(.callout)
                            .foregroundStyle(check.ok ? Color.secondary : Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Not yet").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Check Now") { model.checkBackgroundsNow() }
                }
            }
            Text("Every minute Prism looks at the plan open in Screens. When a song's or the countdown's background has changed, that cue takes the new background's colour, so it goes up matching. A cue that's live changes once it's done.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var claude: some View {
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
    }

    private var updates: some View {
        Section("Updates") {
            Toggle("Check for updates automatically", isOn: Bindable(updater).checksAutomatically)
            HStack {
                if let available = updater.available {
                    // Asks first, with Later as the default, the same as the menu:
                    // updating quits Prism mid-service otherwise.
                    Button("Update to \(available.version)…") { updater.promptToInstall() }
                } else {
                    Button("Check Now") { Task { await updater.check(userInitiated: true) } }
                }
                Button("Previous Version…") { Task { await updater.choosePreviousVersion() } }
                if updater.isWorking { ProgressView().controlSize(.small) }
                if let status = updater.status {
                    Text(status).font(.callout).foregroundStyle(.secondary)
                }
            }
            Text("Version \(updater.currentVersion). Updating quits Prism and reopens it on the cue that was up; do it outside a service. Previous Version… puts an earlier release back if a new one misbehaves.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var show: some View {
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

    private static var firstTab: String {
        #if DEBUG
        ProcessInfo.processInfo.environment["HL_SETTINGS"] ?? "General"
        #else
        "General"
        #endif
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
