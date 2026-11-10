import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation
import Testing
@testable import LightsCore

@Suite struct RigTests {
    @Test func patchHasNoOverlaps() {
        #expect(Rig.hope.patchProblems().isEmpty)
        #expect(Rig.hope.fixtures.count == 88)
    }

    /// Spot checks against the Lightkey patch ("Hope NEW - FINAL").
    @Test func addressesMatchLightkey() {
        let expected: [(String, Int, Int)] = [
            ("FX1", 1, 1), ("P4", 1, 8), ("P1", 1, 17), ("P8", 1, 20), ("P5", 1, 29), ("P16", 1, 53),
            ("B1", 1, 60), ("B3", 1, 66), ("B2", 1, 72), ("B4", 1, 78),
            ("U1", 1, 90), ("U16", 1, 270), ("BL1", 1, 290), ("BL4", 1, 302),
            ("DW1", 1, 310), ("DW8", 1, 317), ("E1", 1, 318), ("E4", 1, 327),
            ("H36", 2, 1), ("H2", 2, 6), ("H35", 2, 171),
        ]
        for (name, universe, address) in expected {
            let fixture = Rig.hope.fixture(name)
            #expect(fixture?.universe == universe, "\(name)")
            #expect(fixture?.address == address, "\(name)")
        }
    }

    @Test func everyFixtureIsInAGroup() {
        let grouped = Set(Rig.hope.groups.flatMap(\.fixtures))
        #expect(Set(Rig.hope.fixtures.map(\.name)) == grouped)
    }
}

@Suite struct ColorTests {
    @Test func hexRoundTrips() {
        #expect(LightColor(hex: "#FF00E5")?.hex == "#FF00E5")
        #expect(LightColor(hex: "ff00e5")?.hex == "#FF00E5")
        #expect(LightColor(hex: "#F0E")?.hex == "#FF00EE")
        #expect(LightColor(hex: "#GG0000") == nil)
        #expect(LightColor(hex: "#12345") == nil)
    }

    @Test func whiteLEDTakesTheWhiteContent() {
        let pastel = Emitters.mix(LightColor(hex: "#FFF1B9")!, hasWhite: true)
        #expect(pastel.red == 1)
        #expect(abs(pastel.white - 185.0 / 255) < 0.001)
        let pink = Emitters.mix(LightColor(hex: "#FF00E5")!, hasWhite: true)
        #expect(pink.white == 0)
        #expect(Emitters.mix(.white, hasWhite: false).white == 0)
    }

    @Test func fullStrengthKeepsTheHue() {
        let dark = LightColor(red: 0, green: 0.1, blue: 0.4).atFullStrength
        #expect(dark.blue == 1)
        #expect(abs(dark.green - 0.25) < 0.0001)
    }
}

@Suite struct ShowTests {
    @Test func defaultShowHasTheChurchsCues() {
        let show = Show.bundledDefault()
        #expect(show.cues.map(\.name) == [
            "Walk-in", "Countdown", "Song 1", "Announcements", "Song 2", "Song 3", "Song 4",
            "Message", "Song 5", "Closing", "Walk Out", "Communion", "Baptisms", "Recognition", "Blackout",
        ])
        for cue in show.cues {
            #expect(Set(cue.looks.keys) == Set(Rig.hope.groups.map(\.id)), "\(cue.name)")
        }
    }

    @Test func notesFollowScreensDefaults() {
        let show = Show.bundledDefault()
        for position in ScreensPositions.defaults {
            #expect(show.cues.first { $0.screensPosition == position.key }?.note == position.note, "\(position.key)")
        }
        #expect(show.cue(forNote: 73)?.name == "Recognition")
        let notes = show.cues.compactMap(\.note)
        #expect(notes.count == Set(notes).count)
    }

    @Test func song1MatchesLightkey() {
        let cue = Show.bundledDefault().cues.first { $0.id == "song1" }!
        #expect(cue.looks["screenSlimpars"] == GroupLook(color: LightColor(hex: "#FF00E5"), level: 0.25))
        #expect(cue.looks["ceilingSlimpars"] == GroupLook(color: LightColor(hex: "#0055FF"), level: 0.25))
        #expect(cue.looks["frontWash"]?.level == 0.75)
        #expect(cue.fade == 5)
    }

    @Test func showRoundTripsThroughDisk() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ShowStore(folder: folder)
        #expect(store.load() == Show.bundledDefault())
        var show = Show.bundledDefault()
        show.cues[0].name = "Doors"
        try store.save(show)
        #expect(store.load().cues[0].name == "Doors")
    }

    @Test func unreadableShowIsKeptAside() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ShowStore(folder: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.showURL)
        #expect(store.load() == Show.bundledDefault())
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(files.contains { $0.hasPrefix("Show-unreadable-") })
    }
}

@Suite struct RenderTests {
    @Test func song1Channels() {
        let cue = Show.bundledDefault().cues.first { $0.id == "song1" }!
        let frame = Renderer.frame(for: cue, rig: .hope)
        // U1: dimmer 25%, pink, shutter open, everything else 0.
        #expect(frame.channels(of: Rig.hope.fixture("U1")!) == [64, 255, 0, 229, 0, 0, 0, 0, 0, 0, 0, 0])
        // U9: blue.
        #expect(frame.channels(of: Rig.hope.fixture("U9")!) == [64, 0, 85, 255, 0, 0, 0, 0, 0, 0, 0, 0])
        // Front wash 75%.
        #expect(frame.value(universe: 1, address: 310) == 191)
        // Pixel Stix: driver open, white pixels.
        #expect(frame.channels(of: Rig.hope.fixture("FX1")!) == [255, 0, 0, 0, 0, 0, 0])
        #expect(frame.channels(of: Rig.hope.fixture("P1")!) == [255, 255, 255])
        // House cannons at 5%, white: RGB full, amber off, dimmer 13.
        #expect(frame.channels(of: Rig.hope.fixture("H2")!) == [255, 255, 255, 0, 13])
    }

    /// Every dimmer closed and every pixel dark. Colour channels behind a
    /// closed dimmer may stay mixed: that's how a cue fades up in its colour.
    @Test func blackoutIsDark() {
        let cue = Show.bundledDefault().cues.first { $0.id == "blackout" }!
        let frame = Renderer.frame(for: cue, rig: .hope)
        for fixture in Rig.hope.fixtures {
            let channels = frame.channels(of: fixture)
            let dimmers: [Int] = switch fixture.kind {
            case .slimParProH, .proBar, .pixelStixDriver, .proWashPlus, .eveE50Z: [0]
            case .cobCannonWash: [4]
            case .pixel: [0, 1, 2]
            case .proBlind4: [0, 1, 2, 3]
            }
            #expect(dimmers.allSatisfy { channels[$0] == 0 }, "\(fixture.name)")
        }
    }

    @Test func pixelsCarryTheLevel() {
        #expect(FixtureKind.pixel.channels(color: LightColor(hex: "#FF8000")!, level: 0.5) == [128, 64, 0])
        #expect(FixtureKind.pixelStixDriver.channels(color: .white, level: 0) == [0, 0, 0, 0, 0, 0, 0])
    }
}

final class RecordingSink: FrameSink, @unchecked Sendable {
    var frames: [DMXFrame] = []
    var stopped: [[Int]] = []
    func send(_ frame: DMXFrame) { frames.append(frame) }
    func stop(universes: [Int]) { stopped.append(universes) }
}

final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var sources: [SACNMonitor.Source] = []
    func set(_ s: [SACNMonitor.Source]) { lock.withLock { sources = s } }
    func get() -> [SACNMonitor.Source] { lock.withLock { sources } }
}

final class ManualClock: @unchecked Sendable {
    var now: TimeInterval = 100
}

@Suite struct EngineTests {
    @Test func crossfadeEasesBetweenFrames() {
        var a = DMXFrame(universes: [1]), b = DMXFrame(universes: [1])
        a.universes[1]![0] = 0
        b.universes[1]![0] = 200
        let fade = Crossfade(from: a, to: b, start: 10, duration: 4)
        #expect(fade.frame(at: 10).value(universe: 1, address: 1) == 0)
        #expect(fade.frame(at: 12).value(universe: 1, address: 1) == 100)
        #expect(fade.frame(at: 14).value(universe: 1, address: 1) == 200)
        #expect(fade.frame(at: 11).value(universe: 1, address: 1) < 50) // eased start
    }

    @Test func goFadesFromWhatIsUp() {
        let clock = ManualClock()
        let sink = RecordingSink()
        let engine = LightEngine(rig: .hope, sink: sink, clock: { clock.now })
        let show = Show.bundledDefault()
        let song1 = show.cues.first { $0.id == "song1" }!
        engine.go(song1)
        #expect(engine.liveCueID == "song1")
        clock.now += 2.5
        let mid = engine.currentFrame().value(universe: 1, address: 310)
        #expect(mid > 0 && mid < 191)
        clock.now += 2.5
        #expect(engine.currentFrame() == Renderer.frame(for: song1, rig: .hope))
        engine.tick()
        #expect(sink.frames.count == 1)
    }

    @Test func editsOnlyReachTheLightsForTheLiveCue() {
        let clock = ManualClock()
        let engine = LightEngine(rig: .hope, sink: RecordingSink(), clock: { clock.now })
        let show = Show.bundledDefault()
        var song1 = show.cues.first { $0.id == "song1" }!
        var song2 = show.cues.first { $0.id == "song2" }!
        engine.go(song1, fade: 0)
        song2.looks["frontWash"] = GroupLook(level: 0.1)
        engine.update(song2)
        clock.now += 1
        #expect(engine.currentFrame().value(universe: 1, address: 310) == 191)
        song1.looks["frontWash"] = GroupLook(level: 0.1)
        engine.update(song1)
        clock.now += LightEngine.editFade
        #expect(engine.currentFrame().value(universe: 1, address: 310) == 26)
    }

    @Test func nothingIsSentBeforeTheFirstCue() {
        let sink = RecordingSink()
        let engine = LightEngine(rig: .hope, sink: sink)
        engine.tick()
        engine.shutdown()
        #expect(sink.frames.isEmpty)
        #expect(sink.stopped.isEmpty)
    }

    @Test func nothingGoesOutAfterShutdown() {
        let sink = RecordingSink()
        let engine = LightEngine(rig: .hope, sink: sink)
        engine.go(Show.bundledDefault().cues[0], fade: 0)
        engine.tick()
        engine.shutdown()
        engine.tick()
        engine.setOutputEnabled(true)
        engine.tick()
        engine.shutdown()
        #expect(sink.frames.count == 1)
        #expect(sink.stopped.count == 1)
    }

    @Test func turningOutputOffTerminatesTheStream() {
        let sink = RecordingSink()
        let engine = LightEngine(rig: .hope, sink: sink)
        engine.go(Show.bundledDefault().cues[0])
        engine.setOutputEnabled(false)
        engine.tick()
        #expect(sink.frames.isEmpty)
        #expect(sink.stopped == [[1, 2]])
    }
}

@Suite(.serialized) struct SACNTests {
    @Test func packetLayout() {
        let cid = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        var slots = [UInt8](repeating: 0, count: 512)
        slots[0] = 9
        slots[511] = 7
        let p = SACNPacket.make(universe: 2, slots: slots, sequence: 42, cid: cid, sourceName: "Hope Lights")
        #expect(p.count == 638)
        #expect(Array(p[0..<4]) == [0x00, 0x10, 0x00, 0x00])
        #expect(Array(p[16..<18]) == [0x72, 0x6E])
        #expect(Array(p[38..<40]) == [0x72, 0x58])
        #expect(Array(p[115..<118]) == [0x72, 0x0B, 0x02])
        #expect(p[118] == 0xA1)
        #expect(Array(p[123..<125]) == [0x02, 0x01])
        #expect(p[108] == 100)
        #expect(p[111] == 42)
        #expect(Array(p[113..<115]) == [0, 2])
        #expect(p[125] == 0)
        #expect(p[126] == 9)
        #expect(p[637] == 7)
        let header = SACNPacket.parse(p)
        #expect(header == SACNPacket.Header(cid: cid, sourceName: "Hope Lights", universe: 2, priority: 100, terminated: false))
        let stop = SACNPacket.make(universe: 1, slots: [], sequence: 1, cid: cid, sourceName: "x", terminated: true)
        #expect(SACNPacket.parse(stop)?.terminated == true)
        #expect(SACNPacket.parse([1, 2, 3]) == nil)
    }

    /// Another source on our universes (Lightkey left running) is noticed;
    /// our own packets are not.
    @Test func monitorSeesOtherSources() async throws {
        let loopback = NetworkInterface(name: "lo0", address: "127.0.0.1")
        let ownCID = UUID()
        let seen = Seen()
        let monitor = SACNMonitor(ownCID: ownCID, universes: [1, 2]) { sources in seen.set(sources) }
        monitor.start(interfaces: [loopback])
        defer { monitor.stop() }
        try await Task.sleep(for: .milliseconds(200))
        let ours = SACNSender(cid: ownCID, sourceName: "Hope Lights")
        let theirs = SACNSender(cid: UUID(), sourceName: "Lightkey")
        ours.configure(interfaces: [loopback], unicastAddresses: [])
        theirs.configure(interfaces: [loopback], unicastAddresses: [])
        // The monitor reports once a second.
        for _ in 0..<40 where seen.get().isEmpty {
            ours.send(DMXFrame(universes: [1]))
            theirs.send(DMXFrame(universes: [1]))
            try await Task.sleep(for: .milliseconds(80))
        }
        #expect(seen.get().map(\.name) == ["Lightkey"])
    }

    @Test func multicastAddresses() {
        #expect(SACNPacket.multicastAddress(universe: 1) == "239.255.0.1")
        #expect(SACNPacket.multicastAddress(universe: 300) == "239.255.1.44")
    }

    /// Sends real packets over loopback and reads them back.
    @Test func senderReachesAUnicastListener() throws {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = SACNPacket.port.bigEndian
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        try #require(bound == 0)
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let sender = SACNSender(cid: UUID())
        sender.configure(interfaces: [NetworkInterface(name: "lo0", address: "127.0.0.1")], unicastAddresses: ["127.0.0.1"])
        var frame = DMXFrame(universes: [1])
        frame.universes[1]![89] = 123
        sender.send(frame)

        var buffer = [UInt8](repeating: 0, count: 1024)
        let count = recv(fd, &buffer, buffer.count, 0)
        try #require(count == 638)
        #expect(SACNPacket.parse(Array(buffer[0..<count]))?.universe == 1)
        #expect(buffer[126 + 89] == 123)
    }
}

@Suite struct PaletteTests {
    func image(_ fill: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
        let side = 64
        var bytes = [UInt8](repeating: 255, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let (r, g, b) = fill(x, y)
                let i = (y * side + x) * 4
                bytes[i] = r; bytes[i + 1] = g; bytes[i + 2] = b
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    @Test func darkBackgroundWithABlueGlowReadsBlue() {
        // Mostly near-black, a quarter dim blue.
        let colors = ImagePalette.colors(in: image { x, _ in x < 16 ? (10, 30, 110) : (8, 8, 10) })
        let first = colors[0]
        #expect(first.blue == 1)
        #expect(first.red < 0.2)
    }

    @Test func strongestColourComesFirst() {
        let colors = ImagePalette.colors(in: image { x, _ in x < 44 ? (230, 20, 20) : (20, 200, 40) })
        #expect(colors.count == 2)
        #expect(colors[0].red == 1)
        #expect(colors[1].green == 1)
    }

    @Test func pictureFileIsReadAndStored() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("slide.png")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image { _, _ in (240, 120, 0) }, nil)
        #expect(CGImageDestinationFinalize(destination))
        let picture = try #require(await ImagePalette.picture(at: url))
        #expect(ImagePalette.colors(in: picture).first?.hex == "#FF8000")
        let store = ShowStore(folder: folder)
        let name = try store.storeImage(picture)
        #expect(FileManager.default.fileExists(atPath: store.imageURL(name).path))
    }

    /// A motion background: black for the first half second, then purple.
    /// The frame one second in is the one that counts.
    @Test func videoUsesTheFrameOneSecondIn() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<60 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = CVPixelBufferGetBaseAddress(pixels)!.bindMemory(to: UInt8.self, capacity: 64 * 64 * 4)
            let stride = CVPixelBufferGetBytesPerRow(pixels)
            let bgra: [UInt8] = frame < 15 ? [0, 0, 0, 255] : [220, 0, 120, 255]
            for y in 0..<64 { for x in 0..<64 { for c in 0..<4 { base[y * stride + x * 4 + c] = bgra[c] } } }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        let picture = try #require(await ImagePalette.picture(at: url))
        let first = try #require(ImagePalette.colors(in: picture).first)
        #expect(first.blue == 1)
        #expect(first.red > 0.4 && first.red < 0.7)
        #expect(first.green < 0.25) // H.264 shifts it a little
    }

    @Test func greyPictureGivesWhite() {
        #expect(ImagePalette.colors(in: image { x, _ in let v = UInt8(x * 4); return (v, v, v) }) == [.white])
    }
}

@Suite struct MIDITests {
    @Test func noteOnFromUMP() {
        // Group 0, note-on channel 16, note 62, velocity 127.
        let n = MIDINote.noteOn(ump: 0x209F_3E7F)
        #expect(n?.channel == 16)
        #expect(n?.note == 62)
        #expect(MIDINote.noteOn(ump: 0x209F_3E00) == nil) // velocity 0
        #expect(MIDINote.noteOn(ump: 0x208F_3E7F) == nil) // note-off
        #expect(MIDINote.noteOn(ump: 0x409F_3E7F) == nil) // MIDI 2.0 word
    }

    @Test func packetsAreReadMessageByMessage() {
        // A 64-bit MIDI 2.0 message whose second word looks like a MIDI 1.0
        // note-on, then a real note-on, then SysEx (2 words), then another.
        let words: [UInt32] = [0x4090_3C00, 0x209F_3E7F, 0x209F_3F7F, 0x3016_0102, 0x209F_407F, 0x209F_417F]
        let notes = words.withUnsafeBufferPointer { MIDINote.noteOns(in: $0) }
        #expect(notes.map(\.note) == [63, 65])
    }

    @Test func channelFilter() {
        #expect(MIDINote.accepts(channel: 16, listeningOn: 16))
        #expect(!MIDINote.accepts(channel: 1, listeningOn: 16))
        #expect(MIDINote.accepts(channel: 1, listeningOn: nil))
    }
}

@Suite struct EditingTests {
    @Test func addCueGoesBeforeBlackoutWithAFreeNote() {
        var show = Show.bundledDefault()
        let base = show.cue("song1")
        let added = show.addCue(basedOn: base)
        #expect(show.cues.last?.id == "blackout")
        #expect(show.cues[show.cues.count - 2].id == added.id)
        #expect(added.note == 74) // 73 is Recognition
        #expect(added.looks == base?.looks)
        #expect(added.screensPosition == "custom:New Cue")
        let second = show.addCue(basedOn: nil)
        #expect(second.name == "New Cue 2")
        #expect(second.note == 75)
    }

    @Test func duplicateGetsItsOwnNameAndNote() throws {
        var show = Show.bundledDefault()
        let duplicated = show.duplicate("song1")
        let copy = try #require(duplicated)
        let index = try #require(show.cues.firstIndex { $0.id == "song1" })
        #expect(show.cues[index + 1].id == copy.id)
        #expect(copy.name == "Song 1 copy")
        #expect(copy.note != 62)
        #expect(show.cue(forNote: 62)?.id == "song1")
        let missing = show.duplicate("nope")
        #expect(missing == nil)
    }

    @Test func renameKeepsCustomPositionsInStep() {
        var show = Show.bundledDefault()
        show.rename("custom:Recognition", to: "Honors")
        #expect(show.cue("custom:Recognition")?.screensPosition == "custom:Honors")
        show.rename("song1", to: "Opener")
        #expect(show.cue("song1")?.screensPosition == "song1")
        // Mid-typing, an empty name doesn't leave a "custom:" position behind.
        show.rename("custom:Recognition", to: "  ")
        #expect(show.cue("custom:Recognition")?.screensPosition == "custom:Honors")
    }

    @Test func assigningANoteTakesItFromTheOtherCue() {
        var show = Show.bundledDefault()
        show.assign(note: 62, to: "song2")
        #expect(show.cue("song2")?.note == 62)
        #expect(show.cue("song1")?.note == nil)
        #expect(show.cue(forNote: 62)?.id == "song2")
        show.assign(note: 99, to: "missing")
        #expect(show.cue(forNote: 99) == nil)
    }

    @Test func slimparColourLiftsDarkGroups() {
        var show = Show.bundledDefault()
        let pink = LightColor(hex: "#FF00E5")!
        show.setSlimparColor(pink, in: "blackout", rig: .hope)
        let cue = show.cue("blackout")!
        for group in Rig.hope.groups where group.isSlimpar {
            #expect(cue.look(for: group) == GroupLook(color: pink, level: 0.5))
        }
        #expect(cue.look(for: Rig.hope.group("house")!).level == 0)
        show.setSlimparColor(.white, in: "song1", rig: .hope)
        #expect(show.cue("song1")?.looks["screenSlimpars"]?.level == 0.25)
    }

    @Test func noteActions() {
        let show = Show.bundledDefault()
        #expect(show.action(forNote: 62, learning: nil, followsScreens: true) == .fire(cueID: "song1"))
        #expect(show.action(forNote: 62, learning: nil, followsScreens: false) == .ignore)
        #expect(show.action(forNote: 5, learning: nil, followsScreens: true) == .ignore) // a song-section note
        #expect(show.action(forNote: 62, learning: "song2", followsScreens: true) == .learn(cueID: "song2"))
        #expect(show.action(forNote: 62, learning: "deleted", followsScreens: true) == .fire(cueID: "song1"))
    }

    @Test func replaceReportsRealChangesOnly() {
        var show = Show.bundledDefault()
        let cue = show.cue("song1")!
        let same = show.replace(cue)
        var changed = cue
        changed.fade = 2
        let different = show.replace(changed)
        let unknown = show.replace(Cue(id: "nope", name: "x"))
        #expect(!same)
        #expect(different)
        #expect(!unknown)
    }

    @Test func theLastCueCantBeDeleted() {
        var show = Show(cues: [Cue(id: "a", name: "A"), Cue(id: "b", name: "B")])
        let first = show.delete("a"), last = show.delete("b"), missing = show.delete("missing")
        #expect(first)
        #expect(!last)
        #expect(!missing)
        #expect(show.cues.map(\.id) == ["b"])
    }

    @Test func nextFreeNoteWhenTheTopIsFull() {
        var show = Show.bundledDefault()
        for note in 73...127 { show.cues.append(Cue(name: "n\(note)", note: note)) }
        #expect(show.nextFreeNote() == 59)
    }
}

@Suite struct FileToleranceTests {
    @Test func missingFieldsReadAsDefaults() throws {
        let json = #"{"cues":[{"name":"Bare"},{"id":"x","name":"Odd","fade":-3,"looks":{"house":{"level":4,"color":"nonsense"}}}]}"#
        let show = try JSONDecoder().decode(Show.self, from: Data(json.utf8))
        #expect(show.version == 1)
        #expect(show.cues[0].fade == 5)
        #expect(show.cues[0].looks.isEmpty)
        #expect(!show.cues[0].id.isEmpty)
        #expect(show.cues[1].fade == 0)
        #expect(show.cues[1].looks["house"] == GroupLook(color: nil, level: 1))
        #expect(show.cues[1].look(for: Rig.hope.group("house")!).color == .white)
    }

    @Test func duplicateIDsAreRepaired() throws {
        let json = #"{"version":1,"cues":[{"id":"a","name":"One"},{"id":"a","name":"Two"},{"id":"","name":"Three"}]}"#
        let show = try JSONDecoder().decode(Show.self, from: Data(json.utf8)).repaired()
        #expect(Set(show.cues.map(\.id)).count == 3)
        #expect(show.cues[0].id == "a")
    }

    @Test func emptyShowFallsBackToTheDefault() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ShowStore(folder: folder)
        try store.save(Show(cues: []))
        #expect(store.load() == Show.bundledDefault())
    }

    @Test func previousShowIsKept() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ShowStore(folder: folder)
        _ = store.load() // nothing saved yet: no backup
        #expect(!FileManager.default.fileExists(atPath: store.previousURL.path))
        var show = Show.bundledDefault()
        try store.save(show)
        _ = store.load()
        show.cues[0].name = "Changed"
        try store.save(show)
        let previous = try JSONDecoder().decode(Show.self, from: Data(contentsOf: store.previousURL))
        #expect(previous.cues[0].name == "Walk-in")
        // A bad file at the next launch leaves the good backup alone.
        try Data("{".utf8).write(to: store.showURL)
        _ = store.load()
        let still = try JSONDecoder().decode(Show.self, from: Data(contentsOf: store.previousURL))
        #expect(still.cues[0].name == "Walk-in")
    }

    @Test func unusedImagesAreRemoved() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ShowStore(folder: folder)
        let image = PaletteTests().image { _, _ in (10, 200, 30) }
        let kept = try store.storeImage(image)
        let dropped = try store.storeImage(image)
        let inBackup = try store.storeImage(image)
        var backup = Show.bundledDefault()
        backup.cues[1].image = inBackup
        try JSONEncoder().encode(backup).write(to: store.previousURL)
        var show = Show.bundledDefault()
        show.cues[0].image = kept
        store.removeUnusedImages(keeping: show)
        #expect(FileManager.default.fileExists(atPath: store.imageURL(kept).path))
        #expect(FileManager.default.fileExists(atPath: store.imageURL(inBackup).path))
        #expect(!FileManager.default.fileExists(atPath: store.imageURL(dropped).path))
    }

    @Test func notAPictureGivesNil() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not a png".utf8).write(to: url)
        #expect(await ImagePalette.picture(at: url) == nil)
        #expect(await ImagePalette.picture(at: URL(fileURLWithPath: "/nonexistent/x.mov")) == nil)
    }

    @Test func hugePicturesAreScaledDown() throws {
        let side = 4000
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: side, height: side / 2, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: 0, green: 0.3, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side / 2))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
        let image = try #require(ImagePalette.cgImage(at: url))
        #expect(max(image.width, image.height) == 1280)
        #expect(ImagePalette.colors(in: image).first?.blue == 1)
    }
}

@Suite struct ChannelTests {
    @Test func everyKindFillsItsFootprint() {
        for kind in FixtureKind.allCases {
            for level in [0.0, 0.5, 1.0] {
                #expect(kind.channels(color: LightColor(hex: "#12AB34")!, level: level).count == kind.footprint, "\(kind)")
            }
        }
    }

    @Test func levelsOutOfRangeAreClamped() {
        #expect(FixtureKind.proWashPlus.channels(color: .white, level: 7) == [255])
        #expect(FixtureKind.proWashPlus.channels(color: .white, level: -1) == [0])
    }

    /// Strobe, macro and program channels stay at their off values in every cue,
    /// so no cue can set a SlimPAR strobing or running a built-in program.
    @Test func specialChannelsStayOff() {
        for cue in Show.bundledDefault().cues {
            let frame = Renderer.frame(for: cue, rig: .hope)
            for fixture in Rig.hope.fixtures {
                let ch = frame.channels(of: fixture)
                switch fixture.kind {
                case .slimParProH: #expect(ch[6...].allSatisfy { $0 == 0 }, "\(cue.name) \(fixture.name)")
                case .pixelStixDriver: #expect(ch[1...].allSatisfy { $0 == 0 })
                case .eveE50Z: #expect(ch[1...].allSatisfy { $0 == 0 })
                default: break
                }
            }
        }
    }
}

@Suite struct StressTests {
    /// Cues, edits, output toggles and ticks from many threads at once, the
    /// way MIDI, the UI and the timer meet in the app. Run under
    /// `--sanitize=thread` to catch races.
    @Test func engineSurvivesConcurrentUse() async {
        let sink = RecordingSink()
        let engine = LightEngine(rig: .hope, sink: LockedSink(sink))
        let cues = Show.bundledDefault().cues
        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    for i in 0..<300 {
                        let cue = cues[(i + worker) % cues.count]
                        switch (i + worker) % 5 {
                        case 0: engine.go(cue, fade: 0.01)
                        case 1: engine.update(cue)
                        case 2: engine.tick()
                        case 3: _ = engine.currentFrame()
                        default: engine.setOutputEnabled(i % 2 == 0)
                        }
                    }
                }
            }
        }
        engine.setOutputEnabled(true)
        engine.go(cues[0], fade: 0)
        #expect(engine.currentFrame() == Renderer.frame(for: cues[0], rig: .hope))
    }
}

/// RecordingSink isn't thread-safe; the stress test needs one that is.
final class LockedSink: FrameSink, @unchecked Sendable {
    private let lock = NSLock()
    private let inner: RecordingSink
    init(_ inner: RecordingSink) { self.inner = inner }
    func send(_ frame: DMXFrame) { lock.withLock { inner.send(frame) } }
    func stop(universes: [Int]) { lock.withLock { inner.stop(universes: universes) } }
}

@Suite struct GlowTests {
    @Test func glowsAreTheColoursOnInTheRoom() {
        let show = Show.bundledDefault()
        let song1 = show.cue("song1")!.glows(in: .hope)
        #expect(song1.contains(Glow(color: LightColor(hex: "#FF00E5")!, level: 0.25)))
        #expect(song1.contains(Glow(color: LightColor(hex: "#0055FF")!, level: 0.25)))
        // White is on in several groups; it counts once, at the brightest.
        #expect(song1.filter { $0.color == .white }.map(\.level) == [1])
        #expect(show.cue("blackout")!.glows(in: .hope).isEmpty)
    }
}
