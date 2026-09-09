import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import PhoneCamCore

protocol CaptureSource {
    func run(configuration: Configuration, cancellation: Cancellation, onFrame: @escaping (CVPixelBuffer) -> Void) throws
}

struct NativeDeviceInfo: Codable {
    let id: String
    let name: String
    let kind: String
    let transport: String
    let formats: [String]
}

enum NativeDevices {
    static func all() -> [AVCaptureDevice] {
        let types: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) { types = [.builtInWideAngleCamera,.external,.continuityCamera] }
        else { types = [.builtInWideAngleCamera,.externalUnknown] }
        return AVCaptureDevice.DiscoverySession(deviceTypes:types,mediaType:.video,position:.unspecified).devices
    }
    static func isUSB(_ d: AVCaptureDevice) -> Bool { UInt32(bitPattern:d.transportType) == 0x75736220 }
    static func isOurs(_ d: AVCaptureDevice) -> Bool { d.uniqueID.uppercased() == Constants.deviceUUID || d.localizedName == Constants.cameraName }
    static func infos() -> [NativeDeviceInfo] {
        all().map { d in
            let formats = Set(d.formats.map { f -> String in
                let dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
                let rate = f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
                return "\(dims.width)x\(dims.height) <=\(Int(rate))fps"
            }).sorted()
            return NativeDeviceInfo(id:d.uniqueID,name:d.localizedName,
                kind:isOurs(d) ? "phonecam" : d.isContinuityCamera ? "continuity" : isUSB(d) ? "uvc" : "other",
                transport:isUSB(d) ? "usb" : d.isContinuityCamera ? "managed-by-apple (USB/wireless not exposed reliably)" : "other",
                formats:formats)
        }
    }
    static func select(_ c: Configuration) throws -> AVCaptureDevice {
        var devices = all().filter { !isOurs($0) || (["probe", "preview"].contains(c.command) && c.device != nil) }
        if c.source == .continuity { devices = devices.filter(\.isContinuityCamera) }
        if c.source == .uvc { devices = devices.filter { isUSB($0) && !$0.isContinuityCamera } }
        if let key = c.device {
            let exact = devices.filter { $0.uniqueID == key }
            if exact.count == 1 { return exact[0] }
            let names = devices.filter { $0.localizedName.localizedCaseInsensitiveContains(key) }
            guard names.count == 1 else { throw PhoneCamError.message("Camera name '\(key)' is missing or ambiguous. Use an exact ID from phonecam devices.") }
            return names[0]
        }
        // Do not unexpectedly open a built-in camera or a different virtual camera.
        if c.source == .auto {
            let continuity = devices.filter(\.isContinuityCamera)
            devices = continuity.isEmpty ? devices.filter(isUSB) : continuity
        }
        guard devices.count == 1 else { throw PhoneCamError.message(devices.isEmpty ? "No eligible native phone camera is visible. Check Continuity Camera or USB Webcam mode." : "Several cameras match. Specify --device using phonecam devices.") }
        return devices[0]
    }
    static func requestPermission(cancellation: Cancellation) throws {
        switch AVCaptureDevice.authorizationStatus(for:.video) {
        case .authorized: return
        case .notDetermined:
            let semaphore = DispatchSemaphore(value:0), result = LatestValue<Bool>()
            DispatchQueue.main.async { AVCaptureDevice.requestAccess(for:.video) { allowed in result.put(allowed); semaphore.signal() } }
            let deadline = ProcessInfo.processInfo.systemUptime+120
            while semaphore.wait(timeout:.now()+0.1) != .success {
                if cancellation.isCancelled || ProcessInfo.processInfo.systemUptime > deadline { throw PhoneCamError.message("Camera permission request cancelled/timed out.") }
            }
            guard result.take() == true else { throw PhoneCamError.message("Camera permission denied. Enable PhoneCam (or its terminal) in System Settings > Privacy & Security > Camera.") }
        default: throw PhoneCamError.message("Camera access is denied/restricted. Enable it in System Settings > Privacy & Security > Camera.")
        }
    }
}

final class NativeCapture: NSObject, CaptureSource, AVCaptureVideoDataOutputSampleBufferDelegate {
    private var callback: ((CVPixelBuffer) -> Void)?
    private let queue = DispatchQueue(label:"dev.flyfish.phonecam.native",qos:.userInteractive)
    private let arrival = LatestValue<Double>()
    private let errorMessage = LatestValue<String>()
    func run(configuration c: Configuration, cancellation: Cancellation, onFrame: @escaping (CVPixelBuffer) -> Void) throws {
        try NativeDevices.requestPermission(cancellation:cancellation)
        let device = try NativeDevices.select(c)
        let input = try AVCaptureDeviceInput(device:device), output = AVCaptureVideoDataOutput(), session = AVCaptureSession()
        callback = onFrame
        session.beginConfiguration()
        // macOS selects the capture format through activeFormat below;
        // AVCaptureSession.Preset.inputPriority is unavailable on macOS.
        guard session.canAddInput(input), session.canAddOutput(output) else { session.commitConfiguration(); throw PhoneCamError.message("Camera cannot be added to capture session.") }
        session.addInput(input); session.addOutput(output)
        let candidates = device.formats.filter { f in f.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= Double(c.fps) && $0.maxFrameRate >= Double(c.fps) } }
        func score(_ f: AVCaptureDevice.Format) -> Double {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let aspect = abs(Double(d.width)/Double(d.height)-Double(c.size.width)/Double(c.size.height))
            return aspect*10_000 + abs(Double(d.width)-Double(c.size.width)) + abs(Double(d.height)-Double(c.size.height))
        }
        guard let format = candidates.min(by:{score($0)<score($1)}) else { session.commitConfiguration(); throw PhoneCamError.message("This camera does not advertise \(c.fps)fps. Try --fps 30 or 15.") }
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            device.activeVideoMinFrameDuration = CMTime(value:1,timescale:Int32(c.fps))
            device.activeVideoMaxFrameDuration = CMTime(value:1,timescale:Int32(c.fps))
            device.unlockForConfiguration()
        } catch { session.commitConfiguration(); throw error }
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self,queue:queue)
        if let connection = output.connection(with:.video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = false
        }
        session.commitConfiguration()
        let observer = NotificationCenter.default.addObserver(forName:.AVCaptureSessionRuntimeError,object:session,queue:nil) { [weak self] note in
            let message = (note.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "Capture session error."
            self?.errorMessage.put(message)
        }
        defer {
            session.stopRunning(); output.setSampleBufferDelegate(nil,queue:nil); queue.sync {}; callback = nil
            NotificationCenter.default.removeObserver(observer)
        }
        session.startRunning()
        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        log("Capturing \(device.localizedName), \(dims.width)x\(dims.height) @ \(c.fps)fps.")
        if device.isContinuityCamera { log("iPhone transport is controlled by macOS; this API cannot enforce or attest USB-only routing.") }
        var last = ProcessInfo.processInfo.systemUptime
        while !cancellation.isCancelled {
            if let message = errorMessage.take() { throw PhoneCamError.message(message) }
            if let t = arrival.take() { last = t }
            if !device.isConnected { throw PhoneCamError.message("Camera disconnected.") }
            if ProcessInfo.processInfo.systemUptime-last > 10 { throw PhoneCamError.message("No camera frames for 10 seconds; check phone lock, camera privacy, or another app using it.") }
            cancellation.sleep(0.1)
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        arrival.put(ProcessInfo.processInfo.systemUptime); callback?(pixel)
    }
}
