import Foundation
import AppKit
import AVFoundation
import CoreVideo
import Metal
import Darwin
import PhoneCamCore

private func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
    let data = try encoder.encode(value)
    FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
}

private struct DeviceReport: Codable {
    let native: [NativeDeviceInfo]
    let androidUSB: [ADBDevice]
    let adbDiagnostic: String?
}
private struct DoctorReport: Codable {
    let version: String
    let macOS: String
    let architecture: String
    let bundle: String
    let cameraPermission: String
    let metalAvailable: Bool
    let virtualCameraPresent: Bool
    let extensionStatus: String
    let devices: DeviceReport
    let androidServer: String
    let signing: String
}

enum Commands {
    private static func deviceReport(_ c: Configuration) -> DeviceReport {
        do {
            let tools = try AndroidTools(c)
            return DeviceReport(native:NativeDevices.infos(), androidUSB:try tools.devices().filter { $0.isUSB }, adbDiagnostic:nil)
        } catch { return DeviceReport(native:NativeDevices.infos(), androidUSB:[], adbDiagnostic:error.localizedDescription) }
    }
    static func run(_ c: Configuration, cancellation: Cancellation, onProcessedFrame: ((CVPixelBuffer) -> Void)? = nil) throws {
        switch c.command {
        case "devices":
            let report = deviceReport(c)
            if c.json { try printJSON(report) }
            else {
                print("AVFoundation cameras:")
                for d in report.native { print("  \(d.name) [\(d.kind)]\n    id: \(d.id)\n    transport: \(d.transport)\n    \(d.formats.joined(separator:", "))") }
                print("Android USB devices:")
                for d in report.androidUSB { print("  \(d.serial) [\(d.state)] \(d.model ?? "")") }
                if let message = report.adbDiagnostic { print("  \(message)") }
                print("Native UVC phones and eligible iPhones can also be selected directly in meeting apps without the PhoneCam extension.")
            }
        case "status", "doctor":
            let visible = (try? VirtualCameraWriter.findDevice()) != nil
            let extensions = (try? ProcessRunner.run("/usr/bin/systemextensionsctl",["list"],allowFailure:true).text) ?? "Unable to read systemextensionsctl."
            let signing = (try? ProcessRunner.run("/usr/bin/codesign",["-dv","--verbose=4",Bundle.main.bundleURL.path],allowFailure:true).text) ?? "Cannot inspect code signature."
            let permission = AVCaptureDevice.authorizationStatus(for:.video)
            let permissionText: String
            switch permission { case .authorized: permissionText="authorized"; case .denied:permissionText="denied"; case .restricted:permissionText="restricted"; default:permissionText="not determined" }
            #if arch(arm64)
            let architecture = "arm64"
            #else
            let architecture = "x86_64"
            #endif
            let report = DoctorReport(version:Constants.version, macOS:ProcessInfo.processInfo.operatingSystemVersionString,
                architecture:architecture, bundle:Bundle.main.bundleURL.path, cameraPermission:permissionText,
                metalAvailable:MTLCreateSystemDefaultDevice() != nil, virtualCameraPresent:visible, extensionStatus:extensions,
                devices:deviceReport(c), androidServer:(try? AndroidTools.serverPath(c)) ?? "Pinned server not installed or hash invalid (only required for Android ADB).",
                signing:signing)
            if c.json { try printJSON(report) }
            else {
                print("PhoneCam \(report.version) | \(architecture) | \(report.macOS)")
                print("Bundle: \(report.bundle)\nCamera permission: \(permissionText)\nMetal: \(report.metalAvailable)\nVirtual camera visible: \(visible)")
                print("\n\(extensions)\n\nAndroid server: \(report.androidServer)")
                if c.command == "doctor" { print("\nCode signature:\n\(signing)"); try printJSON(report.devices) }
            }
        case "run", "probe", "preview":
            let report = try CaptureRuntime.run(c,cancellation:cancellation,onProcessedFrame:onProcessedFrame)
            if c.json { try printJSON(report) }
            else { print(String(format:"Stopped. received=%llu processed=%llu elapsed=%.2fs averageInput=%.2ffps",report.received,report.processed,report.elapsedSeconds,report.receivedFPS)) }
        default: throw PhoneCamError.message("Unsupported command.")
        }
    }
}

@main
@MainActor
struct PhoneCamMain {
    private static var manager: ExtensionManager?
    private static var preview: PreviewWindowController?
    private static var signals: [DispatchSourceSignal] = []
    static func main() {
        let c: Configuration
        do { c = try Configuration.parse(Array(CommandLine.arguments.dropFirst())) }
        catch { log(error.localizedDescription); exit(64) }
        if c.command == "help" { print(help); return }
        if c.command == "version" { print(Constants.version); return }
        // Keep Cocoa's main run loop available for TCC, extension approval, Syphon discovery and preview.
        let app = NSApplication.shared
        app.setActivationPolicy(c.command == "preview" ? .regular : .accessory)
        let cancellation = Cancellation()
        for number in [SIGINT,SIGTERM] {
            signal(number,SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal:number,queue:.main)
            source.setEventHandler {
                cancellation.cancel()
                if c.command.hasSuffix("extension") { log("Approval request interrupted; check phonecam status before retrying."); exit(130) }
            }
            source.resume(); signals.append(source)
        }
        DispatchQueue.main.async {
            if c.command == "install-extension" || c.command == "uninstall-extension" {
                let task = ExtensionManager(activate:c.command == "install-extension") { exit($0) }
                manager = task
                do { try task.submit() } catch { log(error.localizedDescription); exit(1) }
            } else {
                let frames: PreviewFrames?
                if c.command == "preview" {
                    let storage = PreviewFrames()
                    do {
                        preview = try PreviewWindowController(configuration:c, frames:storage, cancellation:cancellation)
                        preview?.show()
                    } catch { log(error.localizedDescription); exit(1) }
                    frames = storage
                } else { frames = nil }
                DispatchQueue.global(qos:.userInitiated).async {
                    do {
                        try Commands.run(c,cancellation:cancellation,onProcessedFrame:frames.map { storage in { pixel in storage.put(pixel) } })
                        DispatchQueue.main.async { preview?.close(); exit(0) }
                    }
                    catch { log(error.localizedDescription); DispatchQueue.main.async { preview?.close(); exit(1) } }
                }
            }
        }
        app.run()
    }
    static let help = """
    PhoneCam \(Constants.version) — native USB phone camera bridge for macOS 13+

    phonecam devices [--json]                  List AVFoundation cameras and authorized/unauthorized USB ADB phones
    phonecam doctor [--json]                   Inspect permissions, code signatures, GPU and USB prerequisites
    phonecam status [--json]                   Inspect extension registration and virtual camera visibility
    phonecam install-extension                Activate the signed, bundled camera system extension (approval required)
    phonecam uninstall-extension              Request extension deactivation (may require a reboot)
    phonecam run [OPTIONS]                     Publish to "\(Constants.cameraName)"; Ctrl+C stops
    phonecam probe [OPTIONS]                   Capture/process without publishing (10 seconds by default)
    phonecam preview [OPTIONS]                 Show processed video in a native window; close window or Ctrl+C to stop
    phonecam version

    OPTIONS (run/probe/preview)
      --source auto|continuity|uvc|android|test  Default: auto; never automatically selects another virtual camera
      --device ID_OR_NAME                      Native selector; probe/preview may explicitly select PhoneCam for testing
      --serial USB_SERIAL                      Android USB selector; wireless ADB is rejected
      --size 640x480|1280x720|1920x1080          Bridge size; default 1280x720 (meeting apps select their output format)
      --fps 15|24|25|30|60                      Default 30; actual source must support it
      --bitrate 8M                             Android H.264 bitrate; default 8M
      --facing front|back|external              Android only; default back
      --camera-id ID                           Android physical/logical camera ID; mutually exclusive with --facing
      --android-size WIDTHxHEIGHT              Request an exact Android camera size, instead of automatic selection
      --rotate 0|90|180|270                     Clockwise image rotation
      --mirror                                 Horizontal mirror after rotation
      --fit fit|fill                           Letterbox or crop; default fit
      --require-hardware                       Reject software H.264 decode (Android only)
      --syphon                                 Share processed frames locally with OBS (preview/probe only)
      --syphon-framework PATH                  Optional path to an installed official Syphon.framework
      --no-reconnect                           Exit on disconnect; otherwise retry the SAME established source
      --duration SECONDS                       Stop after duration; run/preview=unlimited, probe=10 by default
      --json                                   Machine-readable final report; progress/errors go to stderr
      --adb PATH                               Override adb executable
      --server PATH                            Override pinned, SHA-256-verified scrcpy server

    Examples:
      phonecam run --source continuity
      phonecam run --source uvc --device "USB Camera"
      phonecam run --source android --facing back --size 1920x1080 --fps 30 --bitrate 12M
      phonecam run --source test
      phonecam preview --source android --require-hardware
      phonecam preview --source android --require-hardware --syphon
      phonecam probe --device "PhoneCam USB Camera" --duration 5

    iPhone: Continuity Camera requirements apply; macOS controls USB/wireless routing.
    Android: native USB Webcam when supported, otherwise Android 12+ / USB debugging / ADB.
    Native cameras can be used directly by meeting apps; run requires the PhoneCam extension.
    No audio device, recording, cloud relay, kernel extension or SIP modification.
    """
}
