import Foundation

/// A colour as the operator picks it: plain RGB, 0–1 per channel. Stored as
/// a hex string ("#FF00E5") so the show file reads the way people type it.
public struct LightColor: Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    public static let white = LightColor(red: 1, green: 1, blue: 1)

    /// "#FF00E5", "FF00E5" or the short "#F0E". Anything else is nil.
    public init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") { digits.removeFirst() }
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }

    public var hex: String {
        String(format: "#%02X%02X%02X", Self.byte(red), Self.byte(green), Self.byte(blue))
    }

    static func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }

    /// The same hue at full strength: the brightest channel at 1. Lights show
    /// a dark background's colour this way; the brightness slider sets how much.
    public var atFullStrength: LightColor {
        let peak = max(red, green, blue)
        guard peak > 0 else { return .white }
        return LightColor(red: red / peak, green: green / peak, blue: blue / peak)
    }
}

extension LightColor: Codable {
    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let color = LightColor(hex: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a colour: \(text)"))
        }
        self = color
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

/// A named colour for the picker. The church's own Lightkey colours, so the
/// swatches match what they used before.
public struct Swatch: Identifiable, Sendable {
    public var name: String
    public var color: LightColor
    public var id: String { name }

    public static let all: [Swatch] = [
        ("White", "#FFFFFF"), ("Warm White", "#FFF1B9"), ("Light Orange", "#FFD7A6"),
        ("Amber", "#FFA900"), ("Orange", "#FF4900"), ("Red", "#FF0000"), ("Pink", "#FF00E5"),
        ("Purple", "#8000FF"), ("Dark Blue", "#1000FF"), ("Blue", "#0055FF"), ("Cyan", "#00FFFF"),
        ("Turquoise", "#00FFDD"), ("Green", "#00FF00"), ("Yellow", "#FFEE00"),
    ].map { Swatch(name: $0.0, color: LightColor(hex: $0.1)!) }
}

/// What a fixture's LEDs get for a colour.
public struct Emitters: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var white: Double
    public var amber: Double
    public var ultraviolet: Double

    /// RGB as given, plus the white LED at the colour's white content
    /// (the lowest of R, G and B). Adding white rather than taking it out of
    /// RGB keeps whites as bright as Lightkey's, which drove every emitter;
    /// saturated colours have no white content and come out as plain RGB.
    /// Amber and UV stay off: no look in the show calls for them, and mixing
    /// them in would shift every warm colour the operator picks.
    public static func mix(_ color: LightColor, hasWhite: Bool) -> Emitters {
        Emitters(
            red: color.red, green: color.green, blue: color.blue,
            white: hasWhite ? min(color.red, color.green, color.blue) : 0,
            amber: 0, ultraviolet: 0)
    }
}
