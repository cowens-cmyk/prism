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
}
