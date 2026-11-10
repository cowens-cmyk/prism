import AppKit
import Foundation
import LightsCore
import Observation

@MainActor
@Observable
final class AppModel {
    let rig = Rig.hope
    let store = ShowStore.standard

    private(set) var show: Show
    var selectedCueID: String?
    private(set) var liveCueID: String?
    /// The cue waiting for its note from Screens.
    var learningCueID: String?
    private(set) var lastNote: (note: Int, source: String, at: Date)?
    private(set) var midiStatus = MIDIListener.Status()
    /// Anything else sending sACN to our universes, Lightkey most likely.
    private(set) var otherSources: [SACNMonitor.Source] = []
    private(set) var networks: [NetworkInterface] = []
    private(set) var saveError: String?

    // MARK: Settings, per Mac

    /// "all", or one interface name ("en0").
    var networkChoice: String { didSet { defaults.set(networkChoice, forKey: "network"); applyNetwork() } }
    /// Node IPs for sACN unicast, comma separated. Empty: multicast only.
    var unicastText: String { didSet { defaults.set(unicastText, forKey: "unicast"); applyNetwork() } }
    var listensToAllMIDI: Bool { didSet { defaults.set(listensToAllMIDI, forKey: "allMIDI"); midi.setListensToEverything(listensToAllMIDI) } }
    /// Off: Screens' notes are ignored and only clicks change the lights.
    var followsScreens: Bool { didSet { defaults.set(followsScreens, forKey: "followScreens") } }
    var outputEnabled: Bool { didSet { defaults.set(outputEnabled, forKey: "output"); engine.setOutputEnabled(outputEnabled) } }

    private let defaults = UserDefaults.standard
    private let sender: SACNSender
    private let engine: LightEngine
    private var monitor: SACNMonitor!
    private var midi: MIDIListener!
    private var saveTask: Task<Void, Never>?
    private var activity: NSObjectProtocol?

    init() {
        defaults.register(defaults: ["network": "all", "followScreens": true, "output": true])
        networkChoice = defaults.string(forKey: "network") ?? "all"
        unicastText = defaults.string(forKey: "unicast") ?? ""
        listensToAllMIDI = defaults.bool(forKey: "allMIDI")
        followsScreens = defaults.bool(forKey: "followScreens")
        outputEnabled = defaults.bool(forKey: "output")

        // One CID per Mac, kept: nodes and the monitor tell sources apart by it.
        let cid = defaults.string(forKey: "cid").flatMap(UUID.init(uuidString:)) ?? UUID()
        defaults.set(cid.uuidString, forKey: "cid")
        sender = SACNSender(cid: cid)
        engine = LightEngine(rig: rig, sink: sender)
        show = store.load()
        selectedCueID = show.cues.first?.id

        monitor = SACNMonitor(ownCID: cid, universes: rig.universes) { [weak self] sources in
            Task { @MainActor in self?.otherSources = sources }
        }
        midi = MIDIListener(
            onNote: { [weak self] channel, note, source in
                Task { @MainActor in self?.handle(note: note, channel: channel, source: source) }
            },
            onStatus: { [weak self] status in
                Task { @MainActor in self?.midiStatus = status }
            })
    }

    func start() {
        // App Nap would slow the 40 Hz timer whenever the window is hidden,
        // and a sleeping Mac takes the lights with it.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .latencyCritical],
            reason: "Sending lighting cues")
        applyNetwork()
        engine.setOutputEnabled(outputEnabled)
        engine.start()
        midi.start(listensToEverything: listensToAllMIDI)
        // Back to what was up before the app quit, so a restart mid-service
        // doesn't drop the room to black.
        if let id = defaults.string(forKey: "liveCue"), let cue = cue(id) {
            go(cue, fade: 2)
        }
        watchNetworks()
    }

    func shutdown() {
        saveNow()
        engine.shutdown()
        monitor.stop()
    }

    // MARK: Cues

    func cue(_ id: String?) -> Cue? { show.cues.first { $0.id == id } }

    var blackoutCue: Cue? { show.cues.first { $0.id == "blackout" } }

    func go(_ cue: Cue, fade: TimeInterval? = nil) {
        engine.go(cue, fade: fade)
        liveCueID = cue.id
        defaults.set(cue.id, forKey: "liveCue")
    }

    func go(id: String?) {
        if let cue = cue(id) { go(cue) }
    }

    /// Every edit comes through here: saved shortly after, and shown in the
    /// room at once if the cue is live.
    func update(_ cue: Cue) {
        guard let index = show.cues.firstIndex(where: { $0.id == cue.id }), show.cues[index] != cue else { return }
        show.cues[index] = cue
        engine.update(cue)
        scheduleSave()
    }

    func addCue() {
        let name = uniqueName("New Cue")
        // Starts from the selected cue's look, which is usually the nearest
        // thing to what's wanted.
        let base = cue(selectedCueID)
        let cue = Cue(
            name: name, screensPosition: "custom:\(name)", note: nextFreeNote(),
            fade: base?.fade ?? 5, looks: base?.looks ?? [:])
        let at = show.cues.firstIndex { $0.id == "blackout" } ?? show.cues.endIndex
        show.cues.insert(cue, at: at)
        selectedCueID = cue.id
        scheduleSave()
    }

    func duplicate(_ cue: Cue) {
        var copy = cue
        copy.id = UUID().uuidString
        copy.name = uniqueName(cue.name + " copy")
        copy.screensPosition = "custom:\(copy.name)"
        copy.note = nextFreeNote()
        let at = (show.cues.firstIndex { $0.id == cue.id } ?? show.cues.endIndex - 1) + 1
        show.cues.insert(copy, at: at)
        selectedCueID = copy.id
        scheduleSave()
    }

    func delete(_ cue: Cue) {
        show.cues.removeAll { $0.id == cue.id }
        if selectedCueID == cue.id { selectedCueID = show.cues.first?.id }
        scheduleSave()
        store.removeUnusedImages(keeping: show)
    }

    func move(from source: IndexSet, to destination: Int) {
        show.cues.move(fromOffsets: source, toOffset: destination)
        scheduleSave()
    }

    /// Puts the cues back to the ones imported from Lightkey.
    func resetShow() {
        show = .bundledDefault()
        selectedCueID = show.cues.first?.id
        scheduleSave()
        store.removeUnusedImages(keeping: show)
        if let live = cue(liveCueID) { engine.update(live) }
    }

    private func uniqueName(_ base: String) -> String {
        var name = base, n = 2
        while show.cues.contains(where: { $0.name == name }) { name = "\(base) \(n)"; n += 1 }
        return name
    }

    /// Screens gives an added row the lowest free note above its defaults.
    private func nextFreeNote() -> Int {
        let used = Set(show.cues.compactMap(\.note))
        return (73...127).first { !used.contains($0) } ?? 127
    }

    // MARK: Colour helpers

    func setSlimparColor(_ color: LightColor, in cue: Cue) {
        var cue = cue
        for group in rig.groups where group.isSlimpar {
            var look = cue.look(for: group)
            look.color = color
            // A dark SlimPAR wouldn't show the colour it was just given.
            if look.level == 0 { look.level = 0.5 }
            cue.set(look, for: group)
        }
        update(cue)
    }

    /// A picture or video dropped on a cue: its colours go on the cue, the
    /// strongest on every SlimPAR group.
    func applyPicture(at url: URL, to cueID: String) async {
        guard let image = await ImagePalette.picture(at: url) else { return }
        guard var cue = cue(cueID) else { return }
        let palette = ImagePalette.colors(in: image)
        cue.image = try? store.storeImage(image)
        cue.palette = palette
        update(cue)
        if let first = palette.first, let updated = self.cue(cueID) { setSlimparColor(first, in: updated) }
        store.removeUnusedImages(keeping: show)
    }

    func clearPicture(of cue: Cue) {
        var cue = cue
        cue.image = nil
        cue.palette = nil
        update(cue)
        store.removeUnusedImages(keeping: show)
    }

    // MARK: Screens

    private func handle(note: Int, channel: Int, source: String) {
        lastNote = (note, source, Date())
        if let learning = learningCueID, var cue = cue(learning) {
            // A note belongs to one cue; the one it came from lets go of it.
            for var other in show.cues where other.note == note && other.id != cue.id {
                other.note = nil
                update(other)
            }
            cue.note = note
            update(cue)
            learningCueID = nil
            return
        }
        guard followsScreens, let cue = show.cue(forNote: note) else { return }
        go(cue)
    }

    // MARK: Network

    var activeNetworks: [NetworkInterface] {
        networkChoice == "all" ? networks : networks.filter { $0.name == networkChoice }
    }

    private func applyNetwork() {
        networks = NetworkInterface.all()
        let unicast = unicastText.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        sender.configure(interfaces: activeNetworks, unicastAddresses: unicast)
        monitor.start(interfaces: activeNetworks)
    }

    /// A cable plugged in after launch, or Wi-Fi joining late, picks up
    /// within a few seconds without a restart.
    private func watchNetworks() {
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                if NetworkInterface.all() != self.networks { self.applyNetwork() }
            }
        }
    }

    // MARK: Saving

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func saveNow() {
        do {
            try store.save(show)
            saveError = nil
        } catch {
            saveError = "Couldn't save the show: \(error.localizedDescription)"
        }
    }
}
