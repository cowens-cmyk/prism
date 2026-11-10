import Foundation

/// The fixture types Hope owns, each in the DMX mode it is set to. Channel
/// layouts come from the profiles in the church's Lightkey project.
public enum FixtureKind: String, Codable, Sendable, CaseIterable {
    /// Chauvet SlimPAR Pro H USB, 12-channel: dimmer, R G B A W UV, strobe,
    /// colour macro, program, program speed, dimmer speed.
    case slimParProH
    /// ADJ COB Cannon Wash, 5-channel: R G B A, dimmer.
    case cobCannonWash
    /// Pro Church Lights ProBar, AR1.d: dimmer, R G B W A.
    case proBar
    /// The PixelStix driver's own channels (55-channel mode): dimmer, strobe,
    /// two built-in programs, speed, effect colour, sound.
    case pixelStixDriver
    /// One PixelStix pixel: R G B, no dimmer.
    case pixel
    /// Pro Church Lights ProBlind4, Basic: one dimmer per cell.
    case proBlind4
    /// Pro Church Lights ProWashPlus: dimmer only.
    case proWashPlus
    /// Chauvet EVE E-50Z: dimmer, strobe, dimmer speed mode.
    case eveE50Z

    public var footprint: Int {
        switch self {
        case .slimParProH: 12
        case .cobCannonWash: 5
        case .proBar: 6
        case .pixelStixDriver: 7
        case .pixel: 3
        case .proBlind4: 4
        case .proWashPlus: 1
        case .eveE50Z: 3
        }
    }

    public var hasColor: Bool {
        switch self {
        case .slimParProH, .cobCannonWash, .proBar, .pixel: true
        case .pixelStixDriver, .proBlind4, .proWashPlus, .eveE50Z: false
        }
    }

    /// The fixture's channels, in order, for a colour at a level (0–1).
    /// Every other channel is 0, which on each of these is the safe value:
    /// shutter open, no strobe, no macro or built-in program, the fixture's
    /// own dimmer speed.
    public func channels(color: LightColor, level: Double) -> [UInt8] {
        let level = min(max(level, 0), 1)
        func b(_ value: Double) -> UInt8 { UInt8((min(max(value, 0), 1) * 255).rounded()) }
        switch self {
        case .slimParProH:
            let e = Emitters.mix(color, hasWhite: true)
            return [b(level), b(e.red), b(e.green), b(e.blue), b(e.amber), b(e.white), b(e.ultraviolet),
                    0, 0, 0, 0, 0]
        case .cobCannonWash:
            let e = Emitters.mix(color, hasWhite: false)
            return [b(e.red), b(e.green), b(e.blue), b(e.amber), b(level)]
        case .proBar:
            let e = Emitters.mix(color, hasWhite: true)
            return [b(level), b(e.red), b(e.green), b(e.blue), b(e.white), b(e.amber)]
        case .pixelStixDriver:
            // The pixels carry the level themselves (they have no dimmer), so
            // the driver's master only has to be open whenever they're on.
            // That way it doesn't matter whether this master scales the
            // pixels in 55-channel mode.
            return [level > 0 ? 255 : 0, 0, 0, 0, 0, 0, 0]
        case .pixel:
            return [b(color.red * level), b(color.green * level), b(color.blue * level)]
        case .proBlind4:
            return Array(repeating: b(level), count: 4)
        case .proWashPlus:
            return [b(level)]
        case .eveE50Z:
            return [b(level), 0, 0]
        }
    }
}

public struct Fixture: Codable, Hashable, Sendable {
    /// The label on the Lightkey stage plot (U1, H36…).
    public var name: String
    public var kind: FixtureKind
    public var universe: Int
    /// 1-based DMX start address.
    public var address: Int

    public init(name: String, kind: FixtureKind, universe: Int, address: Int) {
        self.name = name
        self.kind = kind
        self.universe = universe
        self.address = address
    }

    /// The last channel this fixture uses.
    public var lastAddress: Int { address + kind.footprint - 1 }
}

/// A set of lights the operator sets together: one colour, one level.
public struct LightGroup: Identifiable, Hashable, Sendable {
    public enum Section: String, CaseIterable, Sendable {
        case slimpars = "SlimPARs"
        case stage = "Stage"
        case house = "House"
    }

    public var id: String
    public var name: String
    public var section: Section
    public var fixtures: [String]
    /// Whether the group takes a colour, or only a brightness.
    public var hasColor: Bool

    public var isSlimpar: Bool { section == .slimpars }
}

public struct Rig: Sendable {
    public var fixtures: [Fixture]
    public var groups: [LightGroup]

    public init(fixtures: [Fixture], groups: [LightGroup]) {
        self.fixtures = fixtures
        self.groups = groups
    }

    public var universes: [Int] { Array(Set(fixtures.map(\.universe))).sorted() }

    public func group(_ id: String) -> LightGroup? { groups.first { $0.id == id } }

    public func fixture(_ name: String) -> Fixture? { fixtures.first { $0.name == name } }

    /// Two fixtures sharing a channel, or a fixture running past 512.
    public func patchProblems() -> [String] {
        var problems: [String] = []
        for fixture in fixtures where fixture.address < 1 || fixture.lastAddress > 512 {
            problems.append("\(fixture.name) is outside 1–512")
        }
        for (i, a) in fixtures.enumerated() {
            for b in fixtures[(i + 1)...] where a.universe == b.universe
                && a.address <= b.lastAddress && b.address <= a.lastAddress {
                problems.append("\(a.name) and \(b.name) overlap")
            }
        }
        let names = Set(fixtures.map(\.name))
        for group in groups {
            for name in group.fixtures where !names.contains(name) {
                problems.append("\(group.name) lists \(name), which isn't patched")
            }
        }
        return problems
    }
}

extension Rig {
    /// Hope's room, as patched in Lightkey ("Hope NEW - FINAL"). Universe 1
    /// is the stage; universe 2 is the house cannons.
    public static let hope: Rig = {
        var fixtures: [Fixture] = []
        func run(_ prefix: String, _ numbers: [Int], _ kind: FixtureKind, universe: Int, from start: Int) {
            for (offset, number) in numbers.enumerated() {
                fixtures.append(Fixture(
                    name: "\(prefix)\(number)", kind: kind, universe: universe,
                    address: start + offset * kind.footprint))
            }
        }
        fixtures.append(Fixture(name: "FX1", kind: .pixelStixDriver, universe: 1, address: 1))
        // The pixels run P4 P3 P2 P1, then P8 P7 P6 P5, then P9–P16: the
        // order the sticks are wired, not their numbers.
        run("P", [4, 3, 2, 1, 8, 7, 6, 5, 9, 10, 11, 12, 13, 14, 15, 16], .pixel, universe: 1, from: 8)
        run("B", [1, 3, 2, 4], .proBar, universe: 1, from: 60)
        run("U", Array(1...16), .slimParProH, universe: 1, from: 90)
        run("BL", Array(1...4), .proBlind4, universe: 1, from: 290)
        run("DW", Array(1...8), .proWashPlus, universe: 1, from: 310)
        run("E", Array(1...4), .eveE50Z, universe: 1, from: 318)
        // The first cannon is labelled H36 in Lightkey; H1 doesn't exist.
        run("H", [36] + Array(2...35), .cobCannonWash, universe: 2, from: 1)

        func names(_ prefix: String, _ numbers: some Sequence<Int>) -> [String] { numbers.map { "\(prefix)\($0)" } }
        let groups = [
            LightGroup(id: "screenSlimpars", name: "Screen SlimPARs", section: .slimpars,
                       fixtures: names("U", 1...8), hasColor: true),
            LightGroup(id: "ceilingSlimpars", name: "Ceiling SlimPARs", section: .slimpars,
                       fixtures: names("U", 9...12), hasColor: true),
            LightGroup(id: "floorSlimpars", name: "Floor SlimPARs", section: .slimpars,
                       fixtures: names("U", 13...16), hasColor: true),
            LightGroup(id: "pixelStix", name: "Pixel Stix", section: .stage,
                       fixtures: ["FX1"] + names("P", 1...16), hasColor: true),
            LightGroup(id: "wallWash", name: "Wall Wash", section: .stage,
                       fixtures: names("B", 1...4), hasColor: true),
            LightGroup(id: "frontWash", name: "Front Wash", section: .stage,
                       fixtures: names("DW", 1...6), hasColor: false),
            LightGroup(id: "rearWash", name: "Rear Wash", section: .stage,
                       fixtures: names("DW", 7...8), hasColor: false),
            LightGroup(id: "stageSpots", name: "Stage Spots", section: .stage,
                       fixtures: ["E1", "E4"], hasColor: false),
            LightGroup(id: "floorSpots", name: "Floor Spots", section: .stage,
                       fixtures: ["E2", "E3"], hasColor: false),
            LightGroup(id: "blinders", name: "Blinders", section: .stage,
                       fixtures: names("BL", 1...4), hasColor: false),
            LightGroup(id: "house", name: "House Lights", section: .house,
                       fixtures: names("H", [36] + Array(2...35)), hasColor: true),
        ]
        return Rig(fixtures: fixtures, groups: groups)
    }()
}
