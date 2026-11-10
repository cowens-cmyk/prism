import Foundation

/// 512 channels per universe.
public struct DMXFrame: Equatable, Sendable {
    public var universes: [Int: [UInt8]]

    public init(universes: [Int]) {
        self.universes = Dictionary(uniqueKeysWithValues: universes.map { ($0, [UInt8](repeating: 0, count: 512)) })
    }

    /// A 1-based channel's value; 0 for a universe the frame doesn't carry.
    public func value(universe: Int, address: Int) -> UInt8 {
        universes[universe]?[address - 1] ?? 0
    }

    /// A fixture's channels, in order.
    public func channels(of fixture: Fixture) -> [UInt8] {
        guard let slots = universes[fixture.universe] else { return [] }
        return Array(slots[(fixture.address - 1)..<fixture.lastAddress])
    }
}

public enum Renderer {
    /// What the rig outputs for a cue.
    public static func frame(for cue: Cue, rig: Rig) -> DMXFrame {
        var frame = DMXFrame(universes: rig.universes)
        for group in rig.groups {
            let look = cue.look(for: group)
            for name in group.fixtures {
                guard let fixture = rig.fixture(name) else { continue }
                let values = fixture.kind.channels(color: look.color ?? .white, level: look.level)
                frame.universes[fixture.universe]?.replaceSubrange(
                    (fixture.address - 1)..<fixture.lastAddress, with: values)
            }
        }
        return frame
    }
}

/// A fade between two frames, channel by channel, eased at both ends so a
/// long fade doesn't start or stop with a visible jump.
public struct Crossfade: Sendable {
    public var from: DMXFrame
    public var to: DMXFrame
    public var start: TimeInterval
    public var duration: TimeInterval

    public init(from: DMXFrame, to: DMXFrame, start: TimeInterval, duration: TimeInterval) {
        self.from = from
        self.to = to
        self.start = start
        self.duration = duration
    }

    public func progress(at time: TimeInterval) -> Double {
        guard duration > 0 else { return 1 }
        let p = min(max((time - start) / duration, 0), 1)
        return p * p * (3 - 2 * p)
    }

    public func isFinished(at time: TimeInterval) -> Bool { time >= start + duration }

    public func frame(at time: TimeInterval) -> DMXFrame {
        let p = progress(at: time)
        if p >= 1 { return to }
        var out = to
        for (universe, target) in to.universes {
            let source = from.universes[universe] ?? [UInt8](repeating: 0, count: 512)
            out.universes[universe] = zip(source, target).map { a, b in
                UInt8((Double(a) + (Double(b) - Double(a)) * p).rounded())
            }
        }
        return out
    }
}

/// Where frames go: sACN on the network, or a test's array.
public protocol FrameSink: AnyObject, Sendable {
    func send(_ frame: DMXFrame)
    /// Tells receivers this source is stopping, so another console can take
    /// over at once instead of after the timeout.
    func stop(universes: [Int])
}

/// Runs the lights: holds what's up, fades to the next cue and sends the
/// result 40 times a second (Lightkey's refresh rate). Off the main thread so
/// a busy UI never stutters a fade.
public final class LightEngine: @unchecked Sendable {
    public static let refreshRate: Double = 40
    /// How fast an edit to the live cue shows up in the room.
    public static let editFade: TimeInterval = 0.2

    public let rig: Rig
    private let sink: FrameSink
    private let clock: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "org.hopejc.lights.engine", qos: .userInteractive)
    private var timer: DispatchSourceTimer?

    private var fade: Crossfade
    private var outputEnabled = true
    private var _liveCueID: String?
    /// Nothing goes out until a cue is fired: opening the app shouldn't
    /// black out a room another console (or the nodes' own hold) is lighting.
    private var hasCue = false

    public init(
        rig: Rig, sink: FrameSink,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.rig = rig
        self.sink = sink
        self.clock = clock
        let dark = DMXFrame(universes: rig.universes)
        fade = Crossfade(from: dark, to: dark, start: 0, duration: 0)
    }

    public var liveCueID: String? {
        lock.withLock { _liveCueID }
    }

    /// What the lights are showing now, mid-fade included.
    public func currentFrame() -> DMXFrame {
        lock.withLock { fade.frame(at: clock()) }
    }

    /// Fades to a cue over its own fade time, or `fade` when given.
    public func go(_ cue: Cue, fade duration: TimeInterval? = nil) {
        let target = Renderer.frame(for: cue, rig: rig)
        lock.withLock {
            let now = clock()
            fade = Crossfade(from: fade.frame(at: now), to: target, start: now, duration: max(duration ?? cue.fade, 0))
            _liveCueID = cue.id
            hasCue = true
        }
    }

    /// An edit to a cue. Only the live cue reaches the lights.
    public func update(_ cue: Cue) {
        guard liveCueID == cue.id else { return }
        let target = Renderer.frame(for: cue, rig: rig)
        lock.withLock {
            let now = clock()
            // Mid-fade, keep the fade's end time so an edit doesn't cut a
            // five-second fade short; otherwise follow the edit quickly.
            let remaining = max(fade.start + fade.duration - now, Self.editFade)
            fade = Crossfade(from: fade.frame(at: now), to: target, start: now, duration: remaining)
        }
    }

    public func setOutputEnabled(_ enabled: Bool) {
        let wasEnabled = lock.withLock {
            let was = outputEnabled
            outputEnabled = enabled
            return was
        }
        if wasEnabled && !enabled && lock.withLock({ hasCue }) { sink.stop(universes: rig.universes) }
    }

    /// One tick of output; the timer calls this, tests call it directly.
    public func tick() {
        let (frame, sending) = lock.withLock { (fade.frame(at: clock()), outputEnabled && hasCue) }
        if sending { sink.send(frame) }
    }

    public func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1 / Self.refreshRate, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    public func shutdown() {
        timer?.cancel()
        timer = nil
        if lock.withLock({ outputEnabled && hasCue }) { sink.stop(universes: rig.universes) }
    }
}
