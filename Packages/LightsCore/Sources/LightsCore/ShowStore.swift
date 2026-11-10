import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The show on disk: ~/Library/Application Support/Hope Lights/Show.json,
/// with dropped pictures in Images/ beside it.
public struct ShowStore: Sendable {
    public var folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    public static var standard: ShowStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ShowStore(folder: support.appendingPathComponent("Hope Lights", isDirectory: true))
    }

    public var showURL: URL { folder.appendingPathComponent("Show.json") }
    public var imagesFolder: URL { folder.appendingPathComponent("Images", isDirectory: true) }

    /// The saved show, or the bundled one on a new install. A file that won't
    /// read is kept aside rather than overwritten, so nothing is lost.
    public func load() -> Show {
        guard let data = try? Data(contentsOf: showURL) else { return .bundledDefault() }
        if let show = try? JSONDecoder().decode(Show.self, from: data) { return show }
        let aside = folder.appendingPathComponent("Show-unreadable-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.moveItem(at: showURL, to: aside)
        return .bundledDefault()
    }

    public func save(_ show: Show) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(show).write(to: showURL, options: .atomic)
    }

    /// A small JPEG copy of a dropped picture (or a video's frame), so the
    /// cue keeps its thumbnail when the original moves. Returns the file name.
    public func storeImage(_ image: CGImage) throws -> String {
        let scale = min(1, 640 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw CocoaError(.fileWriteUnknown) }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let small = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: imagesFolder, withIntermediateDirectories: true)
        let name = UUID().uuidString + ".jpg"
        let target = imagesFolder.appendingPathComponent(name)
        guard let destination = CGImageDestinationCreateWithURL(target as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, small, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return name
    }

    public func imageURL(_ name: String) -> URL { imagesFolder.appendingPathComponent(name) }

    /// Deletes pictures no cue points at any more.
    public func removeUnusedImages(keeping show: Show) {
        let used = Set(show.cues.compactMap(\.image))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: imagesFolder.path)) ?? []
        for file in files where !used.contains(file) {
            try? FileManager.default.removeItem(at: imagesFolder.appendingPathComponent(file))
        }
    }
}

/// MIDI from Screens, decoded. Screens sends a note-on (velocity 127) for
/// each position; note-ons at velocity 0 are note-offs and mean nothing here.
public enum MIDINote {
    /// A MIDI 1.0 channel-voice word in a Universal MIDI Packet: message
    /// type 2, then group, status, note, velocity. Returns (channel 1–16, note).
    public static func noteOn(ump word: UInt32) -> (channel: Int, note: Int)? {
        guard word >> 28 == 0x2 else { return nil }
        let status = (word >> 16) & 0xFF
        let note = Int((word >> 8) & 0x7F)
        let velocity = word & 0x7F
        guard status & 0xF0 == 0x90, velocity > 0 else { return nil }
        return (Int(status & 0x0F) + 1, note)
    }
}
