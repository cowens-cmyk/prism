import Foundation

/// The edits the app makes to a show, kept here so they're tested.
extension Show {
    public func cue(_ id: String?) -> Cue? { cues.first { $0.id == id } }

    /// Every cue with its own id: two the same (a hand-edited file) would
    /// make the list select and edit both at once.
    public func repaired() -> Show {
        var show = self
        var seen = Set<String>()
        for index in show.cues.indices {
            if seen.contains(show.cues[index].id) || show.cues[index].id.isEmpty { show.cues[index].id = UUID().uuidString }
            seen.insert(show.cues[index].id)
        }
        return show
    }

    /// Swaps in an edited cue. False when it's unknown or unchanged.
    @discardableResult
    public mutating func replace(_ cue: Cue) -> Bool {
        guard let index = cues.firstIndex(where: { $0.id == cue.id }), cues[index] != cue else { return false }
        cues[index] = cue
        return true
    }

    /// A new cue with the given look, before Blackout so Blackout stays last.
    public mutating func addCue(basedOn base: Cue?) -> Cue {
        let name = uniqueName("New Cue")
        let cue = Cue(
            name: name, screensPosition: "custom:\(name)", note: nextFreeNote(),
            fade: base?.fade ?? 5, looks: base?.looks ?? [:])
        cues.insert(cue, at: cues.firstIndex { $0.id == "blackout" } ?? cues.endIndex)
        return cue
    }

    /// A copy right after the original, with its own name and note (two cues
    /// on one note would leave the second unreachable from Screens).
    public mutating func duplicate(_ id: String) -> Cue? {
        guard let index = cues.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = cues[index]
        copy.id = UUID().uuidString
        copy.name = uniqueName(copy.name + " copy")
        copy.screensPosition = "custom:\(copy.name)"
        copy.note = nextFreeNote()
        cues.insert(copy, at: index + 1)
        return copy
    }

    /// The last cue stays: an empty show has nothing to put in the room.
    @discardableResult
    public mutating func delete(_ id: String) -> Bool {
        guard cues.count > 1, cues.contains(where: { $0.id == id }) else { return false }
        cues.removeAll { $0.id == id }
        return true
    }

    /// Names the cue. A custom cue's Screens position is its name, so the
    /// row in Screens' cue table matches.
    public mutating func rename(_ id: String, to name: String) {
        guard var cue = cue(id) else { return }
        cue.name = name
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if cue.screensPosition?.hasPrefix("custom:") == true, !trimmed.isEmpty {
            cue.screensPosition = "custom:\(trimmed)"
        }
        replace(cue)
    }

    /// Gives a cue a note; any other cue holding it lets go.
    public mutating func assign(note: Int, to id: String) {
        guard cue(id) != nil else { return }
        for index in cues.indices where cues[index].note == note && cues[index].id != id {
            cues[index].note = nil
        }
        if let index = cues.firstIndex(where: { $0.id == id }) { cues[index].note = note }
    }

    /// One colour on every SlimPAR group. A dark group comes up to half, or
    /// the colour just picked wouldn't show.
    public mutating func setSlimparColor(_ color: LightColor, in id: String, rig: Rig) {
        guard var cue = cue(id) else { return }
        for group in rig.groups where group.isSlimpar {
            var look = cue.look(for: group)
            look.color = color
            if look.level == 0 { look.level = 0.5 }
            cue.set(look, for: group)
        }
        replace(cue)
    }

    /// Hope keeps the blinders glowing at 1% in every cue but Blackout. A show
    /// saved before that rule gets it once; a cue already brighter keeps its level.
    public static let blinderFloor = 0.01

    public mutating func liftBlindersToFloor() {
        for index in cues.indices where cues[index].id != "blackout" {
            var look = cues[index].looks["blinders"] ?? .off
            guard look.level < Self.blinderFloor else { continue }
            look.level = Self.blinderFloor
            cues[index].looks["blinders"] = look
        }
    }

    /// The SlimPARs in the songs sit at 10%; Lightkey's 25% was too bright.
    public static let songSlimparLevel = 0.10
    /// What the songs' SlimPARs were before that change.
    static let oldSongSlimparLevel = 0.25

    /// For a show saved before the change: a song's SlimPAR group still at the
    /// old 25% drops to 10%. A level someone set by hand stays.
    public mutating func dimSongSlimpars(rig: Rig) {
        for index in cues.indices where cues[index].isSong {
            for group in rig.groups where group.isSlimpar {
                guard var look = cues[index].looks[group.id],
                      abs(look.level - Self.oldSongSlimparLevel) < 0.001 else { continue }
                look.level = Self.songSlimparLevel
                cues[index].looks[group.id] = look
            }
        }
    }

    /// Screens gives a row added to its table the lowest free note above its
    /// defaults (60–72); so does this.
    public func nextFreeNote() -> Int {
        let used = Set(cues.compactMap(\.note))
        return (73...127).first { !used.contains($0) } ?? (0...59).reversed().first { !used.contains($0) } ?? 127
    }

    func uniqueName(_ base: String) -> String {
        var name = base, n = 2
        while cues.contains(where: { $0.name == name }) {
            name = "\(base) \(n)"
            n += 1
        }
        return name
    }

    public enum NoteAction: Equatable {
        /// The cue waiting to learn a note takes this one.
        case learn(cueID: String)
        case fire(cueID: String)
        case ignore
    }

    /// What a note from Screens does. Learning wins over firing, so pressing
    /// Send in Screens to teach a cue doesn't also change the room.
    public func action(forNote note: Int, learning: String?, followsScreens: Bool) -> NoteAction {
        if let learning, cue(learning) != nil { return .learn(cueID: learning) }
        guard followsScreens, let cue = cue(forNote: note) else { return .ignore }
        return .fire(cueID: cue.id)
    }
}

/// A colour in the room and how bright it is there.
public struct Glow: Hashable, Sendable {
    public var color: LightColor
    public var level: Double
}

extension Cue {
    /// Every colour group that's on, with its level; the same colour twice
    /// counts once, at the brighter level.
    public func glows(in rig: Rig) -> [Glow] {
        var result: [Glow] = []
        for group in rig.groups where group.hasColor {
            let look = look(for: group)
            guard look.level > 0, let color = look.color else { continue }
            if let i = result.firstIndex(where: { $0.color.hex == color.hex }) {
                result[i].level = max(result[i].level, look.level)
            } else {
                result.append(Glow(color: color, level: look.level))
            }
        }
        return result
    }

    /// The colours this cue puts in the room, for the app's background and
    /// colour strips: every colour group that's on, SlimPARs first, each
    /// colour once.
    public func colors(in rig: Rig) -> [LightColor] {
        var seen = Set<String>()
        var result: [LightColor] = []
        for group in rig.groups where group.hasColor {
            let look = look(for: group)
            guard look.level > 0, let color = look.color, seen.insert(color.hex).inserted else { continue }
            result.append(color)
        }
        return result
    }
}
