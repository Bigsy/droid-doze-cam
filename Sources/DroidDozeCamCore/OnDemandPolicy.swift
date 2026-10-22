import Foundation

/// When `serve` starts and stops USB capture. It holds no ADB or CMIO state, so its rules are testable.
public struct OnDemandPolicy {
    public enum Action: Equatable {
        case start
        case stop(String)
        /// The session ended because the Mac app closed the camera.
        case sleepPhoneScreen
    }
    private enum StopReason { case cameraClosed, settingsChanged }
    public static let retryDelay = 2.0
    public private(set) var hasSession = false
    private var stopReason: StopReason?
    private var activeSettings: CameraCaptureSettings?
    private var activeFPS = 0
    private var nextAttempt = 0.0

    public init() {}

    /// `sessionFinished` reports that the current session's capture thread has exited. `requestedFPS` is the
    /// Mac app's frame rate, nil when unknown.
    public mutating func update(now: Double, wanted: Bool, desired: CameraCaptureSettings, requestedFPS: Double? = nil,
                                sessionFinished: Bool) -> [Action] {
        var actions: [Action] = []
        if hasSession && sessionFinished {
            if stopReason == .cameraClosed { actions.append(.sleepPhoneScreen) }
            // A session that ended without being stopped failed; give the phone a moment before retrying.
            else if stopReason == nil { nextAttempt = now + Self.retryDelay }
            hasSession = false; stopReason = nil; activeSettings = nil
        }
        if hasSession {
            if !wanted && stopReason != .cameraClosed {
                if stopReason == nil { actions.append(.stop("Mac camera closed; stopping USB capture.")) }
                stopReason = .cameraClosed
            } else if wanted && stopReason == nil && activeSettings != desired {
                stopReason = .settingsChanged
                actions.append(.stop("Capture settings changed; restarting the USB stream."))
            } else if wanted && stopReason == nil, let requestedFPS, desired.matching(requestedFPS: requestedFPS).fps > activeFPS {
                // A slower app needs no restart: the camera extension already drops the extra frames.
                stopReason = .settingsChanged
                actions.append(.stop("The Mac app asked for \(Int(requestedFPS.rounded())) fps; restarting the USB stream."))
            }
        } else if wanted && now >= nextAttempt {
            actions.append(.start)
        }
        return actions
    }

    /// `fps` is the rate the phone was asked for when it differs from the saved settings.
    public mutating func started(_ settings: CameraCaptureSettings, fps: Int? = nil) {
        hasSession = true; activeSettings = settings; activeFPS = fps ?? settings.fps
    }
    public mutating func startFailed(now: Double) { nextAttempt = now + Self.retryDelay }
}
