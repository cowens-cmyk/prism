import LightsCore
import SwiftUI
import UniformTypeIdentifiers

struct CueListView: View {
    @Bindable var model: AppModel
    /// The cue waiting for Delete to be confirmed. There's no undo.
    @State private var deleting: Cue?

    var body: some View {
        List(selection: $model.selectedCueID) {
            ForEach(model.show.cues) { cue in
                CueRow(model: model, cue: cue)
                    .tag(cue.id)
                    .contextMenu {
                        Button("Go") { model.go(cue) }
                        Button("Duplicate") { model.duplicate(cue.id) }
                        Divider()
                        Button("Delete…", role: .destructive) { deleting = cue }
                            .disabled(!model.canDelete(cue.id))
                    }
            }
            .onMove { model.move(from: $0, to: $1) }
        }
        .confirmationDialog(
            "Delete \(deleting?.displayName ?? "")?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { cue in
            Button("Delete", role: .destructive) { model.delete(cue.id) }
        } message: { cue in
            Text((cue.note.map { "Screens' note \($0) will no longer change the lights. " } ?? "") + "This can't be undone.")
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    model.addCue()
                } label: {
                    Label("Add Cue", systemImage: "plus")
                }
                .buttonStyle(.glass)
                Spacer()
            }
            .padding(12)
        }
    }
}

struct CueRow: View {
    var model: AppModel
    var cue: Cue
    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if isLive {
                        Circle()
                            .fill(Theme.live)
                            .frame(width: 7, height: 7)
                            .shadow(color: Theme.live, radius: 4)
                    }
                    Text(cue.displayName)
                        .font(.system(.body, design: .rounded).weight(isLive ? .bold : .medium))
                        .lineLimit(1)
                }
                ColorStrip(colors: cue.colors(in: model.rig), height: 4)
                    .frame(maxWidth: 120)
            }
            Spacer(minLength: 4)
            if let note = cue.note {
                Text("\(note)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .help("Screens sends note \(note) for this cue")
            }
            Button {
                model.go(cue)
            } label: {
                Image(systemName: "play.fill")
                    .font(.caption)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .tint(isLive ? Theme.live : nil)
            .help("Go to \(cue.name)")
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .listRowBackground(dropTargeted ? Theme.accent.opacity(0.3) : nil)
        .onDrop(of: PictureDrop.types, isTargeted: $dropTargeted) { providers in
            PictureDrop.load(providers) { url in
                await model.applyPicture(at: url, to: cue.id)
            }
        }
    }

    private var isLive: Bool { model.liveCueID == cue.id }
}

/// Pictures and videos dragged in from Finder, a browser or another app.
enum PictureDrop {
    static let types: [UTType] = [.fileURL, .image, .movie]

    /// Hands the dropped file to `use`. Data without a file (an image
    /// dragged out of a web page) is written to a temporary file first.
    static func load(_ providers: [NSItemProvider], use: @escaping @MainActor (URL) async -> Void) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in await use(url) }
            }
            return true
        }
        for type in [UTType.image, .movie] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else { return }
                // The provider deletes its file when this returns.
                let copy = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(url.pathExtension)
                guard (try? FileManager.default.copyItem(at: url, to: copy)) != nil else { return }
                Task { @MainActor in
                    await use(copy)
                    try? FileManager.default.removeItem(at: copy)
                }
            }
            return true
        }
        return false
    }
}

extension Cue {
    var displayName: String {
        name.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled cue" : name
    }
}

extension Color {
    init(_ color: LightColor) {
        self.init(.sRGB, red: color.red, green: color.green, blue: color.blue)
    }
}

extension LightColor {
    init?(_ color: Color) {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        self.init(red: Double(srgb.redComponent), green: Double(srgb.greenComponent), blue: Double(srgb.blueComponent))
    }
}
