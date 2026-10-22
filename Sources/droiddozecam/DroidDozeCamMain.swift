import Foundation
import AppKit
import AVFoundation
import CoreVideo
import Metal
import Darwin
import DroidDozeCamCore

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
private struct CameraCapabilitiesReport: Codable {
    let device: ADBDevice
    let cameras: [AndroidCameraInfo]
    let encoders: [AndroidVideoEncoder]
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
                print("Native UVC phones and eligible iPhones can also be selected directly in meeting apps without the DroidDozeCam extension.")
            }
        case "cameras":
            let listing = try AndroidTools(c).cameras(serial: c.serial, serverOverride: c.serverPath, cancellation: cancellation)
            if c.json { try printJSON(CameraCapabilitiesReport(device: listing.device, cameras: listing.cameras, encoders: listing.encoders)) }
            else {
                print("Reported cameras for \(listing.device.model ?? "Android") (declarations, not guaranteed modes):")
                for camera in listing.cameras {
                    print("  ID \(camera.id): \(camera.facing), fps \(camera.frameRates)")
                    if let lower = camera.minimumZoom, let upper = camera.maximumZoom { print("    Camera zoom: \(lower)…\(upper)×") }
                    for mode in camera.modes { print("    \(mode.size) — \(mode.frameRates) fps\(mode.highSpeed ? " (high speed)" : "")") }
                }
                print("H.264 encoders:")
                for encoder in listing.encoders { print("  \(encoder.name)\(encoder.hardware ? " (hardware)" : "")") }
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
                print("DroidDozeCam \(report.version) | \(architecture) | \(report.macOS)")
                print("Bundle: \(report.bundle)\nCamera permission: \(permissionText)\nMetal: \(report.metalAvailable)\nVirtual camera visible: \(visible)")
                print("\n\(extensions)\n\nAndroid server: \(report.androidServer)")
                if c.command == "doctor" { print("\nCode signature:\n\(signing)"); try printJSON(report.devices) }
            }
        case "run", "probe", "preview":
            let report = try CaptureRuntime.run(c,cancellation:cancellation,onProcessedFrame:onProcessedFrame)
            if c.json { try printJSON(report) }
            else { print(String(format:"Stopped. received=%llu processed=%llu elapsed=%.2fs averageInput=%.2ffps",report.received,report.processed,report.elapsedSeconds,report.receivedFPS)) }
        case "serve": try OnDemandService.run(c, cancellation: cancellation)
        default: throw DroidDozeCamError.message("Unsupported command.")
        }
    }
}

@main
@MainActor
struct DroidDozeCamMain {
    private static var manager: ExtensionManager?
    private static var preview: PreviewWindowController?
    private static var menuBar: MenuBarApp?
    private static var signals: [DispatchSourceSignal] = []
    static func main() {
        let c: Configuration
        let arguments = Array(CommandLine.arguments.dropFirst())
        let launchArguments = arguments.isEmpty && Bundle.main.bundleURL.pathExtension == "app" ? ["menu"] : arguments
        do { c = try Configuration.parse(launchArguments) }
        catch { log(error.localizedDescription); exit(64) }
        if c.command == "help" { print(help); return }
        if c.command == "version" { print(Constants.version); return }
        // Keep Cocoa's main run loop available for TCC, extension approval, Syphon discovery and preview.
        // NSApplication registers a process with Launch Services as DroidDozeCam.app, so opening the app
        // would switch to the login service instead of starting the menu; the service and reports skip it.
        let headless = ["serve", "status", "doctor", "devices", "cameras"].contains(c.command)
        if !headless { NSApplication.shared.setActivationPolicy(c.command == "preview" ? .regular : .accessory) }
        let cancellation = Cancellation()
        for number in [SIGINT,SIGTERM] {
            signal(number,SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal:number,queue:.main)
            source.setEventHandler {
                cancellation.cancel()
                if c.command.hasSuffix("extension") { log("Approval request interrupted; check droiddozecam status before retrying."); exit(130) }
                // The menu has no capture to wind down; the installer quits it this way.
                if c.command == "menu" { NSApplication.shared.terminate(nil) }
            }
            source.resume(); signals.append(source)
        }
        DispatchQueue.main.async {
            if c.command == "menu" {
                menuBar = MenuBarApp()
            } else if c.command == "install-extension" || c.command == "uninstall-extension" {
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
        if headless { CFRunLoopRun() } else { NSApplication.shared.run() }
    }
    static let help = """
    DroidDozeCam \(Constants.version) — native USB phone camera bridge for macOS 13+

    droiddozecam devices [--json]               List AVFoundation cameras and authorized/unauthorized USB ADB phones
    droiddozecam doctor [--json]                Inspect permissions, code signatures, GPU and USB prerequisites
    droiddozecam status [--json]                Inspect extension registration and virtual camera visibility
    droiddozecam menu                           Show the menu bar settings app (also opens from Finder)
    droiddozecam install-extension             Activate the signed, bundled camera system extension (approval required)
    droiddozecam uninstall-extension           Request extension deactivation (may require a reboot)
    droiddozecam run [OPTIONS]                  Publish to "\(Constants.cameraName)"; Ctrl+C stops
    droiddozecam serve [OPTIONS]                Start USB capture only while a Mac app uses the camera
    droiddozecam probe [OPTIONS]                Capture/process without publishing (10 seconds by default)
    droiddozecam preview [OPTIONS]              Show processed video in a native window; close window or Ctrl+C to stop
    droiddozecam cameras [--serial USB_SERIAL] [--json]  List phone modes, zoom ranges and H.264 encoders
    droiddozecam version

    OPTIONS (run/probe/preview/serve)
      --source auto|continuity|uvc|android|test  Default: auto; never automatically selects another virtual camera
      --device ID_OR_NAME                      Native selector; probe/preview may explicitly select DroidDozeCam for testing
      --serial USB_SERIAL                      Android USB selector; wireless ADB is rejected
      --size 640x480|1280x720|1920x1080|2560x1440|3840x2160  Bridge size; default 720p (serve: saved setting or 1080p)
      --fps 15|24|25|30|60|120                  Requested frame rate; 4K up to 60, 120 needs a high-speed camera mode
      --bitrate 8M                             Android H.264 bitrate; default 8M (serve: saved setting or 20M)
      --facing front|back|external              Android only; default back (serve: saved setting)
      --camera-id ID                           Android physical/logical camera ID; mutually exclusive with --facing
      --android-size WIDTHxHEIGHT|auto         Request an exact Android camera size, instead of automatic selection
      --camera-zoom RATIO                      Phone-side zoom; default 1, clamped by the phone
      --camera-torch / --no-camera-torch       Enable/disable the camera light (when available)
      --video-encoder NAME|auto                H.264 encoder; see droiddozecam cameras
      --rotate 0|90|180|270                     Clockwise image rotation; overrides saved setting
      --zoom 1...4                             Digital centre crop; overrides saved setting
      --mirror | --no-mirror                   Override saved horizontal mirror setting
      --fit fit|fill                           Letterbox or crop; overrides saved setting
      --require-hardware                       Reject software H.264 decode (Android only)
      --syphon                                 Share processed frames locally with OBS (preview/probe only)
      --syphon-framework PATH                  Optional path to an installed official Syphon.framework
      --no-reconnect                           Exit on disconnect; otherwise retry the SAME established source
      --duration SECONDS                       Stop after duration; run/preview=unlimited, probe=10 by default
      --json                                   Machine-readable final report; progress/errors go to stderr
      --adb PATH                               Override adb executable
      --server PATH                            Override pinned, SHA-256-verified scrcpy server
      --demand-dir PATH                        serve development override for the shared demand directory

    Examples:
      droiddozecam run --source continuity
      droiddozecam run --source uvc --device "USB Camera"
      droiddozecam run --source android --facing back --size 1920x1080 --fps 30 --bitrate 12M
      droiddozecam run --source test
      droiddozecam preview --source android --require-hardware
      droiddozecam preview --source android --require-hardware --syphon
      droiddozecam serve --source android --serial USB_SERIAL --size 1920x1080 --fps 60
      droiddozecam serve --source test
      droiddozecam probe --device "DroidDozeCam" --duration 5

    iPhone: Continuity Camera requirements apply; macOS controls USB/wireless routing.
    Android: native USB Webcam when supported, otherwise Android 12+ / USB debugging / ADB.
    Native cameras can be used directly by meeting apps; run requires our own signed extension.
    No audio device, recording, cloud relay, kernel extension or SIP modification.
    """
}
