import Foundation

public enum DroidDozeCamError: Error, LocalizedError, Equatable {
    case message(String)
    public var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

public enum Constants {
    public static let version = "0.1.0"
    public static let cameraName = "DroidDozeCam"
    // Stable across restarts and updates; meeting applications persist these identifiers.
    public static let deviceUUID = "6BC32819-3803-4B4E-8B86-094FCBA5CF70"
    public static let sourceUUID = "4DBF4485-A15D-40B5-B334-EA95CB93663D"
    public static let sinkUUID = "96F9168F-72BD-4A90-91BA-3C4C398629AC"
    public static let scrcpyVersion = "5.0.1"
    public static let scrcpySHA256 = "764eb6f79811d5211fe9df341120882ba9994c7a61b897d7bf3fb662e53bc536"
    public static let maxPacketBytes = 16 * 1024 * 1024
    public static let staleFrameSeconds = 1.5
    // Custom device property ("1" while a Mac app streams the camera). It travels over CoreMediaIO
    // because the extension runs as _cmiodalassistants, so its App Group container is not the user's.
    public static let demandPropertyCode = "wdmd"
    public static let demandPropertyName = "4cc_wdmd_glob_0000"
}

public struct VideoSize: Equatable, Codable, CustomStringConvertible, Sendable {
    public let width: Int
    public let height: Int
    public var description: String { "\(width)x\(height)" }
    public init(width: Int, height: Int) { self.width = width; self.height = height }
    public init(_ text: String) throws {
        let parts = text.lowercased().split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]),
              (16...4096).contains(w), (16...4096).contains(h), w % 2 == 0, h % 2 == 0 else {
            throw DroidDozeCamError.message("Invalid size '\(text)'; use even dimensions such as 1280x720 (16…4096).")
        }
        width = w; height = h
    }
    public static let hd = VideoSize(width: 1280, height: 720)
    public static let fullHD = VideoSize(width: 1920, height: 1080)
    public static let qhd = VideoSize(width: 2560, height: 1440)
    public static let ultraHD = VideoSize(width: 3840, height: 2160)
    public static let vga = VideoSize(width: 640, height: 480)
    // Both the source and sink publish this exact order. Append new formats so existing indices stay stable.
    public static let supported: [VideoSize] = [.hd, .fullHD, .vga, .ultraHD, .qhd]
}

public enum InputSource: String, CaseIterable, Sendable { case auto, continuity, uvc, android, test }
public enum FitMode: String, Sendable { case fit, fill }

public struct CameraTransform: Equatable, Sendable {
    /// Gaussian sigma in output pixels. The Metal blur works at quarter size, so 8 is still sigma 2 there.
    public static let blurRadii = 8...64
    public let rotation: Int
    public let mirror: Bool
    public let fit: FitMode
    public let zoom: Double
    public let backgroundBlur: Bool
    public let blurRadius: Int
    public init(rotation: Int, mirror: Bool, fit: FitMode = .fit, zoom: Double = 1,
                backgroundBlur: Bool = false, blurRadius: Int = 24) {
        self.rotation = rotation
        self.mirror = mirror
        self.fit = fit
        self.zoom = zoom
        self.backgroundBlur = backgroundBlur
        self.blurRadius = blurRadius
    }
}

public struct CameraCaptureSettings: Equatable, Sendable {
    public let size: VideoSize
    public let fps: Int
    public let bitrate: Int
    public let facing: String
    public let cameraID: String?
    public let cameraSize: VideoSize?
    public let cameraZoom: Double
    public let cameraTorch: Bool
    public let videoEncoder: String?

    public init(size: VideoSize, fps: Int, bitrate: Int, facing: String, cameraID: String? = nil,
                cameraSize: VideoSize? = nil, cameraZoom: Double = 1, cameraTorch: Bool = false, videoEncoder: String? = nil) {
        self.cameraSize = cameraSize; self.cameraZoom = cameraZoom; self.cameraTorch = cameraTorch; self.videoEncoder = videoEncoder
        self.size = size; self.fps = fps; self.bitrate = bitrate; self.facing = facing; self.cameraID = cameraID
    }

    public static let standard = CameraCaptureSettings(size: .fullHD, fps: 60, bitrate: 20_000_000, facing: "back")
    public static let frameRates = [15, 24, 25, 30, 60, 120]
    /// What to ask the phone for while a Mac app takes `requestedFPS`. The camera extension drops frames that
    /// arrive faster than the app's rate, so a call app at 30 fps gains nothing from 60. Only 30 is chosen
    /// automatically as a conservative default; a faster or unknown request keeps the saved rate.
    public func matching(requestedFPS: Double?) -> CameraCaptureSettings {
        guard let requestedFPS, requestedFPS > 0, requestedFPS <= 30.05, fps > 30 else { return self }
        return CameraCaptureSettings(size: size, fps: 30, bitrate: bitrate, facing: facing, cameraID: cameraID,
            cameraSize: cameraSize, cameraZoom: cameraZoom, cameraTorch: cameraTorch, videoEncoder: videoEncoder)
    }
    public static func validEncoder(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 256 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
        }
    }
    public var isSupported: Bool {
        let validCameraID = cameraID.map { id in
            !id.isEmpty && id.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
            }
        } ?? true
        return VideoSize.supported.contains(size) && Self.frameRates.contains(fps) &&
        !(size == .ultraHD && fps > 60) && (1_000...100_000_000).contains(bitrate) &&
        ["front", "back", "external"].contains(facing) && validCameraID &&
        cameraZoom.isFinite && (0.1...100).contains(cameraZoom) &&
        (cameraSize.map { (try? VideoSize($0.description)) != nil } ?? true) &&
        (videoEncoder.map(Self.validEncoder) ?? true)
    }
}

/// Shared by the menu bar app and capture processes running from the same app bundle.
public final class CameraSettingsStore {
    private let defaults: UserDefaults
    private let rotationKey = "camera.rotation"
    private let mirrorKey = "camera.mirror"
    private let fitKey = "camera.fit"
    private let zoomKey = "camera.zoom"
    private let backgroundBlurKey = "camera.backgroundBlur"
    private let blurRadiusKey = "camera.blurRadius"
    private let sizeKey = "camera.captureSize"
    private let fpsKey = "camera.captureFPS"
    private let bitrateKey = "camera.captureBitrate"
    private let facingKey = "camera.facing"
    private let cameraSelectionsKey = "camera.selectionsBySerial"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func read() -> CameraTransform {
        defaults.synchronize() // See changes written by the separate login service or menu process.
        let savedRotation = defaults.object(forKey: rotationKey) as? Int ?? 0
        let savedZoom = defaults.object(forKey: zoomKey) as? Double ?? 1
        let savedBlurRadius = defaults.object(forKey: blurRadiusKey) as? Int ?? 24
        return CameraTransform(rotation: [0, 90, 180, 270].contains(savedRotation) ? savedRotation : 0,
                               mirror: defaults.bool(forKey: mirrorKey),
                               fit: FitMode(rawValue: defaults.string(forKey: fitKey) ?? "") ?? .fit,
                               zoom: savedZoom.isFinite && (1...4).contains(savedZoom) ? savedZoom : 1,
                               backgroundBlur: defaults.bool(forKey: backgroundBlurKey),
                               blurRadius: CameraTransform.blurRadii.contains(savedBlurRadius) ? savedBlurRadius : 24)
    }

    public func write(_ transform: CameraTransform) {
        precondition([0, 90, 180, 270].contains(transform.rotation))
        precondition(transform.zoom.isFinite && (1...4).contains(transform.zoom))
        precondition(CameraTransform.blurRadii.contains(transform.blurRadius))
        defaults.set(transform.rotation, forKey: rotationKey)
        defaults.set(transform.mirror, forKey: mirrorKey)
        defaults.set(transform.fit.rawValue, forKey: fitKey)
        defaults.set(transform.zoom, forKey: zoomKey)
        defaults.set(transform.backgroundBlur, forKey: backgroundBlurKey)
        defaults.set(transform.blurRadius, forKey: blurRadiusKey)
        defaults.synchronize()
    }

    public func readCapture(for serial: String? = nil) -> CameraCaptureSettings {
        defaults.synchronize()
        let size = (try? VideoSize(defaults.string(forKey: sizeKey) ?? ""))
        let selections = defaults.dictionary(forKey: cameraSelectionsKey) as? [String: [String: String]] ?? [:]
        let selection = serial.flatMap { selections[$0] }
        let saved = CameraCaptureSettings(
            size: size ?? .fullHD,
            fps: defaults.object(forKey: fpsKey) as? Int ?? 60,
            bitrate: defaults.object(forKey: bitrateKey) as? Int ?? 20_000_000,
            facing: selection?["facing"] ?? (serial == nil ? defaults.string(forKey: facingKey) ?? "back" : "back"),
            cameraID: selection?["id"],
            cameraSize: selection?["size"].flatMap { try? VideoSize($0) },
            cameraZoom: selection?["zoom"].flatMap(Double.init) ?? 1,
            cameraTorch: selection?["torch"] == "true",
            videoEncoder: selection?["encoder"])
        return saved.isSupported ? saved : .standard
    }

    public func writeCapture(_ settings: CameraCaptureSettings, for serial: String? = nil) {
        precondition(settings.isSupported)
        precondition(settings.cameraID == nil || serial != nil)
        defaults.set(settings.size.description, forKey: sizeKey)
        defaults.set(settings.fps, forKey: fpsKey)
        defaults.set(settings.bitrate, forKey: bitrateKey)
        if let serial {
            var selections = defaults.dictionary(forKey: cameraSelectionsKey) as? [String: [String: String]] ?? [:]
            var selection = ["facing": settings.facing]
            selection["id"] = settings.cameraID
            selection["size"] = settings.cameraSize?.description
            selection["zoom"] = String(settings.cameraZoom)
            selection["torch"] = String(settings.cameraTorch)
            selection["encoder"] = settings.videoEncoder
            selections[serial] = selection
            defaults.set(selections, forKey: cameraSelectionsKey)
        } else { defaults.set(settings.facing, forKey: facingKey) }
        defaults.synchronize()
    }
}

public struct Configuration: Equatable, Sendable {
    public var command = "help"
    public var source: InputSource = .auto
    public var device: String?
    public var serial: String?
    public var size = VideoSize.hd
    public var sizeIsExplicit = false
    public var fps = 30
    public var fpsIsExplicit = false
    public var bitrate = 8_000_000
    public var bitrateIsExplicit = false
    public var facing = "back"
    public var facingIsExplicit = false
    public var cameraID: String?
    public var androidSize: VideoSize?
    public var androidSizeIsExplicit = false
    public var cameraZoom = 1.0
    public var cameraZoomIsExplicit = false
    public var cameraTorch = false
    public var cameraTorchIsExplicit = false
    public var videoEncoder: String?
    public var videoEncoderIsExplicit = false
    public var rotation = 0
    public var mirror = false
    public var zoom = 1.0
    public var rotationIsExplicit = false
    public var mirrorIsExplicit = false
    public var zoomIsExplicit = false
    public var fit: FitMode = .fit
    public var fitIsExplicit = false
    public var reconnect = true
    public var json = false
    public var duration: Double?
    public var adbPath: String?
    public var serverPath: String?
    public var requireHardware = false
    public var syphon = false
    public var syphonFrameworkPath: String?
    public var demandDirectory: String?

    public init() {}

    public var captureSettings: CameraCaptureSettings {
        CameraCaptureSettings(size: size, fps: fps, bitrate: bitrate, facing: facing, cameraID: cameraID,
            cameraSize: androidSize, cameraZoom: cameraZoom, cameraTorch: cameraTorch, videoEncoder: videoEncoder)
    }

    public func applyingSavedCapture(_ saved: CameraCaptureSettings) -> Self {
        var result = self
        if !sizeIsExplicit { result.size = saved.size }
        if !fpsIsExplicit { result.fps = saved.fps }
        if !bitrateIsExplicit { result.bitrate = saved.bitrate }
        if !facingIsExplicit && cameraID == nil {
            result.facing = saved.facing
            result.cameraID = saved.cameraID
        }
        if let cameraID, cameraID == saved.cameraID { result.facing = saved.facing }
        if source != .test {
            let sameCamera = result.cameraID == saved.cameraID && result.facing == saved.facing
            if sameCamera && !androidSizeIsExplicit { result.androidSize = saved.cameraSize }
            if sameCamera && !cameraZoomIsExplicit { result.cameraZoom = saved.cameraZoom }
            if sameCamera && !cameraTorchIsExplicit { result.cameraTorch = saved.cameraTorch }
            if !videoEncoderIsExplicit { result.videoEncoder = saved.videoEncoder }
        }
        if result.size == .ultraHD && result.fps > 60 {
            if !fpsIsExplicit { result.fps = 60 }
            else if !sizeIsExplicit { result.size = .fullHD }
        }
        return result
    }

    public static func parse(_ arguments: [String]) throws -> Self {
        var c = Configuration()
        var args = arguments
        if args.first == "--help" || args.first == "-h" { return c }
        if args.first == "--version" { c.command = "version"; return c }
        guard let command = args.first else { return c }
        let commands = ["help", "version", "menu", "devices", "cameras", "doctor", "run", "probe", "preview", "serve", "install-extension", "uninstall-extension", "status"]
        guard commands.contains(command) else { throw DroidDozeCamError.message("Unknown command '\(command)'. Run droiddozecam help.") }
        c.command = args.removeFirst()
        var supplied = Set<String>()
        while !args.isEmpty {
            let raw = args.removeFirst()
            if raw == "--help" || raw == "-h" { c.command = "help"; return c }
            let split = raw.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(split[0])
            guard !supplied.contains(key) else { throw DroidDozeCamError.message("Duplicate option \(key).") }
            supplied.insert(key)
            let flags = ["--mirror", "--no-mirror", "--no-reconnect", "--json", "--require-hardware", "--syphon", "--camera-torch", "--no-camera-torch"]
            var value = ""
            if flags.contains(key) {
                guard split.count == 1 else { throw DroidDozeCamError.message("\(key) does not take a value.") }
            } else if split.count == 2 { value = String(split[1]) }
            else {
                guard let next = args.first, !next.hasPrefix("--") else { throw DroidDozeCamError.message("Missing value for \(key).") }
                value = args.removeFirst()
            }
            switch key {
            case "--source":
                guard let s = InputSource(rawValue: value) else { throw DroidDozeCamError.message("Source must be auto, continuity, uvc, android, or test.") }; c.source = s
            case "--device": c.device = value
            case "--serial":
                // Passed as an argv element, never interpreted by a local shell.
                guard !value.isEmpty, !value.contains("\n") else { throw DroidDozeCamError.message("Invalid USB serial.") }; c.serial = value
            case "--size":
                c.size = try VideoSize(value)
                guard VideoSize.supported.contains(c.size) else { throw DroidDozeCamError.message("Virtual camera sizes: 640x480, 1280x720, 1920x1080, 2560x1440, 3840x2160.") }
                c.sizeIsExplicit = true
            case "--fps":
                guard let n = Int(value), CameraCaptureSettings.frameRates.contains(n) else { throw DroidDozeCamError.message("FPS must be 15, 24, 25, 30, 60, or 120.") }; c.fps = n; c.fpsIsExplicit = true
            case "--bitrate":
                let s = value.lowercased(); let factor = s.hasSuffix("m") ? 1_000_000 : s.hasSuffix("k") ? 1_000 : 1
                let digits = factor == 1 ? s : String(s.dropLast())
                guard let n = Int(digits), n > 0, n <= 100_000_000 / factor else { throw DroidDozeCamError.message("Bitrate must be 1K…100M, e.g. 8M.") }
                c.bitrate = n * factor
                guard c.bitrate >= 1000 else { throw DroidDozeCamError.message("Bitrate must be at least 1000 bits/s.") }
                c.bitrateIsExplicit = true
            case "--facing":
                guard ["front", "back", "external"].contains(value) else { throw DroidDozeCamError.message("Facing must be front, back, or external.") }; c.facing = value; c.facingIsExplicit = true
            case "--camera-id":
                guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46,95].contains($0) }) else { throw DroidDozeCamError.message("Invalid Android camera ID.") }; c.cameraID = value
            case "--android-size":
                c.androidSize = value == "auto" ? nil : try VideoSize(value); c.androidSizeIsExplicit = true
            case "--camera-zoom":
                guard let zoom = Double(value), zoom.isFinite, (0.1...100).contains(zoom) else {
                    throw DroidDozeCamError.message("Camera zoom must be between 0.1 and 100; the phone clamps it to its supported range.")
                }
                c.cameraZoom = zoom; c.cameraZoomIsExplicit = true
            case "--camera-torch": c.cameraTorch = true; c.cameraTorchIsExplicit = true
            case "--no-camera-torch": c.cameraTorch = false; c.cameraTorchIsExplicit = true
            case "--video-encoder":
                guard value == "auto" || CameraCaptureSettings.validEncoder(value) else { throw DroidDozeCamError.message("Invalid H.264 encoder name.") }
                c.videoEncoder = value == "auto" ? nil : value; c.videoEncoderIsExplicit = true
            case "--rotate":
                guard let n = Int(value), [0,90,180,270].contains(n) else { throw DroidDozeCamError.message("Rotation must be 0, 90, 180, or 270 clockwise.") }; c.rotation = n; c.rotationIsExplicit = true
            case "--zoom":
                guard let n = Double(value), n.isFinite, (1...4).contains(n) else { throw DroidDozeCamError.message("Zoom must be between 1 and 4.") }; c.zoom = n; c.zoomIsExplicit = true
            case "--fit":
                guard let fit = FitMode(rawValue: value) else { throw DroidDozeCamError.message("Fit mode must be fit or fill.") }; c.fit = fit; c.fitIsExplicit = true
            case "--mirror": c.mirror = true; c.mirrorIsExplicit = true
            case "--no-mirror": c.mirror = false; c.mirrorIsExplicit = true
            case "--no-reconnect": c.reconnect = false
            case "--json": c.json = true
            case "--duration":
                guard let n = Double(value), n.isFinite, n > 0, n <= 86400 else { throw DroidDozeCamError.message("Duration must be 0…86400 seconds (exclusive of zero).") }; c.duration = n
            case "--adb": c.adbPath = value
            case "--server": c.serverPath = value
            case "--require-hardware": c.requireHardware = true
            case "--syphon": c.syphon = true
            case "--syphon-framework": c.syphonFrameworkPath = value
            case "--demand-dir": c.demandDirectory = value
            default: throw DroidDozeCamError.message("Unknown option \(key). Run droiddozecam help.")
            }
        }
        if supplied.contains("--camera-torch") && supplied.contains("--no-camera-torch") {
            throw DroidDozeCamError.message("Use either --camera-torch or --no-camera-torch.")
        }
        let androidOptions: Set<String> = ["--camera-zoom", "--camera-torch", "--no-camera-torch", "--video-encoder", "--android-size"]
        if !supplied.intersection(androidOptions).isEmpty {
            guard [.auto, .android].contains(c.source), c.device == nil else {
                throw DroidDozeCamError.message("Camera zoom, torch, encoder and source size require Android USB capture.")
            }
            c.source = .android
        }
        if c.command == "cameras" {
            guard supplied.isSubset(of: ["--serial", "--adb", "--server", "--json"]) else {
                throw DroidDozeCamError.message("cameras accepts --serial, --adb, --server and --json only.")
            }
            return c
        }
        if c.cameraID != nil && supplied.contains("--facing") { throw DroidDozeCamError.message("Use either --camera-id or --facing, not both.") }
        if supplied.contains("--mirror") && supplied.contains("--no-mirror") { throw DroidDozeCamError.message("Use either --mirror or --no-mirror, not both.") }
        if c.serial != nil && c.device != nil { throw DroidDozeCamError.message("Use --serial for Android or --device for native cameras, not both.") }
        if c.serial != nil && ![.auto,.android].contains(c.source) { throw DroidDozeCamError.message("--serial requires --source android or auto.") }
        if c.device != nil && [.android,.test].contains(c.source) { throw DroidDozeCamError.message("--device only selects AVFoundation cameras.") }
        if c.syphon && !["preview", "probe"].contains(c.command) {
            throw DroidDozeCamError.message("--syphon is available with preview or probe; run uses the DroidDozeCam system extension.")
        }
        if c.syphonFrameworkPath != nil && !c.syphon { throw DroidDozeCamError.message("--syphon-framework requires --syphon.") }
        if c.demandDirectory != nil && c.command != "serve" { throw DroidDozeCamError.message("--demand-dir requires serve.") }
        if c.command == "serve" {
            guard !["--device", "--syphon", "--syphon-framework", "--duration", "--json"].contains(where: supplied.contains) else {
                throw DroidDozeCamError.message("serve accepts Android USB or test-pattern capture options only.")
            }
            guard [.auto, .android, .test].contains(c.source) else { throw DroidDozeCamError.message("serve supports --source android or test.") }
            if c.source == .auto { c.source = .android }
            if !supplied.contains("--size") { c.size = .fullHD }
            if !supplied.contains("--fps") { c.fps = 60 }
            if !supplied.contains("--bitrate") { c.bitrate = 20_000_000 }
        }
        if c.size == .ultraHD && c.fps > 60 { throw DroidDozeCamError.message("4K capture supports up to 60 fps. Use 1080p for 120 fps.") }
        let streaming = Set(["--source","--device","--serial","--size","--fps","--bitrate","--facing","--camera-id","--android-size","--rotate","--zoom","--fit","--mirror","--no-mirror","--no-reconnect","--duration","--require-hardware","--syphon","--syphon-framework","--camera-zoom","--camera-torch","--no-camera-torch","--video-encoder"])
        if !["run", "probe", "preview", "serve"].contains(c.command), !supplied.intersection(streaming).isEmpty {
            throw DroidDozeCamError.message("Capture options are only accepted by run, probe, preview, and serve.")
        }
        return c
    }
}
