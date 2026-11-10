import LightsCore
import SwiftUI

/// A swatch that opens the colour picker: the church's colours, a hex box,
/// and the system picker for anything else.
struct ColorButton: View {
    var color: LightColor
    var level: Double = 1
    var showsAllSlimpars: Bool
    var set: (LightColor) -> Void
    var setAllSlimpars: (LightColor) -> Void
    @State private var open = false

    var body: some View {
        Button {
            open = true
        } label: {
            Orb(color: color, level: level, size: 30)
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Colour: \(Swatch.all.first { $0.color == color }?.name ?? color.hex)")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ColorPanel(color: color, showsAllSlimpars: showsAllSlimpars, set: set, setAllSlimpars: setAllSlimpars)
        }
        #if DEBUG
        // Screenshots of the picker without clicking: HL_OPEN_COLOR=1.
        .task {
            if showsAllSlimpars, ProcessInfo.processInfo.environment["HL_OPEN_COLOR"] != nil, !Self.openedForDebug {
                Self.openedForDebug = true
                try? await Task.sleep(for: .seconds(1))
                open = true
            }
        }
        #endif
    }

    #if DEBUG
    @MainActor static var openedForDebug = false
    #endif
}

struct ColorPanel: View {
    var color: LightColor
    var showsAllSlimpars: Bool
    var set: (LightColor) -> Void
    var setAllSlimpars: (LightColor) -> Void
    @State private var hex = ""
    @State private var picked = Color.white
    @FocusState private var hexFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 8), count: 7), spacing: 8) {
                ForEach(Swatch.all) { swatch in
                    Button {
                        choose(swatch.color)
                    } label: {
                        Orb(color: swatch.color, size: 28)
                            .overlay(Circle().strokeBorder(.white, lineWidth: swatch.color == color ? 2.5 : 0).padding(-4))
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .help(swatch.name)
                }
            }
            HStack {
                Text("Hex")
                TextField("#FF00E5", text: $hex)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .frame(width: 100)
                    .focused($hexFocused)
                    .onSubmit(applyHex)
                    .onChange(of: hex) { _, text in
                        // Live as soon as it's a full colour, so typing a
                        // value shows it in the room without pressing Return.
                        let digits = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
                        if digits.count == 6 { applyHex() }
                    }
                if LightColor(hex: hex) == nil, !hex.isEmpty {
                    Text("Six digits, like #FF00E5")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                ColorPicker("More", selection: $picked, supportsOpacity: false)
                    .onChange(of: picked) { _, new in
                        // Compared as hex: the trip through NSColor can move a channel by
                        // a hair, which isn't a change anyone made.
                        if let rgb = LightColor(new), rgb.hex != color.hex { choose(rgb) }
                    }
            }
            if showsAllSlimpars {
                Button {
                    setAllSlimpars(color)
                } label: {
                    Label("Use on all SlimPARs", systemImage: "light.recessed.3")
                }
                .buttonStyle(.glass)
            }
        }
        .padding(18)
        .frame(width: 340)
        .onAppear {
            hex = color.hex
            picked = Color(color)
        }
    }

    private func choose(_ new: LightColor) {
        set(new)
        if !hexFocused { hex = new.hex }
    }

    private func applyHex() {
        // By hex: opening the picker sets the box to the current colour, and
        // that mustn't count as an edit when the colour isn't exact 8-bit.
        guard let parsed = LightColor(hex: hex), parsed.hex != color.hex else { return }
        set(parsed)
    }
}
