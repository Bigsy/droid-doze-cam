import AppKit
import Foundation
import Darwin
import CryptoKit
import DroidDozeCamCore

private let adbArchiveURL = URL(string: "https://dl.google.com/android/repository/platform-tools_r37.0.1-darwin.zip")!
private let adbArchiveSHA256 = "ee39ad5967e95c2a07f04dbcbde96b1a0c916ba376096db5d2f498b7727a5d1d"

private func installDownloadedADB(_ archive: URL) throws -> URL {
    let data = try Data(contentsOf: archive, options: .mappedIfSafe)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard digest == adbArchiveSHA256 else {
        throw DroidDozeCamError.message("The Android Platform-Tools download failed its SHA-256 check.")
    }
    let base = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/DroidDozeCam", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let stage = base.appendingPathComponent(".platform-tools-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: stage) }
    _ = try ProcessRunner.run("/usr/bin/ditto", ["-xk", archive.path, stage.path], timeout: 30)
    let extracted = stage.appendingPathComponent("platform-tools", isDirectory: true)
    let adb = extracted.appendingPathComponent("adb")
    guard FileManager.default.isExecutableFile(atPath: adb.path),
          FileManager.default.fileExists(atPath: extracted.appendingPathComponent("NOTICE.txt").path) else {
        throw DroidDozeCamError.message("Google's Platform-Tools archive is missing adb or its license notice.")
    }
    _ = try ProcessRunner.run("/usr/bin/codesign", ["--verify", "--strict", adb.path], timeout: 10)
    _ = try ProcessRunner.run(adb.path, ["version"], timeout: 5)
    let destination = base.appendingPathComponent("platform-tools-37.0.1", isDirectory: true)
    if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.moveItem(at: extracted, to: destination)
    return destination.appendingPathComponent("adb")
}

struct CameraReadiness: Sendable {
    struct Item: Sendable {
        let name: String
        let detail: String
        let ready: Bool
    }
    let items: [Item]
    let guidance: String
    var ready: Bool { items.allSatisfy(\.ready) }
}

@MainActor
final class CameraSetup: NSObject {
    private var extensionManager: ExtensionManager?
    private var downloadTask: URLSessionDownloadTask?
    private var downloadID: UUID?
    private var downloadResult: Result<URL, Error>?
    var onStatusChanged: (() -> Void)?

    var needsFirstRunSetup: Bool {
        !FileManager.default.fileExists(atPath: Self.servicePlist.path)
    }

    func downloadADB() {
        let terms = NSAlert()
        terms.messageText = "Google Android SDK License Agreement"
        terms.informativeText = "DroidDozeCam will download Android Platform-Tools 37.0.1 directly from Google and keep it in your Application Support folder. By choosing I Agree & Download, you agree to Google's Android SDK License Agreement."
        terms.addButton(withTitle: "View Terms")
        terms.addButton(withTitle: "I Agree & Download")
        terms.addButton(withTitle: "Cancel")
        while true {
            switch terms.runModal() {
            case .alertFirstButtonReturn:
                NSWorkspace.shared.open(URL(string: "https://developer.android.com/studio/terms")!)
            case .alertSecondButtonReturn:
                startADBDownload()
                return
            default: return
            }
        }
    }

    private func startADBDownload() {
        let alert = NSAlert()
        alert.messageText = "Downloading Android Platform-Tools"
        alert.informativeText = "Downloading version 37.0.1 from Google, then checking and installing ADB."
        let progress = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 320, height: 18))
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 100
        alert.accessoryView = progress
        alert.addButton(withTitle: "Cancel")
        downloadResult = nil
        let downloadID = UUID()
        self.downloadID = downloadID
        let task = URLSession.shared.downloadTask(with: adbArchiveURL) { [weak self] location, response, error in
            let result: Result<URL, Error> = Result {
                if let error { throw error }
                guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                      let location else {
                    throw DroidDozeCamError.message("Google's Platform-Tools download did not complete.")
                }
                return try installDownloadedADB(location)
            }
            DispatchQueue.main.async {
                guard let self, self.downloadID == downloadID else { return }
                self.downloadResult = result
                NSApp.stopModal(withCode: .alertSecondButtonReturn)
            }
        }
        downloadTask = task
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            progress.doubleValue = max(0, min(100, task.progress.fractionCompleted * 100))
        }
        // runModal spins the run loop in its modal-panel mode, where a default-mode timer never fires.
        RunLoop.main.add(timer, forMode: .common)
        task.resume()
        let response = alert.runModal()
        timer.invalidate()
        downloadTask = nil
        self.downloadID = nil
        if response == .alertFirstButtonReturn {
            task.cancel()
            return
        }
        switch downloadResult {
        case .success(let path):
            UserDefaults.standard.set(path.path, forKey: AndroidTools.savedADBPathKey)
        case .failure(let error):
            show("ADB download failed", error.localizedDescription)
        case nil:
            show("ADB download stopped", "Please try again from Settings → Setup.")
        }
        onStatusChanged?()
    }

    nonisolated static var servicePlist: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.hedworth.droiddozecam.service.plist")
    }

    func restartService() {
        guard FileManager.default.fileExists(atPath: Self.servicePlist.path) else {
            show("Camera service is not installed", "Select Set Up Camera first.")
            return
        }
        do {
            try kickstartService()
            onStatusChanged?()
        } catch {
            show("Camera service could not restart", error.localizedDescription)
        }
    }

    private func kickstartService() throws {
        _ = try ProcessRunner.run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/com.hedworth.droiddozecam.service"], timeout: 5)
    }

    /// This app runs for a long time, and its CMIO device list can miss a camera extension activated or
    /// replaced after it started. A new process sees the current camera.
    nonisolated private static func cameraVisible() -> Bool {
        guard let executable = Bundle.main.executablePath,
              let status = try? ProcessRunner.run(executable, ["status"], timeout: 5, allowFailure: true) else { return false }
        return status.text.contains("Virtual camera visible: true")
    }

    /// The phone the login service captures from.
    nonisolated static var serviceSerial: String? {
        guard let plist = NSDictionary(contentsOf: servicePlist), let arguments = plist["ProgramArguments"] as? [String],
              let index = arguments.firstIndex(of: "--serial"), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    /// Runs several commands, so call it off the main thread.
    nonisolated static func readiness() -> CameraReadiness {
        let installed = Bundle.main.bundleURL.path == "/Applications/DroidDozeCam.app"
        let server = (try? AndroidTools.serverPath(Configuration())) != nil
        let adb = try? AndroidTools(Configuration())
        let service = (try? ProcessRunner.run("/bin/launchctl", ["print", "gui/\(getuid())/com.hedworth.droiddozecam.service"],
                                              timeout: 3, allowFailure: true).text.contains("state = running")) == true
        let camera = cameraVisible()
        var phoneReady = false
        var phoneDetail = "Connect with a USB data cable"
        if let adb {
            do {
                let serial = serviceSerial
                let devices = try adb.devices().filter { $0.isUSB && (serial == nil || $0.serial == serial) }
                if let ready = devices.first(where: { $0.state == "device" }) {
                    phoneReady = true
                    phoneDetail = ready.model ?? "Connected and authorized"
                } else if devices.contains(where: { $0.state == "unauthorized" }) {
                    phoneDetail = "Allow USB debugging on your phone"
                }
            } catch { phoneDetail = "Could not check connection" }
        } else { phoneDetail = "Install ADB first" }
        let guidance: String
        if !installed { guidance = "Move DroidDozeCam into Applications."
        } else if !server { guidance = "Reinstall the app to restore its camera helper."
        } else if adb == nil { guidance = "Download ADB or choose an existing installation below."
        } else if !phoneReady { guidance = "Enable USB debugging, connect your phone and approve this Mac."
        } else if !service { guidance = "Choose Set Up Camera to finish."
        } else if !camera { guidance = "Approve DroidDozeCam in System Settings → Camera Extensions."
        } else { guidance = "Select DroidDozeCam in your video app. Your phone can stay locked." }
        return CameraReadiness(items: [
            .init(name: "App", detail: !installed ? "Move to Applications" : !server ? "Camera helper missing" : "Installed", ready: installed && server),
            .init(name: "ADB", detail: adb == nil ? "Not installed" : "Available", ready: adb != nil),
            .init(name: "Phone", detail: phoneDetail, ready: phoneReady),
            .init(name: "Service", detail: service ? "Starts automatically" : "Not running", ready: service),
            .init(name: "Webcam", detail: camera ? "Available to video apps" : "Not available yet", ready: camera)
        ], guidance: guidance)
    }

    func chooseADB() {
        let panel = NSOpenPanel()
        panel.message = "Select adb from the platform-tools folder you downloaded from Google."
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let path = panel.url?.path else { return }
        guard URL(fileURLWithPath: path).lastPathComponent == "adb",
              FileManager.default.isExecutableFile(atPath: path) else {
            show("Invalid ADB file", "Choose the executable named adb inside the platform-tools folder.")
            return
        }
        do {
            _ = try ProcessRunner.run(path, ["version"], timeout: 5)
            UserDefaults.standard.set(path, forKey: AndroidTools.savedADBPathKey)
            onStatusChanged?()
        } catch {
            show("ADB could not run", error.localizedDescription)
        }
    }

    func begin() {
        do {
            let app = Bundle.main.bundleURL
            guard app.path.hasPrefix("/Applications/"), app.pathExtension == "app" else {
                throw DroidDozeCamError.message("Move DroidDozeCam.app into Applications, open it there, then choose Set Up Camera again.")
            }
            _ = try AndroidTools.serverPath(Configuration())
            let tools = try AndroidTools(Configuration())
            let devices = try tools.devices().filter { $0.isUSB && $0.state == "device" }
            guard !devices.isEmpty else {
                throw DroidDozeCamError.message("Connect an Android 12+ phone with a USB data cable, enable USB debugging, and accept the authorization prompt on the phone. Then choose Set Up Camera again.")
            }
            let serial = try chooseDevice(devices)
            try installService(serial: serial, app: app)
            onStatusChanged?()
            if Self.cameraVisible() {
                show("Camera ready", "DroidDozeCam is already available to Mac apps. The login service has been refreshed for USB phone \(serial).")
                return
            }
            let manager = ExtensionManager(activate: true) { [weak self] result in
                DispatchQueue.main.async {
                    self?.extensionManager = nil
                    self?.onStatusChanged?()
                    if result == 0 {
                        // The login service started before macOS registered this extension.
                        // Reconnect its CMIO client once activation has had time to propagate.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                            guard let self else { return }
                            do { try self.kickstartService() }
                            catch { log("Camera service restart after extension activation failed: \(error.localizedDescription)") }
                            self.onStatusChanged?()
                        }
                        self?.show("Camera extension activated", "Select DroidDozeCam in your video app. The phone starts streaming only while an app uses the camera.")
                    } else if result == 2 {
                        self?.show("Restart required", "Restart your Mac to finish activating the DroidDozeCam camera extension.")
                    } else {
                        self?.show("Camera extension could not activate", "Check System Settings → Privacy & Security or Login Items & Extensions for a DroidDozeCam approval request, then choose Set Up Camera again.")
                    }
                }
            }
            extensionManager = manager
            try manager.submit()
            show("Camera extension requested", "Approve DroidDozeCam when macOS asks. Its login service is ready for USB phone \(serial).")
        } catch {
            if error.localizedDescription.contains("adb is not installed") {
                show("ADB needed", "Open Settings → Setup to download or choose ADB.")
            } else {
                show("Setup needs attention", error.localizedDescription)
            }
        }
    }

    func remove() {
        let confirmation = NSAlert()
        confirmation.messageText = "Remove DroidDozeCam camera setup?"
        confirmation.informativeText = "This stops the login service and asks macOS to deactivate the camera extension. Your saved settings and downloaded ADB remain available if you set it up again."
        confirmation.addButton(withTitle: "Remove Setup")
        confirmation.addButton(withTitle: "Cancel")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }
        do {
            let destination = Self.servicePlist
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try ProcessRunner.run("/bin/launchctl", ["bootout", "gui/\(getuid())", destination.path],
                                          timeout: 5, allowFailure: true)
                try FileManager.default.removeItem(at: destination)
            }
            let manager = ExtensionManager(activate: false) { [weak self] result in
                DispatchQueue.main.async {
                    self?.extensionManager = nil
                    self?.onStatusChanged?()
                    if result == 0 {
                        self?.show("Camera setup removed", "The login service is stopped and the camera extension is deactivated. You can now remove the app from Applications.")
                    } else if result == 2 {
                        self?.show("Restart required", "Restart your Mac to finish removing the DroidDozeCam camera extension.")
                    } else {
                        self?.show("Camera extension needs attention", "The login service is stopped, but macOS did not deactivate the camera extension. Try Remove Camera Setup again before deleting the app.")
                    }
                }
            }
            extensionManager = manager
            try manager.submit()
            onStatusChanged?()
            show("Camera removal requested", "macOS is deactivating the camera extension.")
        } catch {
            show("Removal needs attention", error.localizedDescription)
        }
    }

    private func chooseDevice(_ devices: [ADBDevice]) throws -> String {
        if devices.count == 1 { return devices[0].serial }
        let alert = NSAlert()
        alert.messageText = "Choose a USB phone"
        alert.informativeText = "DroidDozeCam will use this phone when a Mac app opens the camera."
        let selector = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 28), pullsDown: false)
        for device in devices { selector.addItem(withTitle: "\(device.model ?? "Android") (\(device.serial))") }
        alert.accessoryView = selector
        alert.addButton(withTitle: "Use Phone")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { throw DroidDozeCamError.message("Setup cancelled.") }
        return devices[selector.indexOfSelectedItem].serial
    }

    private func installService(serial: String, app: URL) throws {
        guard !serial.isEmpty, serial.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 58, 95].contains($0)
        }) else { throw DroidDozeCamError.message("Invalid USB phone serial.") }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let agents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let logs = home.appendingPathComponent("Library/Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let label = "com.hedworth.droiddozecam.service"
        let destination = Self.servicePlist
        let executable = app.appendingPathComponent("Contents/MacOS/droiddozecam").path
        let log = logs.appendingPathComponent("DroidDozeCam.log").path
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable, "serve", "--source", "android", "--serial", serial],
            "RunAtLoad": true,
            "KeepAlive": true,
            // launchd's default policy throttles the frame timers; capture must keep the camera's frame rate.
            "ProcessType": "Interactive",
            "StandardOutPath": log,
            "StandardErrorPath": log
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let domain = "gui/\(getuid())"
        _ = try? ProcessRunner.run("/bin/launchctl", ["bootout", domain, destination.path], timeout: 5, allowFailure: true)
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        _ = try ProcessRunner.run("/bin/launchctl", ["bootstrap", domain, destination.path], timeout: 5)
    }

    private func show(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
