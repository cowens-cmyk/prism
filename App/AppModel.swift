import AppKit
import Foundation
import LightsCore
import Observation
import SwiftUI

@MainActor
@Observable
final class AppModel {
    let rig = Rig.hope
    let store = ShowStore.standard

    private(set) var show: Show
    var selectedCueID: String?
    private(set) var liveCueID: String?
    /// The cue waiting for its note from Screens. Learn gives up after 30
    /// seconds: left on, it would take the next note of the service.
    var learningCueID: String? {
        didSet {
            learnTimeout?.cancel()
            guard learningCueID != nil else { return }
            learnTimeout = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(30))
                if !Task.isCancelled { self?.learningCueID = nil }
            }
        }
    }
    private var learnTimeout: Task<Void, Never>?
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
    /// Set from Settings when the field is committed, not per keystroke: typing
    /// 10.0.0.150 shouldn't send to 10.0.0.1 and 10.0.0.15 on the way.
    var unicastText: String { didSet { defaults.set(unicastText, forKey: "unicast"); applyNetwork() } }
    /// The channel Screens sends on (its Lightkey & MIDI setting, 16 by
    /// default); 0 takes any. A keyboard on another channel playing middle C
    /// must not fire Walk-in.
    var midiChannel: Int { didSet { defaults.set(midiChannel, forKey: "midiChannel") } }
    var listensToAllMIDI: Bool { didSet { defaults.set(listensToAllMIDI, forKey: "allMIDI"); midi.setListensToEverything(listensToAllMIDI) } }
    /// Off: Screens' notes are ignored and only clicks change the lights.
    var followsScreens: Bool { didSet { defaults.set(followsScreens, forKey: "followScreens") } }
    /// "dark" (the default), "light" or "system".
    var appearance: String { didSet { defaults.set(appearance, forKey: "appearance") } }
    var colorScheme: ColorScheme? {
        switch appearance {
        case "light": .light
        case "system": nil
        default: .dark
        }
    }
    var outputEnabled: Bool { didSet { defaults.set(outputEnabled, forKey: "output"); engine.setOutputEnabled(outputEnabled) } }

    private let defaults = UserDefaults.standard
    private let sender: SACNSender
    private let engine: LightEngine
    private var monitor: SACNMonitor!
    private var midi: MIDIListener!
    private var saveTask: Task<Void, Never>?
    private var activity: NSObjectProtocol?

    init() {
        defaults.register(defaults: ["network": "all", "followScreens": true, "output": true, "appearance": "dark"])
        appearance = defaults.string(forKey: "appearance") ?? "dark"
        networkChoice = defaults.string(forKey: "network") ?? "all"
        unicastText = defaults.string(forKey: "unicast") ?? ""
        midiChannel = defaults.object(forKey: "midiChannel") as? Int ?? 16
        screensHost = defaults.string(forKey: "screensHost") ?? "127.0.0.1"
        screensPort = defaults.object(forKey: "screensPort") as? Int ?? ScreensAPI.defaultPort
        screensKey = Keychain.read()
        #if DEBUG
        // Tests against a stand-in Screens without touching the keychain.
        if let key = ProcessInfo.processInfo.environment["HL_SCREENS_KEY"] { screensKey = key }
        #endif
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
                // The main queue keeps notes in the order they arrived.
                DispatchQueue.main.async { self?.handle(note: note, channel: channel, source: source) }
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

    func cue(_ id: String?) -> Cue? { show.cue(id) }

    var blackoutCue: Cue? { show.cue("blackout") }

    /// What the window's background glows with: the colours in the room.
    /// Nothing up, nothing lit.
    var ambientGlows: [Glow] {
        guard outputEnabled, let live = liveLook else { return [] }
        return live.glows(in: rig)
    }

    /// How long the background takes to follow: the live cue's fade.
    var ambientFade: Double { cue(liveCueID)?.fade ?? 1.5 }

    func go(_ cue: Cue, fade: TimeInterval? = nil) {
        matchTask?.cancel()
        screensColor = nil
        engine.go(cue, fade: fade)
        liveCueID = cue.id
        defaults.set(cue.id, forKey: "liveCue")
    }

    func go(id: String?) {
        if let cue = cue(id) { go(cue) }
    }

    /// Every change to the show comes through here: saved shortly after, and
    /// shown in the room at once when it touches the live cue.
    private func edit(_ change: (inout Show) -> Void) {
        var next = show
        change(&next)
        guard next != show else { return }
        let liveBefore = show.cue(liveCueID)
        show = next
        if let live = show.cue(liveCueID), live != liveBefore {
            // Picking a SlimPAR colour by hand on the live cue wins over the
            // one matched from Screens.
            let slimpars = rig.groups.filter(\.isSlimpar)
            if let liveBefore, slimpars.contains(where: { live.look(for: $0).color != liveBefore.look(for: $0).color }) {
                screensColor = nil
            }
            if let look = liveLook { engine.update(look) }
        }
        scheduleSave()
    }

    func update(_ cue: Cue) { edit { $0.replace(cue) } }

    func rename(_ id: String, to name: String) { edit { $0.rename(id, to: name) } }

    func clearNote(of id: String) {
        edit { show in
            guard var cue = show.cue(id) else { return }
            cue.note = nil
            show.replace(cue)
        }
    }

    /// Starts from the selected cue's look, usually the nearest thing to
    /// what's wanted.
    func addCue() {
        var added: Cue?
        edit { added = $0.addCue(basedOn: $0.cue(selectedCueID)) }
        selectedCueID = added?.id ?? selectedCueID
    }

    func duplicate(_ id: String) {
        var copy: Cue?
        edit { copy = $0.duplicate(id) }
        if let copy { selectedCueID = copy.id }
    }

    /// The live cue stays: deleting it would leave the room on a look no
    /// longer in the list.
    func delete(_ id: String) {
        guard id != liveCueID, show.cues.count > 1 else { return }
        if learningCueID == id { learningCueID = nil }
        let index = show.cues.firstIndex { $0.id == id }
        edit { $0.delete(id) }
        if selectedCueID == id, let index {
            selectedCueID = show.cues[min(index, show.cues.count - 1)].id
        }
        store.removeUnusedImages(keeping: show)
    }

    func move(from source: IndexSet, to destination: Int) {
        edit { $0.cues.move(fromOffsets: source, toOffset: destination) }
    }

    /// Puts the cues back to the ones imported from Lightkey.
    func resetShow() {
        learningCueID = nil
        edit { $0 = .bundledDefault() }
        if cue(selectedCueID) == nil { selectedCueID = show.cues.first?.id }
        store.removeUnusedImages(keeping: show)
    }

    // MARK: Colour helpers

    func setSlimparColor(_ color: LightColor, in cueID: String) {
        edit { $0.setSlimparColor(color, in: cueID, rig: rig) }
    }

    /// A message under the picture box: a file that isn't a picture, or one
    /// that couldn't be read.
    private(set) var pictureMessage: (cueID: String, text: String)?

    /// A picture or video dropped on a cue: its colours go on the cue, the
    /// strongest on every SlimPAR group.
    func applyPicture(at url: URL, to cueID: String) async {
        pictureMessage = nil
        guard let image = await ImagePalette.picture(at: url) else {
            pictureMessage = (cueID, "Couldn't read “\(url.lastPathComponent)” as a picture or video.")
            return
        }
        let palette = ImagePalette.colors(in: image)
        let stored = try? store.storeImage(image)
        edit { show in
            guard var cue = show.cue(cueID) else { return }
            cue.image = stored
            cue.palette = palette
            show.replace(cue)
            if let first = palette.first { show.setSlimparColor(first, in: cueID, rig: rig) }
        }
        store.removeUnusedImages(keeping: show)
    }

    /// Decoded once per picture, not on every redraw while a slider moves.
    @ObservationIgnored private let thumbnails = NSCache<NSString, NSImage>()

    func thumbnail(_ name: String) -> NSImage? {
        if let cached = thumbnails.object(forKey: name as NSString) { return cached }
        guard let image = NSImage(contentsOf: store.imageURL(name)) else { return nil }
        thumbnails.setObject(image, forKey: name as NSString)
        return image
    }

    func clearPicture(of cueID: String) {
        edit { show in
            guard var cue = show.cue(cueID) else { return }
            cue.image = nil
            cue.palette = nil
            show.replace(cue)
        }
        store.removeUnusedImages(keeping: show)
    }

    // MARK: Screens

    private func handle(note: Int, channel: Int, source: String) {
        guard MIDINote.accepts(channel: channel, listeningOn: midiChannel == 0 ? nil : midiChannel) else { return }
        lastNote = (note, source, Date())
        switch show.action(forNote: note, learning: learningCueID, followsScreens: followsScreens) {
        case .learn(let id):
            edit { $0.assign(note: note, to: id) }
            learningCueID = nil
        case .fire(let id):
            go(id: id)
            if cue(id)?.followsScreensBackground == true { matchScreensBackground(for: id) }
        case .ignore:
            if learningCueID != nil { learningCueID = nil }
        }
    }

    // MARK: Screens' background

    /// Screens' Mac and access key, for matching songs to their backgrounds.
    var screensHost: String { didSet { defaults.set(screensHost, forKey: "screensHost") } }
    var screensPort: Int { didSet { defaults.set(screensPort, forKey: "screensPort") } }
    var screensKey: String { didSet { Keychain.write(screensKey) } }
    var screensAPI: ScreensAPI { ScreensAPI(host: screensHost, port: screensPort, key: screensKey) }

    /// The colour the live cue's SlimPARs took from Screens, if they did.
    /// It isn't saved into the cue: next week's song has another background.
    private(set) var screensColor: LightColor?
    /// The last time matching didn't work, for the editor and Settings.
    private(set) var screensProblem: String?
    @ObservationIgnored private var matchTask: Task<Void, Never>?

    /// The live cue as it is in the room: with Screens' colour when matched.
    var liveLook: Cue? {
        guard let live = cue(liveCueID) else { return nil }
        guard let color = screensColor else { return live }
        return live.withSlimparColor(color, rig: rig)
    }

    /// Screens sends the note as the item goes live; its background can land
    /// a moment later, so this asks a few times before giving up. The colour
    /// joins the cue's fade already under way rather than starting a new one.
    func matchScreensBackground(for cueID: String) {
        matchTask?.cancel()
        let api = screensAPI
        guard api.isSetUp else { return }
        matchTask = Task { @MainActor [weak self] in
            var lastFailure: ScreensAPI.Failure = .noBackground
            attempts: for delay in [0.15, 0.35, 0.6, 1.0] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                switch await api.background() {
                case .success(let image):
                    guard let self, !Task.isCancelled, self.liveCueID == cueID else { return }
                    // A dark or black-and-white background leaves the cue's
                    // own colour up, rather than turning the SlimPARs white.
                    guard let color = ImagePalette.vividColors(in: image).first else {
                        self.screensProblem = nil
                        return
                    }
                    self.screensColor = color
                    self.screensProblem = nil
                    if let look = self.liveLook { self.engine.update(look) }
                    return
                case .failure(let failure):
                    lastFailure = failure
                    // A wrong key or address won't fix itself in a second.
                    if failure != .noBackground && failure != .unreachable { break attempts }
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.screensProblem = lastFailure.message
        }
    }

    /// Writes the matched colour into the cue, for a song that should keep it.
    func keepScreensColor() {
        guard let color = screensColor, let id = liveCueID else { return }
        edit { show in
            guard let cue = show.cue(id) else { return }
            show.replace(cue.withSlimparColor(color, rig: rig))
        }
        screensColor = nil
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
