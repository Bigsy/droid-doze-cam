import Foundation
import SystemExtensions
import PhoneCamCore

final class ExtensionManager: NSObject, OSSystemExtensionRequestDelegate {
    private var request: OSSystemExtensionRequest?
    private let completion: (Int32) -> Void
    private let activate: Bool
    init(activate: Bool, completion: @escaping (Int32) -> Void) { self.activate = activate; self.completion = completion }
    func submit() throws {
        let bundle = Bundle.main
        guard bundle.bundleURL.path.hasPrefix("/Applications/"), bundle.bundleURL.pathExtension == "app" else {
            throw PhoneCamError.message("System extension requests must originate from /Applications/USBWakeCam.app. Install the built app first; invoke its bundled CLI, not .build/release/phonecam.")
        }
        let directory = bundle.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions")
        let extensions = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys:nil).filter { $0.pathExtension == "systemextension" }
        guard extensions.count == 1, let identifier = Bundle(url:extensions[0])?.bundleIdentifier else { throw PhoneCamError.message("The app must contain exactly one valid camera system extension.") }
        let r = activate ? OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier:identifier, queue:.main) : OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier:identifier, queue:.main)
        r.delegate = self; request = r
        OSSystemExtensionManager.shared.submitRequest(r)
    }
    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        log("macOS requires your approval. Follow its notification and enable the USB WakeCam camera extension in System Settings. The exact location depends on your macOS version (Privacy & Security / Login Items & Extensions / Camera Extensions).")
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
