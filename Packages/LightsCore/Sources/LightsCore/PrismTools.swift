import Foundation

/// What Claude's tools need from the app. The app model is the real one; the
/// tests use a stand-in, so every tool is tested without a window or lights.
@MainActor
public protocol PrismControl: AnyObject, Sendable {
    var rig: Rig { get }
    var show: Show { get }
    var liveCueID: String? { get }
    var outputEnabled: Bool { get set }
    var followsScreens: Bool { get set }
    func status() -> PrismStatus
    /// Puts a cue up, over its own fade unless one is given.
    func go(cueID: String, fade: Double?)
    /// The app's one path for changing the show: saved, and shown in the room
    /// at once when it touches the live cue.
    func editShow(_ change: (inout Show) -> Void)
    /// False for the live cue or the last one.
    func deleteCue(_ id: String) -> Bool
}

/// The parts of the app's state that aren't the show.
public struct PrismStatus: Encodable, Sendable {
    public var midiInputs: [String]
    /// Other sACN sources on Prism's universes: Lightkey left open, usually.
    public var otherSourcesSending: [String]
    public var networks: [String]
    /// The colour the live cue's SlimPARs took from Screens' background.
    public var screensColor: String?
    public var screensProblem: String?

    public init(midiInputs: [String], otherSourcesSending: [String], networks: [String],
                screensColor: String?, screensProblem: String?) {
        self.midiInputs = midiInputs
        self.otherSourcesSending = otherSourcesSending
        self.networks = networks
        self.screensColor = screensColor
        self.screensProblem = screensProblem
    }
}

public enum PrismTools {
    public static let instructions = """
        Prism runs the stage and house lights at Hope Church in Johnson City, in place of Lightkey. \
        A cue is one look: a colour and brightness for each group of lights, and a fade time. Screens, \
        the church's presentation app, puts cues up by MIDI note as the service moves through its items.

        go_cue changes the room at once, and so does any change to the live cue (get_status says which \
        cue is live). During a service, check with the person before doing either.

        Brightness is 0–100. Colours are hex (#FF8800) or one of the named colours list_groups returns. \
        Cues are named by their name ("Song 1") or id. To match a picture, look at it yourself and pick \
        its colours.
        """

    public static func server(control: some PrismControl, version: String) -> MCPServer {
        MCPServer(version: version, instructions: instructions, tools: tools(control: control))
    }

    public static func tools(control: some PrismControl) -> [MCPTool] {
        let cueArgument: JSONValue = ["type": "string", "description": "The cue's name (\"Song 1\") or id."]
        return [
            MCPTool(
                name: "get_status", title: "Get status",
                description: "What's live, whether Prism is sending to the lights and following Screens, the MIDI inputs connected, and anything else sending to the lights.",
                inputSchema: ["type": "object", "properties": [:]], readOnly: true
            ) { _ in
                MCPToolResult.json(StatusReport(control: control))
            },
            MCPTool(
                name: "list_cues", title: "List cues",
                description: "Every cue in order: name, Screens note, fade, the colours it puts in the room, and which is live.",
                inputSchema: ["type": "object", "properties": [:]], readOnly: true
            ) { _ in
                MCPToolResult.json(["cues": control.show.cues.map { CueSummary($0, control: control) }])
            },
            MCPTool(
                name: "get_cue", title: "Get cue",
                description: "One cue in full: every group's colour and brightness, its fade, Screens note and whether its SlimPARs match Screens' background.",
                inputSchema: ["type": "object", "properties": ["cue": cueArgument], "required": ["cue"]], readOnly: true
            ) { arguments in
                let cue = try resolveCue(arguments["cue"], in: control)
                return MCPToolResult.json(CueReport(cue, control: control))
            },
            MCPTool(
                name: "list_groups", title: "List groups and colours",
                description: "The groups of lights a cue sets (SlimPARs, Pixel Stix, Wall Wash, washes, spots, Blinders, House Lights), which take a colour, and the church's named colours.",
                inputSchema: ["type": "object", "properties": [:]], readOnly: true
            ) { _ in
                MCPToolResult.json(GroupList(rig: control.rig))
            },
            MCPTool(
                name: "go_cue", title: "Go to cue",
                description: "Puts a cue up in the room now, over its own fade unless fade_seconds is given. Blackout is a cue too.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "cue": cueArgument,
                        "fade_seconds": ["type": "number", "minimum": 0, "maximum": 600],
                    ],
                    "required": ["cue"],
                ]
            ) { arguments in
                let cue = try resolveCue(arguments["cue"], in: control)
                let fade = try seconds(arguments["fade_seconds"])
                control.go(cueID: cue.id, fade: fade)
                let summary = control.outputEnabled
                    ? "\(cue.name) is live, fading over \(format(fade ?? cue.fade)) seconds."
                    : "\(cue.name) is live in Prism, but sending to the lights is off."
                return MCPToolResult(text: summary)
            },
            MCPTool(
                name: "set_look", title: "Set colour and brightness",
                description: "Sets a colour, a brightness, or both on groups in one cue. groups takes group ids or names from list_groups, or \"slimpars\" (all three SlimPAR groups), \"stage\", \"house\" or \"all\". A colour is skipped on groups that only take a brightness. Changing the live cue changes the room at once.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "cue": cueArgument,
                        "groups": ["type": "array", "items": ["type": "string"], "minItems": 1],
                        "color": ["type": "string", "description": "Hex (#FF8800) or a named colour."],
                        "brightness": ["type": "number", "minimum": 0, "maximum": 100],
                    ],
                    "required": ["cue", "groups"],
                ]
            ) { arguments in
                let cue = try resolveCue(arguments["cue"], in: control)
                let groups = try resolveGroups(arguments["groups"], rig: control.rig)
                let color = try arguments["color"].map(resolveColor)
                let level = try brightness(arguments["brightness"])
                guard color != nil || level != nil else {
                    throw MCPToolError("Give a color, a brightness, or both.")
                }
                control.editShow { show in
                    guard var edited = show.cue(cue.id) else { return }
                    for group in groups {
                        var look = edited.look(for: group)
                        if let color, group.hasColor { look.color = color }
                        if let level { look.level = level }
                        edited.set(look, for: group)
                    }
                    show.replace(edited)
                }
                let updated = control.show.cue(cue.id) ?? cue
                var notes: [String] = []
                if color != nil {
                    let brightnessOnly = groups.filter { !$0.hasColor }.map(\.name)
                    if !brightnessOnly.isEmpty { notes.append("\(brightnessOnly.joined(separator: ", ")) only take a brightness.") }
                }
                if level == nil {
                    let dark = groups.filter { updated.look(for: $0).level == 0 }.map(\.name)
                    if !dark.isEmpty { notes.append("\(dark.joined(separator: ", ")) are at 0%, so the colour won't show until they're brought up.") }
                }
                if updated.id == control.liveCueID { notes.append("This cue is live, so the room changed.") }
                let summary = (["Updated \(updated.name)."] + notes).joined(separator: " ")
                return MCPToolResult.json(CueReport(updated, control: control), summary: summary)
            },
            MCPTool(
                name: "update_cue", title: "Update cue",
                description: "Renames a cue, or sets its fade, the Screens MIDI note that fires it (null clears it; a cue already on that note lets go), or whether its SlimPARs take their colour from Screens' background when Screens fires it (songs do by default).",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "cue": cueArgument,
                        "name": ["type": "string"],
                        "fade_seconds": ["type": "number", "minimum": 0, "maximum": 600],
                        "screens_note": ["type": ["integer", "null"], "minimum": 0, "maximum": 127],
                        "match_screens_background": ["type": "boolean"],
                    ],
                    "required": ["cue"],
                ]
            ) { arguments in
                let cue = try resolveCue(arguments["cue"], in: control)
                let name = try arguments["name"].map { value -> String in
                    guard let text = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                        throw MCPToolError("A name can't be empty.")
                    }
                    if control.show.cues.contains(where: { $0.id != cue.id && $0.name.lowercased() == text.lowercased() }) {
                        throw MCPToolError("There's already a cue called \(text).")
                    }
                    return text
                }
                let fade = try seconds(arguments["fade_seconds"])
                var note: Int?? = nil
                if let value = arguments["screens_note"] {
                    if value == .null {
                        note = .some(nil)
                    } else {
                        guard let number = value.intValue, (0...127).contains(number) else {
                            throw MCPToolError("screens_note is a MIDI note, 0–127, or null.")
                        }
                        note = .some(number)
                    }
                }
                var matches: Bool?
                if let value = arguments["match_screens_background"] {
                    guard let flag = value.boolValue else { throw MCPToolError("match_screens_background is true or false.") }
                    matches = flag
                }
                let previousHolder = note.flatMap { $0 }.flatMap { control.show.cue(forNote: $0) }
                control.editShow { show in
                    if let name { show.rename(cue.id, to: name) }
                    guard var edited = show.cue(cue.id) else { return }
                    if let fade { edited.fade = fade }
                    if let matches { edited.matchesScreens = matches }
                    if case .some(nil) = note { edited.note = nil }
                    show.replace(edited)
                    if case .some(let number?) = note { show.assign(note: number, to: cue.id) }
                }
                let updated = control.show.cue(cue.id) ?? cue
                var summary = "Updated \(updated.name)."
                if let previousHolder, previousHolder.id != cue.id {
                    summary += " \(previousHolder.name) no longer has a Screens note."
                }
                return MCPToolResult.json(CueReport(updated, control: control), summary: summary)
            },
            MCPTool(
                name: "add_cue", title: "Add cue",
                description: "Adds a cue before Blackout with the next free Screens note (73 and up). It starts as a copy of based_on's look, or dark. In Screens, add a row with that note under Settings › Lightkey & MIDI › Add Cue… for Screens to fire it.",
                inputSchema: [
                    "type": "object",
                    "properties": ["name": ["type": "string"], "based_on": cueArgument],
                    "required": ["name"],
                ]
            ) { arguments in
                guard let name = arguments["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                    throw MCPToolError("Give the new cue a name.")
                }
                if control.show.cues.contains(where: { $0.name.lowercased() == name.lowercased() }) {
                    throw MCPToolError("There's already a cue called \(name).")
                }
                let base = try arguments["based_on"].map { try resolveCue($0, in: control) }
                var added: Cue?
                control.editShow { show in
                    var cue = show.addCue(basedOn: base)
                    show.rename(cue.id, to: name)
                    cue = show.cue(cue.id) ?? cue
                    added = cue
                }
                guard let added = added.flatMap({ control.show.cue($0.id) }) else { throw MCPToolError("Couldn't add the cue.") }
                return MCPToolResult.json(CueReport(added, control: control), summary: "Added \(added.name) on note \(added.note ?? 0).")
            },
            MCPTool(
                name: "duplicate_cue", title: "Duplicate cue",
                description: "Copies a cue to just after it, with its own name and the next free Screens note.",
                inputSchema: ["type": "object", "properties": ["cue": cueArgument], "required": ["cue"]]
            ) { arguments in
                let cue = try resolveCue(arguments["cue"], in: control)
                var copy: Cue?
                control.editShow { copy = $0.duplicate(cue.id) }
                guard let copy else { throw MCPToolError("Couldn't copy \(cue.name).") }
                return MCPToolResult.json(CueReport(copy, control: control), summary: "Copied \(cue.name) to \(copy.name).")
            },
            MCPTool(
                name: "move_cue", title: "Move cue",
                description: "Moves a cue to a place in the list, 1 being the top. The order is only for reading the list; Screens fires cues by note.",
                inputSchema: [
                    "type": "object",
                    "properties": ["cue": cueArgument, "position": ["type": "integer", "minimum": 1]],
                    "required": ["cue", "position"],
                ]
            ) { arguments in
                let cue = try resolveCue(arguments["cue"], in: control)
                guard let position = arguments["position"]?.intValue, position >= 1 else {
                    throw MCPToolError("position is 1 or more.")
                }
                control.editShow { show in
                    guard let from = show.cues.firstIndex(where: { $0.id == cue.id }) else { return }
                    let moved = show.cues.remove(at: from)
                    show.cues.insert(moved, at: min(position - 1, show.cues.count))
                }
                return MCPToolResult.json(["cues": control.show.cues.map(\.name)], summary: "Moved \(cue.name).")
            },
            MCPTool(
                name: "delete_cue", title: "Delete cue",
                description: "Deletes a cue. Without confirm it only says what would be deleted; ask the person, then call again with confirm true. The live cue can't be deleted.",
                inputSchema: [
                    "type": "object",
                    "properties": ["cue": cueArgument, "confirm": ["type": "boolean"]],
                    "required": ["cue"],
                ]
            ) { arguments in
                let cue = try resolveCue(arguments["cue"], in: control)
                guard cue.id != control.liveCueID else {
                    throw MCPToolError("\(cue.name) is live. Put another cue up first.")
                }
                guard control.show.cues.count > 1 else { throw MCPToolError("\(cue.name) is the only cue.") }
                let note = cue.note.map { " Screens' note \($0) will fire nothing." } ?? ""
                guard arguments["confirm"]?.boolValue == true else {
                    return MCPToolResult(text: "This would delete \(cue.name).\(note) It can't be undone here. Ask the person, then call again with confirm true.")
                }
                guard control.deleteCue(cue.id) else { throw MCPToolError("Couldn't delete \(cue.name).") }
                return MCPToolResult(text: "Deleted \(cue.name).\(note)")
            },
            MCPTool(
                name: "set_options", title: "Set options",
                description: "Turns sending to the lights on or off (off leaves the room to another app, such as Lightkey), and following Screens on or off (off: only Prism's own window and these tools change cues).",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "sending_to_lights": ["type": "boolean"],
                        "follow_screens": ["type": "boolean"],
                    ],
                ]
            ) { arguments in
                if let value = arguments["sending_to_lights"] {
                    guard let flag = value.boolValue else { throw MCPToolError("sending_to_lights is true or false.") }
                    control.outputEnabled = flag
                }
                if let value = arguments["follow_screens"] {
                    guard let flag = value.boolValue else { throw MCPToolError("follow_screens is true or false.") }
                    control.followsScreens = flag
                }
                return MCPToolResult.json(StatusReport(control: control))
            },
        ]
    }

    // MARK: Arguments

    /// By id, then by name, ignoring case and spaces at the ends.
    @MainActor
    static func resolveCue(_ value: JSONValue?, in control: some PrismControl) throws -> Cue {
        guard let text = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw MCPToolError("Name the cue.")
        }
        let cues = control.show.cues
        if let cue = cues.first(where: { $0.id == text }) ?? cues.first(where: { $0.name.lowercased() == text.lowercased() }) {
            return cue
        }
        throw MCPToolError("No cue called \(text). The cues are: \(cues.map(\.name).joined(separator: ", ")).")
    }

    static func resolveGroups(_ value: JSONValue?, rig: Rig) throws -> [LightGroup] {
        let names = value?.arrayValue?.compactMap(\.stringValue) ?? value?.stringValue.map { [$0] } ?? []
        guard !names.isEmpty else { throw MCPToolError("Name at least one group.") }
        func key(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
        var result: [LightGroup] = []
        for name in names {
            let wanted = key(name)
            let matched: [LightGroup] = switch wanted {
            case "all": rig.groups
            case "slimpars": rig.groups.filter(\.isSlimpar)
            case "stage": rig.groups.filter { $0.section == .stage }
            case "house", "houselights": rig.groups.filter { $0.section == .house }
            default: rig.groups.filter { key($0.id) == wanted || key($0.name) == wanted }
            }
            guard !matched.isEmpty else {
                throw MCPToolError("No group called \(name). The groups are: \(rig.groups.map(\.name).joined(separator: ", ")).")
            }
            for group in matched where !result.contains(group) { result.append(group) }
        }
        return result
    }

    static func resolveColor(_ value: JSONValue) throws -> LightColor {
        guard let text = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw MCPToolError("color is a hex string like #FF8800.")
        }
        if let swatch = Swatch.all.first(where: { $0.name.lowercased() == text.lowercased() }) { return swatch.color }
        if let color = LightColor(hex: text) { return color }
        throw MCPToolError("\(text) isn't a colour. Use hex like #FF8800 or one of: \(Swatch.all.map(\.name).joined(separator: ", ")).")
    }

    static func brightness(_ value: JSONValue?) throws -> Double? {
        guard let value else { return nil }
        guard let number = value.doubleValue, (0...100).contains(number) else {
            throw MCPToolError("brightness is 0–100.")
        }
        return number / 100
    }

    static func seconds(_ value: JSONValue?) throws -> Double? {
        guard let value else { return nil }
        guard let number = value.doubleValue, (0...600).contains(number) else {
            throw MCPToolError("A fade is 0–600 seconds.")
        }
        return number
    }

    static func format(_ seconds: Double) -> String {
        seconds.rounded() == seconds ? String(Int(seconds)) : String(format: "%.1f", seconds)
    }

    /// 0–1 as a percentage, to a tenth where it matters (the blinders sit at 1%).
    static func percent(_ level: Double) -> Double { (level * 1000).rounded() / 10 }
}

// MARK: Reports

private struct StatusReport: Encodable {
    var liveCue: String?
    var sendingToLights: Bool
    var followingScreens: Bool
    var status: PrismStatus

    @MainActor
    init(control: some PrismControl) {
        liveCue = control.show.cue(control.liveCueID)?.name
        sendingToLights = control.outputEnabled
        followingScreens = control.followsScreens
        status = control.status()
    }

    enum CodingKeys: CodingKey { case liveCue, sendingToLights, followingScreens }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(liveCue, forKey: .liveCue)
        try c.encode(sendingToLights, forKey: .sendingToLights)
        try c.encode(followingScreens, forKey: .followingScreens)
        try status.encode(to: encoder)
    }
}

private struct CueSummary: Encodable {
    var id: String
    var name: String
    var live: Bool
    var screensNote: Int?
    var fadeSeconds: Double
    var colors: [String]
    var matchesScreensBackground: Bool

    @MainActor
    init(_ cue: Cue, control: some PrismControl) {
        id = cue.id
        name = cue.name
        live = cue.id == control.liveCueID
        screensNote = cue.note
        fadeSeconds = cue.fade
        colors = cue.colors(in: control.rig).map(\.hex)
        matchesScreensBackground = cue.followsScreensBackground
    }
}

private struct CueReport: Encodable {
    struct Look: Encodable {
        var group: String
        var name: String
        var color: String?
        var brightness: Double
    }

    var id: String
    var name: String
    var live: Bool
    var screensPosition: String?
    var screensNote: Int?
    var fadeSeconds: Double
    var matchesScreensBackground: Bool
    var looks: [Look]
    var pictureColors: [String]?

    @MainActor
    init(_ cue: Cue, control: some PrismControl) {
        id = cue.id
        name = cue.name
        live = cue.id == control.liveCueID
        screensPosition = cue.screensPosition.map(ScreensPositions.title)
        screensNote = cue.note
        fadeSeconds = cue.fade
        matchesScreensBackground = cue.followsScreensBackground
        looks = control.rig.groups.map { group in
            let look = cue.look(for: group)
            return Look(group: group.id, name: group.name, color: look.color?.hex, brightness: PrismTools.percent(look.level))
        }
        pictureColors = cue.palette?.map(\.hex)
    }
}

private struct GroupList: Encodable {
    struct Group: Encodable {
        var id: String
        var name: String
        var section: String
        var takesColor: Bool
        var fixtures: [String]
    }

    struct Named: Encodable {
        var name: String
        var hex: String
    }

    var groups: [Group]
    var namedColors: [Named]

    init(rig: Rig) {
        groups = rig.groups.map {
            Group(id: $0.id, name: $0.name, section: $0.section.rawValue, takesColor: $0.hasColor, fixtures: $0.fixtures)
        }
        namedColors = Swatch.all.map { Named(name: $0.name, hex: $0.color.hex) }
    }
}
