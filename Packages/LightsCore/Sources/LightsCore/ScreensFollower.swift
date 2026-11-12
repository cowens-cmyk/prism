import Foundation

/// Keeps a matching cue's SlimPARs on Screens' background for as long as the
/// cue is live. It reads what Screens has live (a small status read, under a
/// second apart) and asks for the background again only when the slide or
/// its media changes. Asking once when the note arrived was unreliable: the
/// note can come before Screens shows the new slide, and a song can change
/// backgrounds part way through.
public struct ScreensFollower: Sendable {
    public enum Event: Equatable, Sendable {
        /// The background's colour, or nil for a dark or black-and-white
        /// one, which leaves the cue's own colour up.
        case color(LightColor?)
        case problem(String?)
    }

    public var signature: @Sendable () async -> Result<String, ScreensAPI.Failure>
    public var background: @Sendable () async -> Result<Data, ScreensAPI.Failure>
    public var pause: @Sendable (Double) async -> Void
    /// The background's colour from its JPEG.
    public var color: @Sendable (Data) -> LightColor?
    /// How long the slide that was up before the note gets to give way.
    public var staleGrace: Double = 2

    public init(api: ScreensAPI) {
        signature = { await api.liveSignature() }
        background = { await api.backgroundJPEG() }
        pause = { try? await Task.sleep(for: .seconds($0)) }
        color = { jpeg in
            guard case .success(let image) = ScreensAPI.image(from: jpeg) else { return nil }
            return ImagePalette.vividColors(in: image).first
        }
    }

    public init(
        signature: @escaping @Sendable () async -> Result<String, ScreensAPI.Failure>,
        background: @escaping @Sendable () async -> Result<Data, ScreensAPI.Failure>,
        pause: @escaping @Sendable (Double) async -> Void,
        color: @escaping @Sendable (Data) -> LightColor?
    ) {
        self.signature = signature
        self.background = background
        self.pause = pause
        self.color = color
    }

    /// Runs until the task is cancelled or `stillLive` says the cue has
    /// gone. `stale` is what was live when the previous cue stopped
    /// following; `followed` hears each signature taken, so the next cue
    /// knows it. Returns the last signature followed.
    @discardableResult
    public func run(
        stale: String?,
        stillLive: @escaping @MainActor () -> Bool,
        followed: @escaping @MainActor (String) -> Void,
        send: @escaping @MainActor (Event) -> Void
    ) async -> String? {
        var current: String?
        var lastJPEG: Data?
        var lastColor: LightColor??
        var elapsed = 0.0
        while !Task.isCancelled, await stillLive() {
            var problem: String?
            switch await signature() {
            case .success(let live):
                let waiting = live == stale && elapsed < staleGrace
                if live != current, !waiting {
                    switch await background() {
                    case .success(let jpeg):
                        current = live
                        await followed(live)
                        if jpeg != lastJPEG {
                            lastJPEG = jpeg
                            let found = color(jpeg)
                            if lastColor == nil || lastColor! != found {
                                lastColor = .some(found)
                                guard !Task.isCancelled, await stillLive() else { return current }
                                await send(.color(found))
                            }
                        }
                    case .failure(.noBackground):
                        // A slide without a background leaves the colour as it is.
                        current = live
                        await followed(live)
                    case .failure(let failure):
                        problem = failure.message
                    }
                }
            case .failure(let failure):
                problem = failure.message
            }
            guard !Task.isCancelled, await stillLive() else { return current }
            await send(.problem(problem))
            // A wrong key or address won't fix itself in a second.
            let wait = problem != nil ? 3 : (current == nil ? 0.2 : 0.75)
            await pause(wait)
            elapsed += wait
        }
        return current
    }

    /// While a cue that doesn't match is live, only notes what Screens has
    /// live, so the next matching cue knows which slide was already up when
    /// its note came: the walk-in slide before the countdown, or the last
    /// announcement before a song. Nothing is fetched or coloured.
    public func watch(
        stillLive: @escaping @MainActor () -> Bool,
        followed: @escaping @MainActor (String) -> Void
    ) async {
        while !Task.isCancelled, await stillLive() {
            var wait = 3.0
            if case .success(let live) = await signature() {
                guard !Task.isCancelled, await stillLive() else { return }
                await followed(live)
                wait = 0.75
            }
            await pause(wait)
        }
    }

    /// What an edit to the live cue does to following Screens' background.
    public enum Change: Equatable, Sendable {
        case none
        /// Stop following and go back to the cue's own colour.
        case stop
        /// Start following now, without waiting for the next Go.
        case start
    }

    /// Turning the switch on or off on the live cue takes effect at once,
    /// and picking a SlimPAR colour by hand wins over the matched one.
    /// `following` says whether the live cue is following Screens now.
    public static func change(editing before: Cue, to after: Cue, rig: Rig, following: Bool) -> Change {
        if before.followsScreensBackground != after.followsScreensBackground {
            if after.followsScreensBackground { return .start }
            return following ? .stop : .none
        }
        guard following else { return .none }
        let slimpars = rig.groups.filter(\.isSlimpar)
        return slimpars.contains { after.look(for: $0).color != before.look(for: $0).color } ? .stop : .none
    }

    /// A SlimPAR colour picked by hand on a cue that matches Screens is the
    /// operator's choice for that cue: matching is switched off on it, so
    /// the colour is still there the next time the cue goes up (the 9:30
    /// service, next Sunday) instead of going back to Screens' background.
    /// The cue's Match Screens' background switch turns it on again.
    public static func keepingHandColours(from before: Show, to after: Show, rig: Rig) -> Show {
        var show = after
        let slimpars = rig.groups.filter(\.isSlimpar)
        for index in show.cues.indices {
            let cue = show.cues[index]
            guard cue.followsScreensBackground, let earlier = before.cue(cue.id), earlier.followsScreensBackground,
                  slimpars.contains(where: { cue.look(for: $0).color != earlier.look(for: $0).color })
            else { continue }
            show.cues[index].matchesScreens = false
        }
        return show
    }

    /// Going to the cue that's already live and following keeps the follower
    /// and its colour: starting over would put the cue's own colour up and
    /// wait out the slide that's still on screen, a visible swing mid-song.
    public static func keepsFollowing(firing cueID: String, liveCueID: String?, followingCueID: String?) -> Bool {
        followingCueID != nil && cueID == liveCueID && cueID == followingCueID
    }
}
