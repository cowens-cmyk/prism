import CoreMIDI
import Foundation
import LightsCore

/// Hears the notes Screens sends as the service moves.
///
/// Screens on this Mac sends from a virtual source named "Screens"; Screens
/// on another Mac joins this Mac's network MIDI session (its Lightkey
/// settings take this Mac's IP and port). Both are connected here, plus a
/// "Hope Lights" destination anything else can send to. With "every MIDI
/// input" on, every source is connected too.
final class MIDIListener: @unchecked Sendable {
    struct Status: Equatable, Sendable {
        var connected: [String] = []
        var networkPort: Int = 0
    }

    private let onNote: @Sendable (_ channel: Int, _ note: Int, _ source: String) -> Void
    private let onStatus: @Sendable (Status) -> Void
    private let lock = NSLock()
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var destination = MIDIEndpointRef()
    private var connected: [MIDIEndpointRef] = []
    private var listensToEverything = false

    init(
        onNote: @escaping @Sendable (Int, Int, String) -> Void,
        onStatus: @escaping @Sendable (Status) -> Void
    ) {
        self.onNote = onNote
        self.onStatus = onStatus
    }

    func start(listensToEverything: Bool) {
        lock.withLock { self.listensToEverything = listensToEverything }
        if client == 0 {
            MIDIClientCreateWithBlock("Hope Lights" as CFString, &client) { [weak self] notification in
                if notification.pointee.messageID == .msgSetupChanged {
                    DispatchQueue.main.async { self?.reconnect() }
                }
            }
            // Each source is connected with its own endpoint as the refCon,
            // which is how a packet says where it came from.
            MIDIInputPortCreateWithProtocol(client, "Hope Lights In" as CFString, ._1_0, &port) { [weak self] list, refCon in
                self?.receive(list, source: refCon.map { MIDIEndpointRef(UInt(bitPattern: $0)) })
            }
            MIDIDestinationCreateWithProtocol(client, "Hope Lights" as CFString, ._1_0, &destination) { [weak self] list, _ in
                self?.receive(list, source: nil)
            }
            let session = MIDINetworkSession.default()
            session.isEnabled = true
            session.connectionPolicy = .anyone
        }
        reconnect()
    }

    func setListensToEverything(_ value: Bool) {
        lock.withLock { listensToEverything = value }
        reconnect()
    }

    private func reconnect() {
        let everything = lock.withLock { listensToEverything }
        lock.withLock {
            for source in connected { MIDIPortDisconnectSource(port, source) }
            connected = []
        }
        let network = MIDINetworkSession.default().sourceEndpoint()
        var names: [String] = []
        for index in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(index)
            let name = Self.name(of: source)
            let isScreens = name.localizedCaseInsensitiveContains("Screens")
            guard everything || isScreens || source == network else { continue }
            if MIDIPortConnectSource(port, source, UnsafeMutableRawPointer(bitPattern: UInt(source))) == noErr {
                lock.withLock { connected.append(source) }
                names.append(source == network ? "Network MIDI" : name)
            }
        }
        onStatus(Status(connected: names, networkPort: Int(MIDINetworkSession.default().networkPort)))
    }

    private func receive(_ list: UnsafePointer<MIDIEventList>, source: MIDIEndpointRef?) {
        let sourceName = source.map(Self.name(of:)) ?? "Hope Lights"
        for packet in list.unsafeSequence() {
            let count = Int(packet.pointee.wordCount)
            withUnsafeBytes(of: packet.pointee.words) { raw in
                let words = raw.bindMemory(to: UInt32.self)
                for i in 0..<min(count, words.count) {
                    if let message = MIDINote.noteOn(ump: words[i]) {
                        onNote(message.channel, message.note, sourceName)
                    }
                }
            }
        }
    }

    static func name(of endpoint: MIDIEndpointRef) -> String {
        var value: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &value) == noErr,
              let name = value?.takeRetainedValue()
        else { return "MIDI" }
        return name as String
    }
}
