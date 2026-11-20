import Foundation

/// Keeps the songs' and the countdown's own colours in step with the plan
/// open in Screens. The live follower only sees a background once it's on
/// screen, so a song whose background was swapped in Screens went up in the
/// old background's colour and held it whenever the follower had nothing to
/// change it to (a dark background, Screens slow to answer). Every few
/// minutes this asks Screens which background each position starts on, and
/// when one has changed since it last looked, hands back the new picture and
/// colour for the cue to keep.
public struct ScreensBackgroundSync: Sendable {
    /// How often Prism asks: often enough that a background swapped during
    /// the week, or just before the service, is in the cue before it goes up.
    public static let interval: Double = 5 * 60

    public struct Update: Equatable, Sendable {
        public var position: String
        public var mediaID: String
        public var itemName: String?
        public var jpeg: Data
        /// The background's colour, or nil for a dark or black-and-white one,
        /// which leaves the cue's colour as it is (as the live follower does).
        public var color: LightColor?
    }

    public struct Result: Equatable, Sendable {
        public var planName: String?
        public var updates: [Update]
        /// Positions whose picture couldn't be fetched this time; they're
        /// asked for again next time.
        public var failed: [String]
    }

    public var plan: @Sendable () async -> Swift.Result<LightingBackgrounds, ScreensAPI.Failure>
    public var poster: @Sendable (String) async -> Swift.Result<Data, ScreensAPI.Failure>
    public var color: @Sendable (Data) -> LightColor?

    public init(api: ScreensAPI) {
        plan = { await api.lightingBackgrounds() }
        poster = { await api.poster(mediaID: $0) }
        color = { jpeg in
            guard case .success(let image) = ScreensAPI.image(from: jpeg) else { return nil }
            return ImagePalette.vividColors(in: image).first
        }
    }

    public init(
        plan: @escaping @Sendable () async -> Swift.Result<LightingBackgrounds, ScreensAPI.Failure>,
        poster: @escaping @Sendable (String) async -> Swift.Result<Data, ScreensAPI.Failure>,
        color: @escaping @Sendable (Data) -> LightColor?
    ) {
        self.plan = plan
        self.poster = poster
        self.color = color
    }

    /// The positions in `wanted` whose background isn't the one in `seen`
    /// (position → media id last applied). A position the plan doesn't have,
    /// or whose item has no background, is left alone: the cue keeps what it
    /// has rather than losing its colour to an empty slot.
    public func check(positions wanted: Set<String>, seen: [String: String]) async
        -> Swift.Result<Result, ScreensAPI.Failure>
    {
        let plan: LightingBackgrounds
        switch await self.plan() {
        case .success(let found): plan = found
        case .failure(let failure): return .failure(failure)
        }
        var updates: [Update] = []
        var failed: [String] = []
        var done = Set<String>()
        for entry in plan.positions where wanted.contains(entry.position) {
            guard done.insert(entry.position).inserted,
                  let media = entry.mediaId, !media.isEmpty, seen[entry.position] != media
            else { continue }
            switch await poster(media) {
            case .success(let jpeg):
                updates.append(Update(
                    position: entry.position, mediaID: media, itemName: entry.itemName,
                    jpeg: jpeg, color: color(jpeg)))
            case .failure:
                failed.append(entry.position)
            }
        }
        return .success(Result(planName: plan.serviceName, updates: updates, failed: failed))
    }
}
