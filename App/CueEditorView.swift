import AppKit
import LightsCore
import SwiftUI

struct CueEditorView: View {
    var model: AppModel
    var cue: Cue

    var body: some View {
        ScrollView {
            GlassEffectContainer(spacing: 18) {
                VStack(spacing: 18) {
                    header
                    PictureCard(model: model, cue: cue)
                    ForEach(LightGroup.Section.allCases, id: \.self) { section in
                        GlassCard(title: section.rawValue, systemImage: section.symbol) {
                            VStack(spacing: 0) {
                                let groups = model.rig.groups.filter { $0.section == section }
                                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                                    if index > 0 { Divider().opacity(0.4) }
                                    GroupRow(model: model, cue: cue, group: group)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        // The window would otherwise open with the name selected for typing.
        // At launch the window isn't key yet, so this waits a moment.
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                for window in NSApp.windows where window.firstResponder is NSTextView { window.makeFirstResponder(nil) }
            }
        }
    }

    private var isLive: Bool { model.liveCueID == cue.id }

    private var header: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Name", text: Binding(
                            get: { model.cue(cue.id)?.name ?? cue.name },
                            set: { model.rename(cue.id, to: $0) }))
                        .textFieldStyle(.plain)
                        .labelsHidden()
                        .focusEffectDisabled()
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        ColorStrip(colors: cue.colors(in: model.rig), height: 6)
                            .frame(maxWidth: 260)
                    }
                    Spacer(minLength: 12)
                    if isLive {
                        GlassPill(text: "LIVE", systemImage: "dot.radiowaves.left.and.right", tint: Theme.live)
                    }
                    Button {
                        model.go(cue)
                    } label: {
                        Label("Go", systemImage: "play.fill")
                            .font(.title3.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(isLive ? Theme.live : Theme.accent)
                    .controlSize(.large)
                    .help("Fade to this cue (⌘↩)")
                }
                if !isLive {
                    // Otherwise moving a slider here and seeing nothing in the
                    // room looks like a fault.
                    Text("Not live. Changes show in the room after Go.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Divider().opacity(0.4)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 28) {
                        fade
                        Spacer(minLength: 0)
                        ScreensControl(model: model, cue: cue)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        fade
                        ScreensControl(model: model, cue: cue)
                    }
                }
            }
        }
    }

    private var fade: some View {
        HStack(spacing: 10) {
            Image(systemName: "timer")
                .foregroundStyle(.secondary)
            Text("Fade")
            Slider(value: binding(\.fade), in: 0...20, step: 0.5)
                .frame(width: 170)
            Text(cue.fade == 0 ? "Instant" : String(format: "%.1f s", cue.fade))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .leading)
        }
    }

    private func binding<Value>(_ path: WritableKeyPath<Cue, Value>) -> Binding<Value> {
        Binding {
            model.cue(cue.id)?[keyPath: path] ?? cue[keyPath: path]
        } set: { value in
            guard var current = model.cue(cue.id) else { return }
            current[keyPath: path] = value
            model.update(current)
        }
    }
}

extension LightGroup.Section {
    var symbol: String {
        switch self {
        case .slimpars: "light.recessed.3"
        case .stage: "theatermasks"
        case .house: "chandelier"
        }
    }
}

/// Which Screens position fires the cue, and the note it arrives as.
struct ScreensControl: View {
    var model: AppModel
    var cue: Cue

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.on.rectangle")
                .foregroundStyle(.secondary)
            if model.learningCueID == cue.id {
                Text("Waiting for a note: press Send on this cue's row in Screens.")
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                Button("Cancel") { model.learningCueID = nil }
                    .buttonStyle(.glass)
            } else {
                Text(description)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Button("Learn") { model.learningCueID = cue.id }
                    .buttonStyle(.glass)
                    .help("Set this cue's note from the next one Screens sends")
                if cue.note != nil {
                    Button("Clear") { model.clearNote(of: cue.id) }
                        .buttonStyle(.glass)
                }
            }
        }
    }

    private var description: String {
        guard let note = cue.note else { return "Screens: only by hand" }
        let position = cue.screensPosition.map(ScreensPositions.title) ?? "note"
        return "Screens: \(position), note \(note)"
    }
}

struct PictureCard: View {
    var model: AppModel
    var cue: Cue
    @State private var targeted = false

    var body: some View {
        GlassCard(title: "Match a slide", systemImage: "photo.on.rectangle.angled") {
            HStack(alignment: .center, spacing: 18) {
                dropZone
                VStack(alignment: .leading, spacing: 12) {
                    if let palette = cue.palette, !palette.isEmpty {
                        Text("Colours in the picture. Click one to put it on the SlimPARs.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            ForEach(Array(palette.enumerated()), id: \.offset) { _, color in
                                Button {
                                    model.setSlimparColor(color, in: cue.id)
                                } label: {
                                    Orb(color: color, size: 32)
                                }
                                .buttonStyle(.plain)
                                .help(color.hex)
                            }
                        }
                    } else {
                        Text("Drop a worship background or sermon slide, a picture or a video, and the SlimPARs take its colour.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Button("Choose…") { choose() }
                            .buttonStyle(.glass)
                        if cue.image != nil {
                            Button("Remove") { model.clearPicture(of: cue.id) }
                                .buttonStyle(.glass)
                        }
                    }
                    if let message = model.pictureMessage, message.cueID == cue.id {
                        Text(message.text)
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .onDrop(of: PictureDrop.types, isTargeted: $targeted) { providers in
            PictureDrop.load(providers) { url in await model.applyPicture(at: url, to: cue.id) }
        }
    }

    private var dropZone: some View {
        let shape = RoundedRectangle(cornerRadius: 16)
        return ZStack {
            if let name = cue.image, let image = model.thumbnail(name) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(shape)
            } else {
                shape.fill(.white.opacity(0.04))
                VStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down.on.square")
                        .font(.title)
                    Text("Drop here")
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(.secondary)
            }
            shape.strokeBorder(
                targeted
                    ? AnyShapeStyle(LinearGradient(colors: [Theme.accent, .pink, .orange], startPoint: .topLeading, endPoint: .bottomTrailing))
                    : AnyShapeStyle(Color.white.opacity(cue.image == nil ? 0.22 : 0.12)),
                style: StrokeStyle(lineWidth: targeted ? 2.5 : 1.2, dash: cue.image == nil && !targeted ? [6, 5] : []))
        }
        .frame(width: 208, height: 117)
        .scaleEffect(targeted ? 1.03 : 1)
        .animation(.spring(duration: 0.25), value: targeted)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.applyPicture(at: url, to: cue.id) }
    }
}

struct GroupRow: View {
    var model: AppModel
    var cue: Cue
    var group: LightGroup

    var body: some View {
        let look = cue.look(for: group)
        let shown = look.color ?? Theme.tungsten
        HStack(spacing: 14) {
            if group.hasColor {
                ColorButton(
                    color: shown, level: look.level,
                    showsAllSlimpars: group.isSlimpar,
                    set: { color in set { $0.color = color } },
                    setAllSlimpars: { color in model.setSlimparColor(color, in: cue.id) })
            } else {
                Orb(color: Theme.tungsten, level: look.level, size: 30)
                    .frame(width: 34)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .fixedSize()
                Text(subtitle(look))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Image(systemName: "sun.min")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Slider(value: Binding(
                get: { model.cue(cue.id).map { $0.look(for: group).level } ?? look.level },
                set: { level in set { $0.level = (level * 100).rounded() / 100 } }),
                in: 0...1)
                .tint(Color(shown))
                .frame(minWidth: 140, maxWidth: 240)
            Image(systemName: "sun.max.fill")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text("\(Int((look.level * 100).rounded()))%")
                .font(.body.monospacedDigit().weight(.medium))
                .foregroundStyle(look.level > 0 ? .primary : .secondary)
                .frame(width: 46, alignment: .trailing)
        }
        .padding(.vertical, 10)
    }

    private func subtitle(_ look: GroupLook) -> String {
        let count = group.fixtures.filter { $0 != "FX1" }.count
        let lights = count == 1 ? "1 light" : "\(count) lights"
        guard let color = look.color else { return lights }
        return "\(lights) · \(Swatch.all.first { $0.color == color }?.name ?? color.hex)"
    }

    private func set(_ change: (inout GroupLook) -> Void) {
        guard var current = model.cue(cue.id) else { return }
        var look = current.look(for: self.group)
        change(&look)
        current.set(look, for: self.group)
        model.update(current)
    }
}
