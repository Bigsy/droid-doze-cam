import Foundation

public enum PhoneCamError: Error, LocalizedError, Equatable {
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
    public static let scrcpyVersion = "3.3.4"
    public static let scrcpySHA256 = "8588238c9a5a00aa542906b6ec7e6d5541d9ffb9b5d0f6e1bc0e365e2303079e"
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
            throw PhoneCamError.message("Invalid size '\(text)'; use even dimensions such as 1280x720 (16…4096).")
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

public struct AndroidCameraInfo: Equatable, Sendable {
    public let id: String
    public let facing: String

    public static func parse(_ output: String) -> [Self] {
        let pattern = #"--camera-id=([A-Za-z0-9_.-]+)\s+\((front|back|external),"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        return expression.matches(in: output, range: range).compactMap { match in
            guard let idRange = Range(match.range(at: 1), in: output),
                  let facingRange = Range(match.range(at: 2), in: output) else { return nil }
            return Self(id: String(output[idRange]), facing: String(output[facingRange]))
        }
    }
}

public struct CameraCaptureSettings: Equatable, Sendable {
    public let size: VideoSize
    public let fps: Int
    public let bitrate: Int
    public let facing: String
    public let cameraID: String?

    public init(size: VideoSize, fps: Int, bitrate: Int, facing: String, cameraID: String? = nil) {
        self.size = size; self.fps = fps; self.bitrate = bitrate; self.facing = facing; self.cameraID = cameraID
    }

    public static let standard = CameraCaptureSettings(size: .fullHD, fps: 60, bitrate: 20_000_000, facing: "back")
    public static let frameRates = [15, 24, 25, 30, 60, 120]
    public var isSupported: Bool {
        let validCameraID = cameraID.map { id in
            !id.isEmpty && id.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
            }
        } ?? true
        return VideoSize.supported.contains(size) && Self.frameRates.contains(fps) &&
        !(size == .ultraHD && fps > 60) && (1_000...100_000_000).contains(bitrate) &&
        ["front", "back", "external"].contains(facing) && validCameraID
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
                               blurRadius: [12, 24, 40].contains(savedBlurRadius) ? savedBlurRadius : 24)
    }

    public func write(_ transform: CameraTransform) {
        precondition([0, 90, 180, 270].contains(transform.rotation))
        precondition(transform.zoom.isFinite && (1...4).contains(transform.zoom))
        precondition([12, 24, 40].contains(transform.blurRadius))
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
            cameraID: selection?["id"])
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
        CameraCaptureSettings(size: size, fps: fps, bitrate: bitrate, facing: facing, cameraID: cameraID)
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
        let commands = ["help", "version", "menu", "devices", "doctor", "run", "probe", "preview", "serve", "install-extension", "uninstall-extension", "status"]
        guard commands.contains(command) else { throw PhoneCamError.message("Unknown command '\(command)'. Run phonecam help.") }
        c.command = args.removeFirst()
        var supplied = Set<String>()
        while !args.isEmpty {
            let raw = args.removeFirst()
            if raw == "--help" || raw == "-h" { c.command = "help"; return c }
            let split = raw.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(split[0])
            guard !supplied.contains(key) else { throw PhoneCamError.message("Duplicate option \(key).") }
            supplied.insert(key)
            let flags = ["--mirror", "--no-mirror", "--no-reconnect", "--json", "--require-hardware", "--syphon"]
            var value = ""
            if flags.contains(key) {
                guard split.count == 1 else { throw PhoneCamError.message("\(key) does not take a value.") }
            } else if split.count == 2 { value = String(split[1]) }
            else {
                guard let next = args.first, !next.hasPrefix("--") else { throw PhoneCamError.message("Missing value for \(key).") }
                value = args.removeFirst()
            }
            switch key {
            case "--source":
                guard let s = InputSource(rawValue: value) else { throw PhoneCamError.message("Source must be auto, continuity, uvc, android, or test.") }; c.source = s
            case "--device": c.device = value
            case "--serial":
                // Passed as an argv element, never interpreted by a local shell.
                guard !value.isEmpty, !value.contains("\n") else { throw PhoneCamError.message("Invalid USB serial.") }; c.serial = value
            case "--size":
                c.size = try VideoSize(value)
                guard VideoSize.supported.contains(c.size) else { throw PhoneCamError.message("Virtual camera sizes: 640x480, 1280x720, 1920x1080, 2560x1440, 3840x2160.") }
                c.sizeIsExplicit = true
            case "--fps":
                guard let n = Int(value), CameraCaptureSettings.frameRates.contains(n) else { throw PhoneCamError.message("FPS must be 15, 24, 25, 30, 60, or 120.") }; c.fps = n; c.fpsIsExplicit = true
            case "--bitrate":
                let s = value.lowercased(); let factor = s.hasSuffix("m") ? 1_000_000 : s.hasSuffix("k") ? 1_000 : 1
                let digits = factor == 1 ? s : String(s.dropLast())
                guard let n = Int(digits), n > 0, n <= 100_000_000 / factor else { throw PhoneCamError.message("Bitrate must be 1K…100M, e.g. 8M.") }
                c.bitrate = n * factor
                guard c.bitrate >= 1000 else { throw PhoneCamError.message("Bitrate must be at least 1000 bits/s.") }
                c.bitrateIsExplicit = true
            case "--facing":
                guard ["front", "back", "external"].contains(value) else { throw PhoneCamError.message("Facing must be front, back, or external.") }; c.facing = value; c.facingIsExplicit = true
            case "--camera-id":
                guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46,95].contains($0) }) else { throw PhoneCamError.message("Invalid Android camera ID.") }; c.cameraID = value
            case "--android-size": c.androidSize = try VideoSize(value)
            case "--rotate":
                guard let n = Int(value), [0,90,180,270].contains(n) else { throw PhoneCamError.message("Rotation must be 0, 90, 180, or 270 clockwise.") }; c.rotation = n; c.rotationIsExplicit = true
            case "--zoom":
                guard let n = Double(value), n.isFinite, (1...4).contains(n) else { throw PhoneCamError.message("Zoom must be between 1 and 4.") }; c.zoom = n; c.zoomIsExplicit = true
            case "--fit":
                guard let fit = FitMode(rawValue: value) else { throw PhoneCamError.message("Fit mode must be fit or fill.") }; c.fit = fit; c.fitIsExplicit = true
            case "--mirror": c.mirror = true; c.mirrorIsExplicit = true
            case "--no-mirror": c.mirror = false; c.mirrorIsExplicit = true
            case "--no-reconnect": c.reconnect = false
            case "--json": c.json = true
            case "--duration":
                guard let n = Double(value), n.isFinite, n > 0, n <= 86400 else { throw PhoneCamError.message("Duration must be 0…86400 seconds (exclusive of zero).") }; c.duration = n
            case "--adb": c.adbPath = value
            case "--server": c.serverPath = value
            case "--require-hardware": c.requireHardware = true
            case "--syphon": c.syphon = true
            case "--syphon-framework": c.syphonFrameworkPath = value
            case "--demand-dir": c.demandDirectory = value
            default: throw PhoneCamError.message("Unknown option \(key). Run phonecam help.")
            }
        }
        if c.cameraID != nil && supplied.contains("--facing") { throw PhoneCamError.message("Use either --camera-id or --facing, not both.") }
        if supplied.contains("--mirror") && supplied.contains("--no-mirror") { throw PhoneCamError.message("Use either --mirror or --no-mirror, not both.") }
        if c.serial != nil && c.device != nil { throw PhoneCamError.message("Use --serial for Android or --device for native cameras, not both.") }
        if c.serial != nil && ![.auto,.android].contains(c.source) { throw PhoneCamError.message("--serial requires --source android or auto.") }
        if c.device != nil && [.android,.test].contains(c.source) { throw PhoneCamError.message("--device only selects AVFoundation cameras.") }
        if c.syphon && !["preview", "probe"].contains(c.command) {
            throw PhoneCamError.message("--syphon is available with preview or probe; run uses the PhoneCam system extension.")
        }
        if c.syphonFrameworkPath != nil && !c.syphon { throw PhoneCamError.message("--syphon-framework requires --syphon.") }
        if c.demandDirectory != nil && c.command != "serve" { throw PhoneCamError.message("--demand-dir requires serve.") }
        if c.command == "serve" {
            guard !["--device", "--syphon", "--syphon-framework", "--duration", "--json"].contains(where: supplied.contains) else {
                throw PhoneCamError.message("serve accepts Android USB capture options only.")
            }
            guard c.source == .auto || c.source == .android else { throw PhoneCamError.message("serve requires --source android.") }
            c.source = .android
            if !supplied.contains("--size") { c.size = .fullHD }
            if !supplied.contains("--fps") { c.fps = 60 }
            if !supplied.contains("--bitrate") { c.bitrate = 20_000_000 }
        }
        if c.size == .ultraHD && c.fps > 60 { throw PhoneCamError.message("4K capture supports up to 60 fps. Use 1080p for 120 fps.") }
        let streaming = Set(["--source","--device","--serial","--size","--fps","--bitrate","--facing","--camera-id","--android-size","--rotate","--zoom","--fit","--mirror","--no-mirror","--no-reconnect","--duration","--require-hardware","--syphon","--syphon-framework"])
        if !["run", "probe", "preview", "serve"].contains(c.command), !supplied.intersection(streaming).isEmpty {
            throw PhoneCamError.message("Capture options are only accepted by run, probe, preview, and serve.")
        }
        return c
    }
}
