import AppKit
import Sparkle
import DroidDozeCamCore

/// Only the menu process starts Sparkle; capture and CLI commands never check the network.
@MainActor
final class AppUpdater: NSObject, SPUUpdaterDelegate, NSMenuItemValidation {
    private var controller: SPUStandardUpdaterController?
    private var observations: [NSKeyValueObservation] = []
    let maintenance = AppUpdateMaintenance()
    private(set) var isInstalling = false
    private(set) var unavailableReason: String?
    var onChange: (() -> Void)?
    var canCheck: Bool { controller?.updater.canCheckForUpdates == true && unavailableReason == nil }
    var automaticChecks: Bool { controller?.updater.automaticallyChecksForUpdates == true }

    func start() {
        guard controller == nil else { return }
        guard CameraSetup.installedInApplications,
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32,
              let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: feed), url.scheme == "https", url.host != nil else {
            unavailableReason = "Open the installed app in Applications to enable updates."
            onChange?()
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        observations = [
            controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.onChange?() }
            },
            controller.updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.onChange?() }
            }
        ]
        do { try controller.updater.start() }
        catch { unavailableReason = "Updates could not start: \(error.localizedDescription)" }
        onChange?()
    }

    @objc func checkForUpdates() {
        guard canCheck else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    func setAutomaticChecks(_ enabled: Bool) { controller?.updater.automaticallyChecksForUpdates = enabled }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { canCheck }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        try maintenance.requireIdle()
    }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        try maintenance.requireIdle()
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) { isInstalling = true }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        isInstalling = false
        maintenance.recover(reconcileManualUpgrade: false) { }
    }
}

/// Persist before stopping launchd's KeepAlive job. The next menu launch recovers it even if
/// installation was interrupted. Extension activation runs before any UI enumerates cameras.
@MainActor
final class AppUpdateMaintenance {
    private struct Pending: Codable {
        let previousBuild: String
        var restartService: Bool
        var replaceExtension: Bool
    }
    private let directory: URL
    private let marker: URL
    private let servicePlist: URL
    private let build: String
    private let installed: Bool
    private let identifier: String
    private let command: (String, [String]) throws -> CommandResult
    var onIssue: ((String, String) -> Void)?

    init(directory: URL = supportDirectory, servicePlist: URL = CameraSetup.servicePlist,
         build: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
         installed: Bool = CameraSetup.installedInApplications,
         identifier: String = (Bundle.main.bundleIdentifier ?? "com.hedworth.usbwakecam") + ".camera",
         command: @escaping (String, [String]) throws -> CommandResult = {
             try ProcessRunner.run($0, $1, timeout: 5, allowFailure: true)
         }) {
        self.directory = directory
        self.marker = directory.appendingPathComponent("pending-app-update.json")
        self.servicePlist = servicePlist
        self.build = build
        self.installed = installed
        self.identifier = identifier
        self.command = command
    }

    private func run(_ executable: String, _ arguments: [String], allowFailure: Bool = false) throws -> CommandResult {
        let result = try command(executable, arguments)
        if !allowFailure && result.status != 0 { throw DroidDozeCamError.message(result.text) }
        return result
    }
    private var extensionManager: ExtensionManager?
    private var domain: String { "gui/\(getuid())" }
    private let label = "com.hedworth.droiddozecam.service"

    func requireIdle() throws {
        if let status = ServiceStatusFile(directory: directory).read(), kill(status.pid, 0) == 0, status.state != .idle {
            throw DroidDozeCamError.message("Close the preview and stop using DroidDozeCam in video apps before updating.")
        }
    }

    func prepare() throws {
        try requireIdle()
        // A camera app may retain an older extension across several host app updates. Carry that
        // recovery forward rather than making every later app update wait for the old process.
        let previous = FileManager.default.fileExists(atPath: marker.path)
            ? try JSONDecoder().decode(Pending.self, from: Data(contentsOf: marker)) : nil
        let loaded = try serviceLoaded()
        let extensions = try run("/usr/bin/systemextensionsctl", ["list"])
        let approved = Self.approvedExtensionBuild(in: extensions.text, identifier: identifier) != nil
        let pending = Pending(previousBuild: previous?.previousBuild ?? build,
                              restartService: loaded || previous?.restartService == true,
                              replaceExtension: approved || previous?.replaceExtension == true)
        try save(pending)
        if loaded {
            do {
                _ = try run("/bin/launchctl", ["bootout", domain, servicePlist.path])
            } catch {
                // Keep recovery state if launchd stopped the job before reporting an error.
                recover { }
                throw error
            }
        }
    }

    func recover(reconcileManualUpgrade: Bool = true, completion: @escaping () -> Void) {
        do {
            guard installed else { completion(); return }
            if !FileManager.default.fileExists(atPath: marker.path) {
                guard reconcileManualUpgrade else { completion(); return }
                // Drag-and-drop upgrades have no Sparkle shutdown marker. Reconcile their approved
                // extension too, before the settings UI or service attaches to the old camera.
                let listing = try run("/usr/bin/systemextensionsctl", ["list"], allowFailure: true)
                guard listing.status == 0,
                      let previous = Self.approvedExtensionBuild(in: listing.text, identifier: identifier),
                      previous.compare(build, options: .numeric) == .orderedAscending else { completion(); return }
                try save(Pending(previousBuild: previous, restartService: false, replaceExtension: true))
            }
            let pending = try JSONDecoder().decode(Pending.self, from: Data(contentsOf: marker))
            Task { @MainActor [self] in
                var pending = pending
                if pending.previousBuild != build && pending.replaceExtension {
                    do {
                        try requireIdle()
                        if try serviceLoaded() {
                            pending.restartService = true
                            try save(pending)
                            _ = try run("/bin/launchctl", ["bootout", domain, servicePlist.path])
                        }
                    } catch {
                        finish(pending, clear: false)
                        show("Camera update waiting", "\(error.localizedDescription) Reopen DroidDozeCam once the camera is idle.")
                        completion()
                        return
                    }
                    // The old menu and service are gone, but other apps may still hold a camera open.
                    for _ in 0..<30 {
                        if !RunningCameraExtension.builds(identifier: identifier).contains(where: { $0 != build }) { break }
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                    if RunningCameraExtension.builds(identifier: identifier).contains(where: { $0 != build }) {
                        finish(pending, clear: false)
                        show("Camera update waiting", "The app updated. Quit camera apps and reopen DroidDozeCam to finish updating its camera extension. The previous extension remains available.")
                        completion()
                        return
                    }
                    let state = pending
                    let manager = ExtensionManager(activate: true) { [weak self] result in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            guard let self else { completion(); return }
                            self.extensionManager = nil
                            self.finish(state, clear: result == 0 || result == 2)
                            if result == 2 {
                                self.show("Restart required", "Restart your Mac to finish updating the camera extension.")
                            } else if result != 0 {
                                self.show("Camera update needs attention", "Reopen DroidDozeCam to retry. Check System Settings for a camera extension approval request.")
                            }
                            completion()
                        }
                    }
                    extensionManager = manager
                    do { try manager.submit() }
                    catch {
                        extensionManager = nil
                        finish(pending, clear: false)
                        show("Camera update needs attention", error.localizedDescription)
                        completion()
                    }
                } else {
                    pending.replaceExtension = false
                    finish(pending, clear: true)
                    completion()
                }
            }
        } catch {
            show("Update recovery needs attention", "\(error.localizedDescription) Open Settings → Setup to restart the service.")
            completion()
        }
    }

    private func serviceLoaded() throws -> Bool {
        try run("/bin/launchctl", ["print", "\(domain)/\(label)"], allowFailure: true).status == 0
    }

    static func approvedExtensionBuild(in listing: String, identifier: String) -> String? {
        for line in listing.split(separator: "\n") where line.contains("[activated enabled]") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard let index = fields.firstIndex(of: Substring(identifier)), index + 1 < fields.count,
                  let version = fields[index + 1].split(separator: "/").last else { continue }
            let build = String(version).trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            guard build.range(of: "^[0-9]+(?:\\.[0-9]+){0,2}$", options: .regularExpression) != nil else { continue }
            return build
        }
        return nil
    }

    private func save(_ pending: Pending) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(pending).write(to: marker, options: .atomic)
    }

    private func finish(_ pending: Pending, clear: Bool) {
        do {
            var pending = pending
            if pending.restartService {
                if FileManager.default.fileExists(atPath: servicePlist.path), try !serviceLoaded() {
                    _ = try run("/bin/launchctl", ["bootstrap", domain, servicePlist.path])
                }
                pending.restartService = false
            }
            if clear { try FileManager.default.removeItem(at: marker) }
            else { try save(pending) }
        } catch {
            show("Camera service needs attention", "\(error.localizedDescription) Open Settings → Setup and choose Restart Service.")
        }
    }

    private func show(_ title: String, _ message: String) {
        if let onIssue { onIssue(title, message); return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
