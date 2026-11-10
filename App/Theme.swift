import LightsCore
import SwiftUI

/// The look: a dark window lit by the cue that's in the room, with Liquid
/// Glass cards and controls floating over it.
enum Theme {
    static let accent = Color(red: 0.64, green: 0.42, blue: 1.0)
    static let live = Color(red: 0.2, green: 0.85, blue: 0.45)
    /// Dimmer-only lights show as warm white.
    static let tungsten = LightColor(hex: "#FFE2B0")!

    static func base(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0.11) : Color(white: 0.93)
    }
}

/// Dark grey, lit by a gradient of the colours on in the room right now,
/// each as strong as its lights are bright. It changes over the live cue's
/// fade time, so the window fades with the room.
struct AmbientBackground: View {
    var glows: [Glow]
    var fade: Double = 1.5
    @Environment(\.colorScheme) private var scheme

    /// The nine mesh points take the room's colours in turn; how much each
    /// tints the grey follows its level, more at the edges than the middle.
    /// Colourful glows first, so they take the strong corners. White
    /// light only lifts the grey a little: at full it would wash the window
    /// out and the text with it.
    private var ordered: [Glow] {
        glows.sorted { saturation($0.color) * $0.level > saturation($1.color) * $1.level }
    }

    private func saturation(_ c: LightColor) -> Double {
        let peak = max(c.red, c.green, c.blue)
        return peak > 0 ? (peak - min(c.red, c.green, c.blue)) / peak : 0
    }

    private func color(at index: Int, weight: Double) -> Color {
        let base = Theme.base(scheme)
        let glows = ordered
        guard !glows.isEmpty else { return base }
        let glow = glows[index % glows.count]
        let strength = (scheme == .dark ? 0.8 : 0.4) * (0.35 + 0.65 * glow.level) * (0.25 + 0.75 * saturation(glow.color))
        return base.mix(with: Color(glow.color), by: weight * strength)
    }

    var body: some View {
        MeshGradient(
            width: 3, height: 3,
            points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.55, 0.45], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1],
            ],
            colors: [
                color(at: 0, weight: 0.9), color(at: 1, weight: 0.55), color(at: 2, weight: 0.85),
                color(at: 3, weight: 0.5), color(at: 4, weight: 0.12), color(at: 5, weight: 0.5),
                color(at: 6, weight: 0.8), color(at: 7, weight: 0.45), color(at: 8, weight: 0.9),
            ])
            .animation(.easeInOut(duration: max(fade, 0.6)), value: glows)
            .ignoresSafeArea()
    }
}

/// A section of the editor: a Liquid Glass panel with a small heading.
struct GlassCard<Content: View>: View {
    var title: String?
    var systemImage: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                Label(title, systemImage: systemImage ?? "circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .labelStyle(.titleAndIcon)
            }
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }
}

/// A light as a glowing ball: brighter and with more glow the higher its level.
struct Orb: View {
    var color: LightColor
    var level: Double = 1
    var size: CGFloat = 28

    var body: some View {
        let c = Color(color)
        Circle()
            .fill(RadialGradient(
                colors: [c.mix(with: .white, by: 0.45), c, c.mix(with: .black, by: 0.25)],
                center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: size * 0.75))
            .overlay(Circle().strokeBorder(.white.opacity(0.28), lineWidth: 0.6))
            .opacity(level > 0 ? 1 : 0.3)
            .shadow(color: c.opacity(level > 0 ? 0.35 + 0.5 * level : 0), radius: size * (0.15 + 0.35 * level))
            .frame(width: size, height: size)
    }
}

/// The cue's colours side by side, blended.
struct ColorStrip: View {
    var colors: [LightColor]
    var height: CGFloat = 5

    var body: some View {
        Capsule()
            .fill(LinearGradient(
                colors: colors.isEmpty ? [Color.white.opacity(0.12)] : (colors.count == 1 ? [Color(colors[0]), Color(colors[0])] : colors.map(Color.init)),
                startPoint: .leading, endPoint: .trailing))
            .frame(height: height)
            .opacity(colors.isEmpty ? 1 : 0.9)
    }
}

/// A small glass capsule: LIVE, statuses.
struct GlassPill: View {
    var text: String
    var systemImage: String?
    var tint: Color?

    var body: some View {
        Label {
            Text(text)
        } icon: {
            if let systemImage { Image(systemName: systemImage) }
        }
        .font(.caption.weight(.bold))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .glassEffect(.regular.tint(tint?.opacity(0.55)), in: .capsule)
    }
}
