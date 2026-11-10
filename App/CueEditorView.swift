import AppKit
import LightsCore
import SwiftUI

struct CueEditorView: View {
    var model: AppModel
    var cue: Cue

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            Divider()
            form
        }
        // The window would otherwise open with the name selected for typing.
        .onAppear { DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) } }
    }

    private var form: some View {
        Form {
            Section {
                fadeRow
                ScreensRow(model: model, cue: cue)
            }
            Section("Picture") {
                PictureRow(model: model, cue: cue)
            }
            ForEach(LightGroup.Section.allCases, id: \.self) { section in
                Section(section.rawValue) {
                    ForEach(model.rig.groups.filter { $0.section == section }) { group in
                        GroupRow(model: model, cue: cue, group: group)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var isLive: Bool { model.liveCueID == cue.id }

    private var header: some View {
        HStack(spacing: 12) {
            TextField("Name", text: binding(\.name) { cue, name in
                // A custom cue's Screens position is its name, so the row in
                // Screens' cue table matches.
                if cue.screensPosition?.hasPrefix("custom:") == true { cue.screensPosition = "custom:\(name)" }
            })
            .textFieldStyle(.plain)
            .labelsHidden()
            .focusEffectDisabled()
            .font(.title.weight(.semibold))
            Spacer()
            if isLive {
                Label("Live", systemImage: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.green)
                    .font(.headline)
            }
            Button {
                model.go(cue)
            } label: {
                Label("Go", systemImage: "play.fill")
                    .frame(minWidth: 70)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Fade to this cue (⌘↩)")
        }
    }

    private var fadeRow: some View {
        LabeledContent("Fade") {
            HStack {
                Slider(value: binding(\.fade), in: 0...20, step: 0.5)
                    .frame(maxWidth: 280)
                Text(cue.fade == 0 ? "Instant" : String(format: "%.1f s", cue.fade))
                    .monospacedDigit()
                    .frame(width: 60, alignment: .trailing)
            }
        }
    }

    private func binding<Value>(
        _ path: WritableKeyPath<Cue, Value>, also: ((inout Cue, Value) -> Void)? = nil
    ) -> Binding<Value> {
        Binding {
            model.cue(cue.id)?[keyPath: path] ?? cue[keyPath: path]
        } set: { value in
            guard var current = model.cue(cue.id) else { return }
            current[keyPath: path] = value
            also?(&current, value)
            model.update(current)
        }
    }
}

/// Which Screens position fires the cue, and the note it arrives as.
struct ScreensRow: View {
    var model: AppModel
    var cue: Cue

    var body: some View {
        LabeledContent("Screens") {
            HStack(spacing: 10) {
                if model.learningCueID == cue.id {
                    Text("Waiting for a note. In Screens, press Send on this cue's row (Settings › Lightkey & MIDI).")
                        .foregroundStyle(.orange)
                    Button("Cancel") { model.learningCueID = nil }
                } else {
                    Text(description)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Button("Learn") { model.learningCueID = cue.id }
                        .help("Set this cue's note from the next one Screens sends")
                    if cue.note != nil {
                        Button("Clear") {
                            var c = cue
                            c.note = nil
                            model.update(c)
                        }
                    }
                }
            }
        }
    }

    private var description: String {
        guard let note = cue.note else { return "Only by hand" }
        let position = cue.screensPosition.map(ScreensPositions.title) ?? "note"
        return "\(position), note \(note)"
    }
}

struct PictureRow: View {
    var model: AppModel
    var cue: Cue
    @State private var targeted = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: cue.image == nil ? [5] : []))
                    .foregroundStyle(targeted ? Color.accentColor : .secondary.opacity(0.5))
                if let name = cue.image, let image = NSImage(contentsOf: model.store.imageURL(name)) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.title2)
                        Text("Drop a slide or background")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .frame(width: 192, height: 108)
            .onDrop(of: PictureDrop.types, isTargeted: $targeted) { providers in
                PictureDrop.load(providers) { url in await model.applyPicture(at: url, to: cue.id) }
            }

            VStack(alignment: .leading, spacing: 8) {
                if let palette = cue.palette, !palette.isEmpty {
                    Text("Colours in the picture. Click one to put it on the SlimPARs.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        ForEach(palette, id: \.self) { color in
                            Button {
                                if let current = model.cue(cue.id) { model.setSlimparColor(color, in: current) }
                            } label: {
                                SwatchDot(color: color, size: 28)
                            }
                            .buttonStyle(.plain)
                            .help(color.hex)
                        }
                    }
                } else {
                    Text("Drop a worship background or sermon slide here, a picture or a video, and the SlimPARs take its colour.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Choose…") { choose() }
                    if cue.image != nil {
                        Button("Remove") { model.clearPicture(of: cue) }
                    }
                }
            }
        }
        .padding(.vertical, 4)
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
        LabeledContent {
            HStack(spacing: 12) {
                if group.hasColor {
                    ColorButton(
                        color: look.color ?? .white,
                        showsAllSlimpars: group.isSlimpar,
                        set: { color in set { $0.color = color } },
                        setAllSlimpars: { color in
                            if let current = model.cue(cue.id) { model.setSlimparColor(color, in: current) }
                        })
                }
                Slider(value: Binding(
                    get: { model.cue(cue.id).map { $0.look(for: group).level } ?? look.level },
                    set: { level in set { $0.level = (level * 100).rounded() / 100 } }),
                    in: 0...1)
                Text("\(Int((look.level * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
            .frame(maxWidth: 420)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(group.name)
                Text(group.fixtures.count == 1 ? "1 light" : "\(group.fixtures.filter { $0 != "FX1" }.count) lights")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func set(_ change: (inout GroupLook) -> Void) {
        guard var current = model.cue(cue.id) else { return }
        var look = current.look(for: self.group)
        change(&look)
        current.set(look, for: self.group)
        model.update(current)
    }
}
