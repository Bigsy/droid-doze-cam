import Foundation

public enum PhoneCamError: Error, LocalizedError, Equatable {
    case message(String)
    public var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

public enum Constants {
    public static let version = "0.1.0"
    public static let cameraName = "USB WakeCam"
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
    public static let vga = VideoSize(width: 640, height: 480)
    // Both the source and sink publish this exact, deterministic order.
    public static let supported: [VideoSize] = [.hd, .fullHD, .vga]
}

public enum InputSource: String, CaseIterable, Sendable { case auto, continuity, uvc, android, test }
public enum FitMode: String, Sendable { case fit, fill }

public struct Configuration: Equatable, Sendable {
    public var command = "help"
    public var source: InputSource = .auto
    public var device: String?
    public var serial: String?
    public var size = VideoSize.hd
    public var fps = 30
    public var bitrate = 8_000_000
    public var facing = "back"
    public var cameraID: String?
    public var androidSize: VideoSize?
    public var rotation = 0
    public var mirror = false
    public var fit: FitMode = .fit
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
    public static func parse(_ arguments: [String]) throws -> Self {
        var c = Configuration()
        var args = arguments
        if args.first == "--help" || args.first == "-h" { return c }
        if args.first == "--version" { c.command = "version"; return c }
        guard let command = args.first else { return c }
        let commands = ["help", "version", "devices", "doctor", "run", "probe", "preview", "serve", "install-extension", "uninstall-extension", "status"]
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
            let flags = ["--mirror", "--no-reconnect", "--json", "--require-hardware", "--syphon"]
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
                guard VideoSize.supported.contains(c.size) else { throw PhoneCamError.message("Virtual camera sizes: 640x480, 1280x720, 1920x1080.") }
            case "--fps":
                guard let n = Int(value), [15, 24, 25, 30, 60].contains(n) else { throw PhoneCamError.message("FPS must be 15, 24, 25, 30, or 60.") }; c.fps = n
            case "--bitrate":
                let s = value.lowercased(); let factor = s.hasSuffix("m") ? 1_000_000 : s.hasSuffix("k") ? 1_000 : 1
                let digits = factor == 1 ? s : String(s.dropLast())
                guard let n = Int(digits), n > 0, n <= 100_000_000 / factor else { throw PhoneCamError.message("Bitrate must be 1K…100M, e.g. 8M.") }
                c.bitrate = n * factor
                guard c.bitrate >= 1000 else { throw PhoneCamError.message("Bitrate must be at least 1000 bits/s.") }
            case "--facing":
                guard ["front", "back", "external"].contains(value) else { throw PhoneCamError.message("Facing must be front, back, or external.") }; c.facing = value
            case "--camera-id":
                guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46,95].contains($0) }) else { throw PhoneCamError.message("Invalid Android camera ID.") }; c.cameraID = value
            case "--android-size": c.androidSize = try VideoSize(value)
            case "--rotate":
                guard let n = Int(value), [0,90,180,270].contains(n) else { throw PhoneCamError.message("Rotation must be 0, 90, 180, or 270 clockwise.") }; c.rotation = n
            case "--fit":
                guard let fit = FitMode(rawValue: value) else { throw PhoneCamError.message("Fit mode must be fit or fill.") }; c.fit = fit
            case "--mirror": c.mirror = true
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
        let streaming = Set(["--source","--device","--serial","--size","--fps","--bitrate","--facing","--camera-id","--android-size","--rotate","--fit","--mirror","--no-reconnect","--duration","--require-hardware","--syphon","--syphon-framework"])
        if !["run", "probe", "preview", "serve"].contains(c.command), !supplied.intersection(streaming).isEmpty {
            throw PhoneCamError.message("Capture options are only accepted by run, probe, preview, and serve.")
        }
        return c
    }
}
