import Foundation
import DroidDozeCamCore

private final class CaptureSession {
    let cancellation = Cancellation()
    private let stopRequest = Cancellation()
    private let finished = DispatchGroup()
    /// Why the session ended when serve did not stop it. Read only once isFinished is true.
    private(set) var failure: String?

    init(configuration: Configuration, onEvent: @escaping (CaptureEvent) -> Void) {
        finished.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { finished.leave() }
            do {
                let report = try CaptureRuntime.run(resolved: configuration, cancellation: cancellation, onEvent: onEvent)
                log(String(format: "USB capture stopped after %.1fs (%llu incoming frames).", report.elapsedSeconds, report.received))
            } catch {
                // The runtime also cancels itself when it gives up, for example on a stalled camera sink,
                // so only a stop that serve asked for is quiet.
                if !stopRequest.isCancelled {
                    failure = error.localizedDescription
                    log("USB capture failed: \(error.localizedDescription)")
                }
            }
        }
    }

    var isFinished: Bool { finished.wait(timeout: .now()) == .success }
    func stop() { stopRequest.cancel(); cancellation.cancel() }
    func wait() { finished.wait() }
}

/// Publishes what serve is doing for the menu bar app, skipping repeats.
private final class StatusReporter: @unchecked Sendable {
    private let file = ServiceStatusFile(directory: supportDirectory)
    private let lock = NSLock()
    private var last: ServiceStatus?

    func set(_ state: ServiceStatus.State, _ detail: String = "") {
        let status = ServiceStatus(state: state, detail: detail)
        lock.lock(); defer { lock.unlock() }
        guard status != last else { return }
        last = status
        do { try file.publish(status) } catch { log("Could not publish the service status: \(error.localizedDescription)") }
    }

    func clear() { file.remove() }
}

private enum PhoneScreen {
    /// Leave an unlocked phone alone. A lit lock screen can safely go dark again.
    static func sleepIfLocked(adb: String, serial: String) {
        let prefix = ["-s", serial, "shell"]
        guard let power = try? ProcessRunner.run(adb, prefix + ["dumpsys", "power"], timeout: 3).text,
              power.contains("mWakefulness=Awake"),
              let window = try? ProcessRunner.run(adb, prefix + ["dumpsys", "window"], timeout: 3).text,
              window.contains("mDreamingLockscreen=true") else { return }
        do {
            _ = try ProcessRunner.run(adb, prefix + ["input", "keyevent", "KEYCODE_SLEEP"], timeout: 3)
            log("Phone lock screen turned off after camera use.")
        } catch { log("Could not turn off phone lock screen: \(error.localizedDescription)") }
    }
}

/// A process's CMIO device list can miss a camera extension that was activated or replaced after the
/// process first used CMIO, so serve would never see a Mac app open the camera; a new process sees it.
/// Under the login service, serve exits while idle and launchd's KeepAlive starts a fresh one.
private struct CameraListRefresh {
    private static let database = "/Library/SystemExtensions/db.plist"
    private static let missingLimit = 30.0
    /// A camera still missing after a restart is not fixed by more restarts, so space them out.
    private static let missingRestartInterval = 600.0
    private static let lastMissingRestartKey = "service.lastMissingCameraRestart"
    private let enabled = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == "com.hedworth.droiddozecam.service"
    private let stamp = Self.modified()
    private var nextCheck = 0.0
    private var missingSince: Double?

    private static func modified() -> Date? {
        try? FileManager.default.attributesOfItem(atPath: database)[.modificationDate] as? Date
    }

    /// Restarting cannot help while the extension awaits approval or is not installed.
    private static func extensionEnabled() -> Bool {
        guard let host = Bundle.main.bundleIdentifier, let data = FileManager.default.contents(atPath: database),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let extensions = plist["extensions"] as? [[String: Any]] else { return false }
        return extensions.contains { $0["identifier"] as? String == "\(host).camera" && $0["state"] as? String == "activated_enabled" }
    }

    mutating func restartReason(now: Double) -> String? {
        guard enabled, now >= nextCheck else { return nil }
        nextCheck = now + 2
        if Self.modified() != stamp { return "System extensions changed." }
        if (try? VirtualCameraWriter.findDevice()) != nil || !Self.extensionEnabled() { missingSince = nil; return nil }
        let since = missingSince ?? now
        missingSince = since
        guard now - since >= Self.missingLimit else { return nil }
        let wallClock = Date().timeIntervalSince1970
        let sinceLastRestart = wallClock - UserDefaults.standard.double(forKey: Self.lastMissingRestartKey)
        guard sinceLastRestart < 0 || sinceLastRestart >= Self.missingRestartInterval else { return nil }
        UserDefaults.standard.set(wallClock, forKey: Self.lastMissingRestartKey)
        return "The \(Constants.cameraName) camera has not been visible for \(Int(now - since))s."
    }
}

enum OnDemandService {
    private static let logPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/DroidDozeCam.log").path

    static func run(_ original: Configuration, cancellation: Cancellation) throws {
        var capture = original
        capture.command = "run"
        capture.duration = nil
        let settingsStore = CameraSettingsStore()
        var desiredCapture = capture.applyingSavedCapture(settingsStore.readCapture(for: original.serial))
        var nextSettingsRead = ProcessInfo.processInfo.systemUptime + 0.5

        let demand: () -> Bool?
        let requestedFrameRate: () -> Double?
        if let path = original.demandDirectory {
            let file = CameraDemandFile(directory: URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true))
            demand = { file.current() }
            requestedFrameRate = { nil }
        } else {
            demand = VirtualCameraWriter.demand
            requestedFrameRate = VirtualCameraWriter.requestedFrameRate
        }
        var refresh = original.demandDirectory == nil ? CameraListRefresh() : nil
        let status = StatusReporter()
        defer { status.clear() }
        log("Waiting for a Mac app to use \(Constants.cameraName). The phone screen stays dark.")
        var policy = OnDemandPolicy()
        var session: CaptureSession?
        var activePhone: (adb: String, serial: String)?
        var lastWait: String?
        var nextLogCheck = 0.0
        var cameraVisible: Bool?
        while !cancellation.isCancelled {
            let now = ProcessInfo.processInfo.systemUptime
            if now >= nextSettingsRead {
                desiredCapture = capture.applyingSavedCapture(settingsStore.readCapture(for: original.serial))
                nextSettingsRead = now + 0.5
            }
            let reading = demand()
            if cameraVisible != (reading != nil) {
                if reading == nil {
                    log("The \(Constants.cameraName) camera is not visible. Check Settings → Setup or run droiddozecam status and droiddozecam install-extension.")
                } else if cameraVisible != nil {
                    log("The \(Constants.cameraName) camera is visible again.")
                }
                cameraVisible = reading != nil
            }
            let wanted = reading == true
            let requestedFPS = wanted ? requestedFrameRate() : nil
            var finished: CaptureSession?
            if let running = session, running.isFinished { finished = running; session = nil }
            if wanted, let failure = finished?.failure { status.set(.problem, failure) }
            for action in policy.update(now: now, wanted: wanted, desired: desiredCapture.captureSettings,
                                        requestedFPS: requestedFPS, sessionFinished: finished != nil) {
                switch action {
                case .stop(let reason):
                    log(reason)
                    session?.stop()
                case .sleepPhoneScreen:
                    if let phone = activePhone { PhoneScreen.sleepIfLocked(adb: phone.adb, serial: phone.serial) }
                case .start:
                    do {
                        var matched = desiredCapture
                        matched.fps = desiredCapture.captureSettings.matching(requestedFPS: requestedFPS).fps
                        let selected = try CaptureRuntime.resolve(matched, cancellation: cancellation)
                        let phone: String
                        if selected.source == .test {
                            phone = "Test pattern"
                            activePhone = nil
                            log("Mac camera opened; starting the test pattern.")
                        } else {
                            guard let serial = selected.serial else { throw DroidDozeCamError.message("Choose an authorized USB Android phone.") }
                            let tools = try AndroidTools(selected)
                            phone = (try? tools.devices(cancellation: cancellation).first { $0.serial == serial }?.model) ?? serial
                            let rate = matched.fps == desiredCapture.fps ? "" : " at \(matched.fps) fps to match the app"
                            log("Mac camera opened; starting USB capture from \(serial)\(rate).")
                            activePhone = (tools.adb, serial)
                        }
                        status.set(.starting, phone)
                        lastWait = nil
                        policy.started(desiredCapture.captureSettings, fps: matched.fps)
                        session = CaptureSession(configuration: selected) { event in
                            switch event {
                            case .receiving: status.set(.streaming, phone)
                            case .reconnecting(let reason): status.set(.reconnecting, reason)
                            }
                        }
                    } catch {
                        // Repeats every two seconds while an app waits for an unplugged phone.
                        if error.localizedDescription != lastWait { log("Waiting for USB phone: \(error.localizedDescription)") }
                        lastWait = error.localizedDescription
                        status.set(.problem, error.localizedDescription)
                        policy.startFailed(now: ProcessInfo.processInfo.systemUptime)
                    }
                }
            }
            if !policy.hasSession {
                activePhone = nil
                if !wanted {
                    if reading == nil { status.set(.problem, "Camera extension not visible. Check Settings → Setup.") }
                    else { status.set(.idle) }
                    lastWait = nil
                }
                if let reason = refresh?.restartReason(now: ProcessInfo.processInfo.systemUptime) {
                    log("\(reason) Restarting so the camera list is current.")
                    return
                }
                if now >= nextLogCheck {
                    nextLogCheck = now + 600
                    if LogRotation.rotateIfNeeded(path: logPath, limit: 5_000_000) {
                        log("Started a new log; the previous one is DroidDozeCam.log.1.")
                    }
                }
            }
            cancellation.sleep(0.2)
        }
        if let session {
            session.stop()
            session.wait()
            if let phone = activePhone { PhoneScreen.sleepIfLocked(adb: phone.adb, serial: phone.serial) }
        }
    }
}
