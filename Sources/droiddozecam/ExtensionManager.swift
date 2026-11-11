import Foundation
import Darwin
import SystemExtensions
import DroidDozeCamCore

/// The camera extension processes macOS is running now, by the build each one runs.
enum RunningCameraExtension {
    static func builds(identifier: String) -> [String] {
        let capacity = Int(proc_listallpids(nil, 0))
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: capacity + 64)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        var builds: [String] = []
        for pid in pids.prefix(max(0, count)) where pid > 0 {
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            let executable = String(cString: path)
            guard executable.contains("/\(identifier).systemextension/Contents/MacOS/") else { continue }
            let bundle = URL(fileURLWithPath: executable).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            builds.append(Bundle(url: bundle)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")
        }
        return builds
    }
}

final class ExtensionManager: NSObject, OSSystemExtensionRequestDelegate {
    private var request: OSSystemExtensionRequest?
    private let completion: (Int32) -> Void
    private let activate: Bool
    private let force: Bool
    init(activate: Bool, force: Bool = false, completion: @escaping (Int32) -> Void) {
        self.activate = activate; self.force = force; self.completion = completion
    }
    func submit() throws {
        let bundle = Bundle.main
        guard bundle.bundleURL.path.hasPrefix("/Applications/"), bundle.bundleURL.pathExtension == "app" else {
            throw DroidDozeCamError.message("System extension requests must originate from /Applications/DroidDozeCam.app. Install the built app first; invoke its bundled CLI, not .build/release/droiddozecam.")
        }
        let directory = bundle.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions")
        let extensions = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys:nil).filter { $0.pathExtension == "systemextension" }
        guard extensions.count == 1, let bundled = Bundle(url:extensions[0]), let identifier = bundled.bundleIdentifier else { throw DroidDozeCamError.message("The app must contain exactly one valid camera system extension.") }
        // macOS can fail to start the replacement of an extension whose process is still running: the new
        // build is listed as active, but no extension runs and Mac apps lose the camera until a newer
        // build is installed or the Mac restarts. The process exits once nothing has a camera open.
        if activate && !force {
            let build = bundled.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            if let running = RunningCameraExtension.builds(identifier: identifier).first(where: { $0 != build }) {
                throw DroidDozeCamError.message("The camera extension (build \(running)) is still running, and replacing it now can leave Mac apps without the \(Constants.cameraName) camera. Quit apps that use a camera, such as browsers and call apps, stop the camera service, and try again once it has exited; scripts/install.sh does this. To replace it regardless, run droiddozecam install-extension --force.")
            }
        }
        let r = activate ? OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier:identifier, queue:.main) : OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier:identifier, queue:.main)
        r.delegate = self; request = r
        OSSystemExtensionManager.shared.submitRequest(r)
    }
    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        log("macOS requires your approval. Follow its notification and enable the DroidDozeCam camera extension in System Settings. The exact location depends on your macOS version (Privacy & Security / Login Items & Extensions / Camera Extensions).")
    }
    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties, withExtension replacement: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        log("Replacing camera extension \(existing.bundleShortVersion) with \(replacement.bundleShortVersion).")
        return .replace
    }
    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        if result == .completed { print(activate ? "Camera extension activated." : "Camera extension deactivated."); completion(0) }
        else { log("macOS accepted the request, but requires a restart to finish. Do not remove the host app until deactivation completes."); completion(2) }
    }
    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        log("Extension request failed: \(error.localizedDescription). Check signing, provisioning profiles, Team ID, approval and /Applications placement. See docs/SIGNING.md. SIP must remain enabled.")
        completion(1)
    }
}
