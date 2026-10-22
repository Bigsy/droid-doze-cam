import Foundation
import CoreVideo
import CryptoKit
import DroidDozeCamCore

struct AndroidTools {
    static let savedADBPathKey = "setup.adbPath"
    let adb: String
    init(_ c: Configuration) throws {
        if let explicit = c.adbPath {
            adb = try ProcessRunner.executable("adb", override: explicit)
        } else if let saved = UserDefaults.standard.string(forKey: Self.savedADBPathKey),
                  FileManager.default.isExecutableFile(atPath: saved) {
            adb = saved
        } else {
            adb = try ProcessRunner.executable("adb")
        }
    }
    func devices(cancellation: Cancellation? = nil) throws -> [ADBDevice] { ADBDevice.parse(try ProcessRunner.run(adb,["devices","-l"],cancellation:cancellation).text) }
    /// Without a serial, lists the cameras of the only authorized USB phone.
    func cameras(serial: String? = nil, serverOverride: String? = nil, cancellation: Cancellation? = nil) throws -> (device: ADBDevice, cameras: [AndroidCameraInfo], encoders: [AndroidVideoEncoder]) {
        let device = try ADBDevice.select(devices(cancellation: cancellation), serial: serial)
        var configuration = Configuration()
        configuration.serverPath = serverOverride
        let server = try Self.serverPath(configuration)
        let remote = "/data/local/tmp/droiddozecam-list-\(UUID().uuidString).jar"
        let prefix = ["-s", device.serial]
        _ = try ProcessRunner.run(adb, prefix + ["push", server, remote], timeout: 20, cancellation: cancellation)
        defer { _ = try? ProcessRunner.run(adb, prefix + ["shell", "rm", "-f", remote], timeout: 3, allowFailure: true) }
        let output = try ProcessRunner.run(adb, prefix + ["shell", "CLASSPATH=\(remote)", "app_process", "/",
            "com.genymobile.scrcpy.Server", Constants.scrcpyVersion, "list_cameras=true", "list_camera_sizes=true", "list_encoders=true", "audio=false"], timeout: 20, cancellation: cancellation).text
        let cameras = AndroidCameraInfo.parse(output)
        guard !cameras.isEmpty else { throw DroidDozeCamError.message("Android reported no selectable cameras.") }
        return (device, cameras, AndroidVideoEncoder.parse(output))
    }
    static func serverPath(_ c: Configuration) throws -> String {
        var candidates: [String] = []
        if let path = c.serverPath { candidates = [(path as NSString).expandingTildeInPath] }
        else {
            if let resources = Bundle.main.resourceURL { candidates.append(resources.appendingPathComponent("scrcpy-server-v\(Constants.scrcpyVersion)").path) }
            candidates.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DroidDozeCam/scrcpy-server-v\(Constants.scrcpyVersion)").path)
        }
        guard let path = candidates.first(where:{FileManager.default.fileExists(atPath:$0)}) else {
            throw DroidDozeCamError.message("Pinned scrcpy server \(Constants.scrcpyVersion) is missing. Run scripts/setup-android.sh from the source package.")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath:path)
        guard let byteCount = attributes[.size] as? NSNumber, (1...4_194_304).contains(byteCount.intValue) else { throw DroidDozeCamError.message("Invalid scrcpy server file size.") }
        let data = try Data(contentsOf:URL(fileURLWithPath:path),options:.mappedIfSafe)
        let digest = SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
        guard digest == Constants.scrcpySHA256 else { throw DroidDozeCamError.message("scrcpy server SHA-256 mismatch. Only the pinned official \(Constants.scrcpyVersion) server is accepted.") }
        return path
    }
}

/// Receives a resolved configuration; keep device and server checks here for reconnects.
final class AndroidCapture: CaptureSource {
    func run(configuration c: Configuration, cancellation: Cancellation, onFrame: @escaping (CVPixelBuffer) -> Void) throws {
        let tools = try AndroidTools(c), selected = try ADBDevice.select(tools.devices(cancellation:cancellation),serial:c.serial)
        let prefix = ["-s",selected.serial]
        let server = try AndroidTools.serverPath(c)
        let sessionID = try ScrcpySessionID(UInt32.random(in:1...0x7fffffff))
        let scid = sessionID.hex
        let remote = "/data/local/tmp/droiddozecam-\(scid).jar"
        _ = try ProcessRunner.run(tools.adb,prefix+["push",server,remote],timeout:30,cancellation:cancellation)
        defer { _ = try? ProcessRunner.run(tools.adb,prefix+["shell","rm","-f",remote],timeout:3,allowFailure:true) }
        let portText = try ProcessRunner.run(tools.adb,prefix+["forward","tcp:0","localabstract:\(sessionID.socketName)"],cancellation:cancellation).text
        guard let line = portText.split(whereSeparator:\.isNewline).last, let port = UInt16(line), port > 0 else { throw DroidDozeCamError.message("ADB did not return a valid local port: \(portText)") }
        defer { _ = try? ProcessRunner.run(tools.adb,prefix+["forward","--remove","tcp:\(port)"],timeout:3,allowFailure:true) }
        let options = try ScrcpyVideoOptions.arguments(c, session: sessionID)
        let process = Process()
        process.executableURL = URL(fileURLWithPath:tools.adb)
        // Options contain only locally validated values. No user-provided shell program is executed.
        process.arguments = prefix+["shell","CLASSPATH=\(remote)","app_process","/","com.genymobile.scrcpy.Server",Constants.scrcpyVersion]+options
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.standardError; process.standardError = FileHandle.standardError
        try process.run()
        defer { ProcessRunner.stop(process) }
        var connected: USBConnection?
        let deadline = ProcessInfo.processInfo.systemUptime+20
        while !cancellation.isCancelled && ProcessInfo.processInfo.systemUptime < deadline && process.isRunning {
            do {
                let candidate = try USBConnection(port:port,cancellation:cancellation)
                let dummy = try candidate.readExact(1,timeout:5)
                guard dummy.first == 0 else { throw DroidDozeCamError.message("Invalid scrcpy handshake byte.") }
                connected = candidate; break
            } catch { cancellation.sleep(0.2) }
        }
        guard let connection = connected else { throw DroidDozeCamError.message("Android camera server did not start. Check USB authorization, camera privacy toggle, Android version, and server logs above.") }
        _ = try StreamHeader(data: connection.readExact(4))
        var hasSession = false
        let decoder = H264Decoder(requireHardware:c.requireHardware,onFrame:onFrame)
        var epoch: Double?, lastPTS: UInt64?, skipping = false
        while !cancellation.isCancelled {
            let record = try VideoRecordHeader(data: connection.readExact(12))
            if case .session(let metadata) = record {
                decoder.beginSession()
                epoch = nil; lastPTS = nil; skipping = false; hasSession = true
                log("USB Android \(selected.model ?? selected.serial), encoded \(metadata.width)x\(metadata.height), requested \(c.fps)fps / \(c.bitrate)bit/s.")
                continue
            }
            guard hasSession, case .packet(let header) = record else {
                throw DroidDozeCamError.message("Video packet arrived before its session metadata.")
            }
            let payload = try connection.readExact(header.size)
            if !header.isConfiguration {
                let now = ProcessInfo.processInfo.systemUptime
                let pts = Double(header.presentationTimeMicroseconds)/1_000_000
                if epoch == nil || (lastPTS != nil && header.presentationTimeMicroseconds < lastPTS!) { epoch = now-pts }
                lastPTS = header.presentationTimeMicroseconds
                let lag = now-(epoch!+pts)
                if !skipping && lag > 0.4 { skipping = true; decoder.resynchronize(); log("Decoder fell behind; dropping dependent frames until the next keyframe.") }
                if skipping {
                    if !header.isKeyFrame { continue }
                    skipping = false; epoch = now-pts
                }
            }
            try autoreleasepool { try decoder.consume(header:header,payload:payload) }
        }
    }
}
