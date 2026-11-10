import Foundation

/// When the camera extension sends frames to Mac apps. It holds no CMIO state, so its rules are testable.
///
/// Producer frames go out on arrival; a timer of the extension's own would drift against the phone and
/// repeat or skip frames. Two frames are never closer than `minimumSpacing` of the app's frame period.
public struct FramePacer {
    public enum Action: Equatable {
        case emit
        /// Emit after this many seconds, unless a frame goes out first.
        case emitAfter(Double)
    }
    /// The share of the app's frame period that must pass between two frames.
    public static let minimumSpacing = 0.8
    private var lastEmit = 0.0
    private var waiting = false

    public init() {}

    /// A producer frame arrived. One that follows the previous frame too closely waits for the minimum
    /// spacing. Skipping it would leave a gap of two periods, because the next frame usually replaces it
    /// before the repeat timer is due. Returns nil while an earlier frame is already waiting; the newest
    /// frame goes out in its place.
    public mutating func frameArrived(now: Double, period: Double) -> Action? {
        let wait = lastEmit + period * Self.minimumSpacing - now
        if wait <= 0 { return .emit }
        if waiting { return nil }
        waiting = true
        return .emitAfter(wait)
    }

    /// The delay from `emitAfter` ended. False when a frame went out in the meantime.
    public mutating func delayEnded() -> Bool {
        defer { waiting = false }
        return waiting
    }

    /// The repeating timer fired. It repeats a frame once the producer has been quiet for longer than a
    /// frame, and sends black at the full rate when there is no producer frame.
    public func repeatDue(now: Double, period: Double, hasFrame: Bool) -> Bool {
        now - lastEmit >= period * (hasFrame ? 1.5 : Self.minimumSpacing)
    }

    public mutating func emitted(now: Double) { lastEmit = now; waiting = false }
}
