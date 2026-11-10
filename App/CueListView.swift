import LightsCore
import SwiftUI
import UniformTypeIdentifiers

struct CueListView: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: $model.selectedCueID) {
            ForEach(model.show.cues) { cue in
                CueRow(model: model, cue: cue)
                    .tag(cue.id)
                    .contextMenu {
                        Button("Go") { model.go(cue) }
                        Button("Duplicate") { model.duplicate(cue) }
                        Divider()
                        Button("Delete", role: .destructive) { model.delete(cue) }
                            .disabled(model.liveCueID == cue.id)
                    }
            }
            .onMove { model.move(from: $0, to: $1) }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    model.addCue()
                } label: {
                    Label("Add Cue", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
            }
            .padding(10)
            .background(.bar)
        }
    }
}

struct CueRow: View {
    var model: AppModel
    var cue: Cue
    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(cue.name)
                    .font(.body.weight(isLive ? .semibold : .regular))
                HStack(spacing: 3) {
                    ForEach(model.rig.groups.filter(\.isSlimpar)) { group in
                        let look = cue.look(for: group)
                        Circle()
                            .fill(Color(look.color ?? .white).opacity(look.level > 0 ? 1 : 0.2))
                            .overlay(Circle().strokeBorder(.secondary.opacity(0.4), lineWidth: 0.5))
                            .frame(width: 9, height: 9)
                    }
                }
            }
            Spacer()
            if isLive {
                Text("LIVE")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.green))
                    .foregroundStyle(.white)
            }
            Button {
                model.go(cue)
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderless)
            .help("Go to \(cue.name)")
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .listRowBackground(dropTargeted ? Color.accentColor.opacity(0.25) : nil)
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
