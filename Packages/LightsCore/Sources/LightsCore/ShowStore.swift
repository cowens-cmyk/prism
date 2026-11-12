import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The show on disk: ~/Library/Application Support/Prism/Show.json,
/// with dropped pictures in Images/ beside it, and a copy of the show the
/// operator can see, back up and carry to another Mac: Prism Show.json on
/// the Desktop, written with every save.
public struct ShowStore: Sendable {
    public var folder: URL
    /// The copy on the Desktop; nil keeps the show in `folder` only (tests).
    public var showFile: URL?

    public static let showFileName = "Prism Show.json"

    public init(folder: URL, showFile: URL? = nil) {
        self.folder = folder
        self.showFile = showFile
    }

    public static var standard: ShowStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        return ShowStore(
            folder: support.appendingPathComponent("Prism", isDirectory: true),
            showFile: desktop?.appendingPathComponent(showFileName))
    }

    public var showURL: URL { folder.appendingPathComponent("Show.json") }
    /// The show as it was when the app last opened: one step back if a
    /// session's edits go wrong.
    public var previousURL: URL { folder.appendingPathComponent("Show-previous.json") }
    public var imagesFolder: URL { folder.appendingPathComponent("Images", isDirectory: true) }

    /// The saved show, or the bundled one on a new install. A file that won't
    /// read is kept aside rather than overwritten, so nothing is lost.
    public func load() -> Show {
        guard let data = try? Data(contentsOf: showURL) else {
            // Nothing saved on this Mac (a new one, or Prism reinstalled):
            // the show file on the Desktop is the show, when it reads.
            if let showFile, let copy = try? Data(contentsOf: showFile),
               let show = try? JSONDecoder().decode(Show.self, from: copy), !show.cues.isEmpty {
                return show.repaired()
            }
            return .bundledDefault()
        }
        if let show = try? JSONDecoder().decode(Show.self, from: data), !show.cues.isEmpty {
            // Only a file that reads becomes the backup; a bad one copied
            // over it would lose the last good show.
            try? FileManager.default.removeItem(at: previousURL)
            try? FileManager.default.copyItem(at: showURL, to: previousURL)
            return show.repaired()
        }
        let aside = folder.appendingPathComponent("Show-unreadable-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.moveItem(at: showURL, to: aside)
        return .bundledDefault()
    }

    /// Saves the show, and the copy on the Desktop. Returns whether the
    /// Desktop copy was written: the show itself is safe either way, so a
    /// Desktop that can't be written (macOS hasn't been allowed to) is
    /// reported, not thrown.
    @discardableResult
    public func save(_ show: Show) throws -> Bool {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(show)
        try data.write(to: showURL, options: .atomic)
        guard let showFile else { return true }
        return (try? data.write(to: showFile, options: .atomic)) != nil
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

    /// Deletes pictures no cue points at any more, in this show or in the
    /// backup and set-aside copies beside it, so restoring one of those
    /// brings its pictures back too.
    public func removeUnusedImages(keeping show: Show) {
        let used = Set(show.cues.compactMap(\.image))
        let others = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasPrefix("Show-") && $0.hasSuffix(".json") }
            .compactMap { try? String(contentsOf: folder.appendingPathComponent($0), encoding: .utf8) }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: imagesFolder.path)) ?? []
        for file in files where !used.contains(file) && !others.contains(where: { $0.contains(file) }) {
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

    /// Words in a UMP message, from its type (the first word's top nibble).
    static func messageSize(_ word: UInt32) -> Int {
        switch word >> 28 {
        case 0x0, 0x1, 0x2, 0x6, 0x7: 1
        case 0x3, 0x4, 0x8, 0x9, 0xA: 2
        case 0xB, 0xC: 3
        default: 4 // 0x5, 0xD, 0xE, 0xF
        }
    }

    /// The note-ons in a packet's words, reading message by message so a
    /// data word inside a longer message is never taken for a note.
    public static func noteOns(in words: UnsafeBufferPointer<UInt32>) -> [(channel: Int, note: Int)] {
        var result: [(channel: Int, note: Int)] = []
        var i = 0
        while i < words.count {
            if let n = noteOn(ump: words[i]) { result.append(n) }
            i += messageSize(words[i])
        }
        return result
    }

    /// Whether a note's channel is one this app listens on (nil: any).
    public static func accepts(channel: Int, listeningOn wanted: Int?) -> Bool {
        wanted == nil || wanted == channel
    }
}
