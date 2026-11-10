import Foundation

/// One group's setting in a cue.
public struct GroupLook: Codable, Hashable, Sendable {
    /// nil for brightness-only groups.
    public var color: LightColor?
    /// 0–1.
    public var level: Double

    public init(color: LightColor? = nil, level: Double) {
        self.color = color
        self.level = level
    }

    public static let off = GroupLook(level: 0)

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        color = try? c.decodeIfPresent(LightColor.self, forKey: .color)
        level = min(max(try c.decodeIfPresent(Double.self, forKey: .level) ?? 0, 0), 1)
    }
}

public struct Cue: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// The Screens position this cue answers to ("song1", "custom:Recognition").
    /// nil for a cue only fired by hand, like Blackout.
    public var screensPosition: String?
    /// The MIDI note Screens sends for that position.
    public var note: Int?
    /// Seconds to fade from whatever is up into this cue.
    public var fade: Double
    public var looks: [String: GroupLook]
    /// The picture dropped on this cue, by file name in the show's image
    /// folder, and the colours found in it.
    public var image: String?
    public var palette: [LightColor]?
    /// Whether the SlimPARs take their colour from Screens' background when
    /// Screens starts this cue. nil: the default, on for songs only.
    public var matchesScreens: Bool?

    public init(
        id: String = UUID().uuidString, name: String, screensPosition: String? = nil, note: Int? = nil,
        fade: Double = 5, looks: [String: GroupLook] = [:], image: String? = nil, palette: [LightColor]? = nil
    ) {
        self.id = id
        self.name = name
        self.screensPosition = screensPosition
        self.note = note
        self.fade = fade
        self.looks = looks
        self.image = image
        self.palette = palette
    }

    /// A cue missing a field reads with its default rather than failing the
    /// whole show: a hand-edited or older file still opens.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Cue"
        screensPosition = try c.decodeIfPresent(String.self, forKey: .screensPosition)
        note = try c.decodeIfPresent(Int.self, forKey: .note)
        fade = max(try c.decodeIfPresent(Double.self, forKey: .fade) ?? 5, 0)
        looks = (try? c.decodeIfPresent([String: GroupLook].self, forKey: .looks)) ?? [:]
        image = try c.decodeIfPresent(String.self, forKey: .image)
        palette = try? c.decodeIfPresent([LightColor].self, forKey: .palette)
        matchesScreens = try? c.decodeIfPresent(Bool.self, forKey: .matchesScreens)
    }

    /// Screens' song positions: song1, song2…
    public var isSong: Bool { screensPosition?.hasPrefix("song") == true }

    /// Songs match Screens' background unless turned off; walk-in, message
    /// and the rest keep their own colours unless turned on.
    public var followsScreensBackground: Bool { matchesScreens ?? isSong }

    /// This cue with every SlimPAR group in one colour, levels as they are:
    /// a SlimPAR the cue keeps dark stays dark.
    public func withSlimparColor(_ color: LightColor, rig: Rig) -> Cue {
        var cue = self
        for group in rig.groups where group.isSlimpar {
            var look = cue.look(for: group)
            look.color = color
            cue.set(look, for: group)
        }
        return cue
    }

    /// A group the cue doesn't mention is off, and white if it takes colour,
    /// so a new group added to the rig starts dark in every old cue.
    public func look(for group: LightGroup) -> GroupLook {
        var look = looks[group.id] ?? .off
        if group.hasColor, look.color == nil { look.color = .white }
        if !group.hasColor { look.color = nil }
        return look
    }

    public mutating func set(_ look: GroupLook, for group: LightGroup) {
        looks[group.id] = look
    }
}

public struct Show: Codable, Sendable, Equatable {
    /// Bumped only for a change old builds can't read.
    public var version: Int
    public var cues: [Cue]

    public init(version: Int = 1, cues: [Cue]) {
        self.version = version
        self.cues = cues
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        cues = try c.decode([Cue].self, forKey: .cues)
    }

    /// The show imported from the church's Lightkey project, which a new
    /// install starts from.
    public static func bundledDefault() -> Show {
        guard let url = Bundle.module.url(forResource: "DefaultShow", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let show = try? JSONDecoder().decode(Show.self, from: data)
        else { fatalError("DefaultShow.json is missing or unreadable") }
        return show
    }

    /// The cue Screens means by a note. The first in the list wins if two
    /// share one.
    public func cue(forNote note: Int) -> Cue? {
        cues.first { $0.note == note }
    }
}

/// Screens' lighting positions and the notes it sends for them by default
/// (PresenterCore's LightingCueTable). Screens' own table is the authority;
/// a cue's note can be changed, or learned, to follow it.
public enum ScreensPositions {
    public static let defaults: [(key: String, title: String, note: Int)] = [
        ("walkIn", "Walk-in", 60), ("countdown", "Countdown", 61),
        ("song1", "Song 1", 62), ("song2", "Song 2", 63), ("song3", "Song 3", 64),
        ("song4", "Song 4", 65), ("song5", "Song 5", 66),
        ("announcements", "Announcements", 67), ("message", "Message", 68),
        ("closing", "Closing", 69), ("walkout", "Walkout", 70),
        ("baptism", "Baptism", 71), ("communion", "Communion", 72),
    ]

    /// What Screens calls a position.
    public static func title(_ key: String) -> String {
        if key.hasPrefix("custom:") { return String(key.dropFirst("custom:".count)) }
        return defaults.first { $0.key == key }?.title ?? key
    }
}
