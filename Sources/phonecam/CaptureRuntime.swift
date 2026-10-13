import Foundation
import CoreVideo
import PhoneCamCore
import PhoneCamMedia
import PhoneCamSyphon

struct RuntimeReport: Codable {
    let source: String
    let received: UInt64
    let processed: UInt64
    let queueDrops: UInt64
    let mailboxReplacements: UInt64
    let elapsedSeconds: Double
    let receivedFPS: Double
    let outputSize: String
    let requestedFPS: Int
    let metal: Bool
}
private final class Counters {
    private let lock = NSLock()
    private var received: UInt64 = 0, processed: UInt64 = 0, drops: UInt64 = 0
    func receive() { lock.lock(); received &+= 1; lock.unlock() }
    func output(_ success: Bool) { lock.lock(); if success { processed &+= 1 } else { drops &+= 1 }; lock.unlock() }
    func snapshot() -> (UInt64, UInt64, UInt64) { lock.lock(); defer { lock.unlock() }; return (received, processed, drops) }
}
private struct ArrivedFrame { let pixel: CVPixelBuffer; let time: Double }

final class TestCapture: CaptureSource {
    func run(configuration c: Configuration, cancellation: Cancellation, onFrame: @escaping (CVPixelBuffer) -> Void) throws {
        let renderer = try FrameRenderer(size: c.size)
        var frame: UInt64 = 0
        while !cancellation.isCancelled {
            let start = ProcessInfo.processInfo.systemUptime
            try autoreleasepool { onFrame(try renderer.testPattern(frame: frame)) }
            frame &+= 1
            cancellation.sleep(max(0, 1.0/Double(c.fps) - (ProcessInfo.processInfo.systemUptime - start)))
        }
    }
}

enum CaptureRuntime {
    /// Resolve ambiguity once. Reconnection must not silently switch to another person's phone.
    static func resolve(_ original: Configuration, cancellation: Cancellation) throws -> Configuration {
        var c = original
        if c.source == .test { return c }
        if c.serial != nil { c.source = .android }
        if c.source == .auto {
            let eligible = NativeDevices.all().filter { !NativeDevices.isOurs($0) && ($0.isContinuityCamera || NativeDevices.isUSB($0)) }
            if c.device != nil || !eligible.isEmpty { c.source = .auto }
            else { c.source = .android }
        }
        if c.source == .android {
            let tools = try AndroidTools(c)
            let selected = try ADBDevice.select(tools.devices(cancellation: cancellation), serial: c.serial)
            c.serial = selected.serial
            _ = try AndroidTools.serverPath(c)
            let version = try ProcessRunner.run(tools.adb, ["-s", selected.serial, "shell", "getprop", "ro.build.version.sdk"], cancellation: cancellation).text
            guard let sdk = Int(version), sdk >= 31 else { throw PhoneCamError.message("USB ADB camera mode requires Android 12+. Native USB Webcam mode is an independent option when supported by the phone.") }
        } else {
            try NativeDevices.requestPermission(cancellation: cancellation)
            let device = try NativeDevices.select(c); c.device = device.uniqueID
            // A probe may explicitly target the virtual camera without qualifying as a USB source.
            c.source = device.isContinuityCamera ? .continuity : (NativeDevices.isUSB(device) ? .uvc : .auto)
        }
        return c
    }
    static func run(_ original: Configuration, cancellation: Cancellation, onProcessedFrame: ((CVPixelBuffer) -> Void)? = nil) throws -> RuntimeReport {
        let c = try resolve(original, cancellation: cancellation)
        let instance = c.command == "run" ? try InstanceLock() : nil
        defer { withExtendedLifetime(instance) {} }
        let renderer = try FrameRenderer(size: c.size)
        let syphon: PCSyphonOutput?
        if c.syphon {
            let paths = c.syphonFrameworkPath.map { [($0 as NSString).expandingTildeInPath] } ?? [
                Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/Syphon.framework").path,
                "/Library/Frameworks/Syphon.framework",
                "/Applications/OBS.app/Contents/Frameworks/Syphon.framework"
            ]
            guard let path = paths.first(where:{ FileManager.default.fileExists(atPath:$0) }) else {
                throw PhoneCamError.message("Syphon.framework is unavailable. Install OBS or provide --syphon-framework with the official framework path.")
            }
            // Syphon discovery uses distributed notifications and needs the running main run loop.
            syphon = try DispatchQueue.main.sync { try PCSyphonOutput(frameworkPath:path,name:"PhoneCam") }
            log("Local Syphon output: PhoneCam. In OBS add a Syphon Client, then start OBS Virtual Camera.")
        } else { syphon = nil }
        let privacyFrame = syphon != nil ? try renderer.black() : nil
        let writer = c.command == "run" ? try VirtualCameraWriter(size: c.size, fps: c.fps) : nil
        let mailbox = LatestValue<ArrivedFrame>(), failure = LatestValue<String>(), counters = Counters()
        let settingsStore = CameraSettingsStore()
        var savedTransform = settingsStore.read()
        let backgroundBlur = BackgroundBlurProcessor()
        var lastSettingsRead = ProcessInfo.processInfo.systemUptime
        var reportedBlurDevice = false
        let queue = DispatchQueue(label: "PhoneCam.render", qos: .userInteractive, autoreleaseFrequency: .workItem)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let started = ProcessInfo.processInfo.systemUptime
        let duration = c.duration ?? (c.command == "probe" ? 10 : Double.greatestFiniteMagnitude)
        var lastReport = started, lastEnqueue = started, lastRenderError = 0.0, lastInput = started
        var sentPrivacyFrame = false
        timer.schedule(deadline: .now(), repeating: 1.0/Double(c.fps), leeway: .milliseconds(1))
        timer.setEventHandler {
            let now = ProcessInfo.processInfo.systemUptime
            if now - started >= duration { cancellation.cancel() }
            guard !cancellation.isCancelled else { return }
            if now - lastSettingsRead >= 0.5 {
                savedTransform = settingsStore.read()
                lastSettingsRead = now
            }
            if let item = mailbox.take() {
                lastInput = item.time; sentPrivacyFrame = false
                if now - item.time > 0.25 { counters.output(false) }
                else {
                    autoreleasepool {
                        do {
                            let converted = try renderer.convert(item.pixel,
                                rotation: c.rotationIsExplicit ? c.rotation : savedTransform.rotation,
                                mirror: c.mirrorIsExplicit ? c.mirror : savedTransform.mirror,
                                fit: c.fitIsExplicit ? c.fit : savedTransform.fit,
                                zoom: c.zoomIsExplicit ? c.zoom : savedTransform.zoom)
                            let pixel: CVPixelBuffer
                            if savedTransform.backgroundBlur {
                                if !reportedBlurDevice {
                                    log("Background blur segmentation: \(backgroundBlur.computeDeviceDescription); compositing: \(renderer.usesMetal ? "Metal" : "Core Image CPU")")
                                    reportedBlurDevice = true
                                }
                                pixel = try backgroundBlur.apply(to: converted, radius: savedTransform.blurRadius, renderer: renderer)
                            } else {
                                backgroundBlur.disable()
                                pixel = converted
                            }
                            try syphon?.publish(pixel)
                            let success = try writer?.send(pixel) ?? true
                            if success { onProcessedFrame?(pixel) }
                            counters.output(success)
                            if success { lastEnqueue = now }
                            else if now - lastEnqueue > 10 {
                                failure.put("Virtual camera sink stopped consuming frames. Restart PhoneCam and check extension status.")
                                cancellation.cancel()
                            }
                        } catch {
                            counters.output(false)
                            if now - lastRenderError > 5 { log("Dropping render frame: \(error.localizedDescription)"); lastRenderError = now }
                            if now - lastEnqueue > 10 { failure.put(error.localizedDescription); cancellation.cancel() }
                        }
                    }
                }
            } else if let syphon, let privacyFrame, now-lastInput > Constants.staleFrameSeconds, !sentPrivacyFrame {
                do { try syphon.publish(privacyFrame); sentPrivacyFrame = true }
                catch { failure.put(error.localizedDescription); cancellation.cancel() }
            }
            if now - lastReport >= 2 {
                let s = counters.snapshot()
                log(String(format: "received=%llu processed=%llu queueDrops=%llu replaced=%llu avgInput=%.1ffps", s.0,s.1,s.2,mailbox.overwritten,Double(s.0)/max(0.001,now-started)))
                if let syphon { log("Syphon client connected: \(syphon.hasClients)") }
                lastReport = now
            }
        }
        timer.resume()
        defer {
            timer.cancel()
            queue.sync {
                if let privacyFrame { try? syphon?.publish(privacyFrame) }
                syphon?.stop(); writer?.stop()
            }
            mailbox.clear()
        }
        let destination = c.command == "run" ? "Publishing to \(Constants.cameraName)" : (c.command == "preview" ? "Live preview window; not publishing a virtual camera" : "Probe only; not publishing")
        log("\(destination) — \(c.size), \(c.fps)fps, \(renderer.usesMetal ? "Metal" : "Core Image fallback"). Ctrl+C stops capture.")
        var backoff = RetryBackoff()
        while !cancellation.isCancelled {
            let before = counters.snapshot().0
            do {
                let source: CaptureSource
                switch c.source {
                case .android: source = AndroidCapture()
                case .test: source = TestCapture()
                default: source = NativeCapture()
                }
                try source.run(configuration: c, cancellation: cancellation) { pixel in
                    counters.receive(); mailbox.put(ArrivedFrame(pixel: pixel, time: ProcessInfo.processInfo.systemUptime))
                }
                if !cancellation.isCancelled { throw PhoneCamError.message("Camera source ended unexpectedly.") }
            } catch {
                mailbox.clear()
                if cancellation.isCancelled { break }
                let after = counters.snapshot().0
                // A bad initial configuration must fail, not enter an infinite retry loop.
                guard c.reconnect, after > 0 else { throw error }
                if after > before { backoff.reset() }
                let delay = backoff.next()
                log("\(error.localizedDescription) Retrying the SAME device after \(delay)s.")
                cancellation.sleep(delay)
            }
        }
        timer.cancel(); queue.sync {} // Finish any active callback before taking final statistics.
        if let error = failure.take() { throw PhoneCamError.message(error) }
        let s = counters.snapshot(), elapsed = max(0.001, ProcessInfo.processInfo.systemUptime-started)
        guard s.0 > 0, s.1 > 0 else { throw PhoneCamError.message("No frames were successfully processed. Run phonecam doctor and inspect the camera/server errors above.") }
        return RuntimeReport(source: c.source.rawValue, received:s.0, processed:s.1, queueDrops:s.2,
            mailboxReplacements:mailbox.overwritten, elapsedSeconds:elapsed, receivedFPS:Double(s.0)/elapsed,
            outputSize:c.size.description, requestedFPS:c.fps, metal:renderer.usesMetal)
    }
}
