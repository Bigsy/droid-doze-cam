import Foundation

/// The control messages the pinned scrcpy server accepts while it captures a camera: torch and zoom steps.
/// Any other message type makes the server stop, so nothing else is ever sent.
public enum ScrcpyCameraControl {
    /// One zoom message moves the ratio by this factor, as CameraCapture.ZOOM_FACTOR in scrcpy 5.0.1.
    public static let zoomFactor: Float = 1 + 1 / 16
    public static let zoomIn = Data([19])
    public static let zoomOut = Data([20])
    public static func torch(_ on: Bool) -> Data { Data([18, on ? 1 : 0]) }

    /// The ratio the phone moves to for one zoom message. The server first aligns the current ratio to a
    /// whole power of the factor, then moves one power, so a step from an exact ratio such as 2 is uneven.
    public static func stepped(_ zoom: Float, zoomIn: Bool) -> Float {
        // floor(x + 0.5) is Java's Math.round, which the server uses.
        let power = (log(Double(zoom)) / log(Double(zoomFactor)) + 0.5).rounded(.down)
        return Float(pow(Double(zoomFactor), power + (zoomIn ? 1 : -1)))
    }

    public struct ZoomPlan: Equatable {
        public let zoomIn: Bool
        public let steps: Int
        /// The ratio the phone ends at. Zoom moves in steps of about 6%, so it can miss the target by about 3%.
        public let result: Float
    }

    /// The zoom messages that bring the phone nearest to `target`. The phone clamps to its own range,
    /// which is not known here; Settings only offers ratios inside it.
    public static func zoomPlan(from current: Float, to target: Double) -> ZoomPlan {
        guard current.isFinite, current > 0, target.isFinite, target > 0 else {
            return ZoomPlan(zoomIn: false, steps: 0, result: current)
        }
        func distance(_ zoom: Float) -> Double { abs(log(Double(zoom)) - log(target)) }
        let zoomIn = target > Double(current)
        var steps = 0, result = current
        // 0.1 to 100, the accepted range, is 114 steps.
        while steps < 128 {
            let next = stepped(result, zoomIn: zoomIn)
            guard next.isFinite, next > 0, distance(next) < distance(result) else { break }
            result = next; steps += 1
        }
        return ZoomPlan(zoomIn: zoomIn, steps: steps, result: result)
    }
}

/// Which phones capture without the control channel. A start with the channel open can give no video
/// once because the phone is restarting or leaving USB, as it does several times during a system update,
/// so a phone skips the channel only after it fails again with no start that streamed in between.
public struct ControlChannelHistory {
    public static let failuresBeforeSkipping = 2
    private var failures: [String: Int] = [:]
    public init() {}

    public func skips(_ serial: String) -> Bool { failures[serial, default: 0] >= Self.failuresBeforeSkipping }

    /// A start with the channel gave no video, then one without it streamed.
    /// True when this failure is the one that makes the phone skip the channel.
    public mutating func recordFailure(_ serial: String) -> Bool {
        failures[serial, default: 0] += 1
        return failures[serial] == Self.failuresBeforeSkipping
    }

    /// Video flowed with the channel open.
    public mutating func recordSuccess(_ serial: String) { failures[serial] = nil }
}
