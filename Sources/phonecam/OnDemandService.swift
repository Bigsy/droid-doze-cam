import Foundation
import PhoneCamCore

private final class CaptureSession {
    let cancellation = Cancellation()
    private let finished = DispatchGroup()

    init(configuration: Configuration) {
        finished.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { finished.leave() }
            do {
                let report = try CaptureRuntime.run(configuration, cancellation: cancellation)
                log(String(format: "USB capture stopped after %.1fs (%llu incoming frames).", report.elapsedSeconds, report.received))
            } catch {
                if !cancellation.isCancelled { log("USB capture failed: \(error.localizedDescription)") }
            }
        }
    }

    var isFinished: Bool { finished.wait(timeout: .now()) == .success }
    func stop() { cancellation.cancel() }
    func wait() { finished.wait() }
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

enum OnDemandService {
    static func run(_ original: Configuration, cancellation: Cancellation) throws {
        var capture = original
        capture.command = "run"
        capture.duration = nil

        let demand: () -> Bool
        if let path = original.demandDirectory {
            let file = CameraDemandFile(directory: URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true))
            demand = { file.current() }
        } else {
            demand = VirtualCameraWriter.demandActive
        }
        log("Waiting for a Mac app to use \(Constants.cameraName). The phone screen stays dark.")
        var session: CaptureSession?
        var activePhone: (adb: String, serial: String)?
        var stopping = false
        var nextAttempt = 0.0
        while !cancellation.isCancelled {
            let wanted = demand()
            if let running = session, running.isFinished {
                session = nil
                if stopping, let phone = activePhone { PhoneScreen.sleepIfLocked(adb: phone.adb, serial: phone.serial) }
                else { nextAttempt = ProcessInfo.processInfo.systemUptime + 2 }
                activePhone = nil
                stopping = false
            }
            if wanted {
                if session == nil && ProcessInfo.processInfo.systemUptime >= nextAttempt {
                    do {
                        let selected = try CaptureRuntime.resolve(capture, cancellation: cancellation)
                        guard let serial = selected.serial else { throw PhoneCamError.message("Choose an authorized USB Android phone.") }
                        let adb = try AndroidTools(selected).adb
                        log("Mac camera opened; starting USB capture from \(serial).")
                        activePhone = (adb, serial)
                        session = CaptureSession(configuration: selected)
                    } catch {
                        log("Waiting for USB phone: \(error.localizedDescription)")
                        nextAttempt = ProcessInfo.processInfo.systemUptime + 2
                    }
                }
            } else if let running = session, !stopping {
                log("Mac camera closed; stopping USB capture.")
                running.stop()
                stopping = true
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
