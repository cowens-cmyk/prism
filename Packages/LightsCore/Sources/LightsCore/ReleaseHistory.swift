import Foundation

/// Prism's published releases, for going back to an earlier one when a new
/// release misbehaves (Prism › Install Previous Version…).
public enum ReleaseHistory {
    public struct Listing: Equatable, Sendable {
        public var tag: String
        public var draft: Bool
        public var prerelease: Bool
        public var hasDMG: Bool

        public init(tag: String, draft: Bool = false, prerelease: Bool = false, hasDMG: Bool = true) {
            self.tag = tag
            self.draft = draft
            self.prerelease = prerelease
            self.hasDMG = hasDMG
        }

        /// "v0.3.8" → "0.3.8".
        public var version: String {
            tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        }
    }

    /// The first release that updates itself. Anything older is on GitHub
    /// to install by hand, but isn't offered: once in, it could never come
    /// back to the newest with Check for Updates.
    public static let oldestInstallable = "0.3.0"

    /// The releases older than `current` that can be installed, newest
    /// first: published (not drafts or pre-releases), with a DMG, able to
    /// update themselves, each version once.
    public static func earlier(_ releases: [Listing], than current: String) -> [Listing] {
        var seen = Set<String>()
        return releases
            .filter { !$0.draft && !$0.prerelease && $0.hasDMG }
            .filter { $0.version.compare(current, options: .numeric) == .orderedAscending }
            .filter { $0.version.compare(oldestInstallable, options: .numeric) != .orderedAscending }
            .sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
            .filter { seen.insert($0.version).inserted }
    }
}
