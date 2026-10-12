import Foundation
import CoreVideo
import CryptoKit
import PhoneCamCore

struct AndroidTools {
    let adb: String
    init(_ c: Configuration) throws { adb = try ProcessRunner.executable("adb",override:c.adbPath) }
    func devices(cancellation: Cancellation? = nil) throws -> [ADBDevice] { ADBDevice.parse(try ProcessRunner.run(adb,["devices","-l"],cancellation:cancellation).text) }
    static func serverPath(_ c: Configuration) throws -> String {
        var candidates: [String] = []
        if let path = c.serverPath { candidates = [(path as NSString).expandingTildeInPath] }
        else {
            if let resources = Bundle.main.resourceURL { candidates.append(resources.appendingPathComponent("scrcpy-server-v\(Constants.scrcpyVersion)").path) }
            candidates.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DroidDozeCam/scrcpy-server-v\(Constants.scrcpyVersion)").path)
        }
        guard let path = candidates.first(where:{FileManager.default.fileExists(atPath:$0)}) else {
            throw PhoneCamError.message("Pinned scrcpy server \(Constants.scrcpyVersion) is missing. Run scripts/setup-android.sh from the source package.")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath:path)
        guard let byteCount = attributes[.size] as? NSNumber, (1...4_194_304).contains(byteCount.intValue) else { throw PhoneCamError.message("Invalid scrcpy server file size.") }
        let data = try Data(contentsOf:URL(fileURLWithPath:path),options:.mappedIfSafe)
        let digest = SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
        guard digest == Constants.scrcpySHA256 else { throw PhoneCamError.message("scrcpy server SHA-256 mismatch. Only the pinned official \(Constants.scrcpyVersion) server is accepted.") }
        return path
    }
}

final class AndroidCapture: CaptureSource {
    func run(configuration c: Configuration, cancellation: Cancellation, onFrame: @escaping (CVPixelBuffer) -> Void) throws {
        let tools = try AndroidTools(c), selected = try ADBDevice.select(tools.devices(cancellation:cancellation),serial:c.serial)
        let prefix = ["-s",selected.serial]
        let sdkText = try ProcessRunner.run(tools.adb,prefix+["shell","getprop","ro.build.version.sdk"],cancellation:cancellation).text
        guard let sdk = Int(sdkText), sdk >= 31 else { throw PhoneCamError.message("ADB camera capture requires Android 12+ (API 31). Older phones need a separate companion application, not included in this build.") }
        let server = try AndroidTools.serverPath(c)
        let sessionID = try ScrcpySessionID(UInt32.random(in:1...0x7fffffff))
        let scid = sessionID.hex
        let remote = "/data/local/tmp/phonecam-\(scid).jar"
        _ = try ProcessRunner.run(tools.adb,prefix+["push",server,remote],timeout:30,cancellation:cancellation)
        defer { _ = try? ProcessRunner.run(tools.adb,prefix+["shell","rm","-f",remote],timeout:3,allowFailure:true) }
        let portText = try ProcessRunner.run(tools.adb,prefix+["forward","tcp:0","localabstract:\(sessionID.socketName)"],cancellation:cancellation).text
        guard let line = portText.split(whereSeparator:\.isNewline).last, let port = UInt16(line), port > 0 else { throw PhoneCamError.message("ADB did not return a valid local port: \(portText)") }
        defer { _ = try? ProcessRunner.run(tools.adb,prefix+["forward","--remove","tcp:\(port)"],timeout:3,allowFailure:true) }
        var options = [
            "scid=\(scid)","log_level=warn","video=true","audio=false","control=false",
            "video_source=camera","video_codec=h264","tunnel_forward=true",
            "send_dummy_byte=true","send_device_meta=false","send_codec_meta=true","send_frame_meta=true",
            "video_bit_rate=\(c.bitrate)","camera_fps=\(c.fps)","cleanup=true",
            "video_codec_options=i-frame-interval=1,max-bframes=0"
        ]
        if let id = c.cameraID { options.append("camera_id=\(id)") } else { options.append("camera_facing=\(c.facing)") }
        if let size = c.androidSize { options.append("camera_size=\(size)") }
        else { options += ["max_size=\(c.size.width)","camera_ar=16:9"] }
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
                guard dummy.first == 0 else { throw PhoneCamError.message("Invalid scrcpy handshake byte.") }
                connected = candidate; break
            } catch { cancellation.sleep(0.2) }
        }
        guard let connection = connected else { throw PhoneCamError.message("Android camera server did not start. Check USB authorization, camera privacy toggle, Android version, and server logs above.") }
        let streamHeader = try StreamHeader(data:connection.readExact(12))
        log("USB Android \(selected.model ?? selected.serial), encoded \(streamHeader.width)x\(streamHeader.height), requested \(c.fps)fps / \(c.bitrate)bit/s.")
        let decoder = H264Decoder(requireHardware:c.requireHardware,onFrame:onFrame)
        var epoch: Double?, lastPTS: UInt64?, skipping = false
        while !cancellation.isCancelled {
            let header = try PacketHeader(data:connection.readExact(12))
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
