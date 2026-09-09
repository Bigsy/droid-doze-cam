import Foundation
import CoreMediaIO

@main
struct ExtensionMain {
    static func main() {
        let provider = CameraProvider()
        CMIOExtensionProvider.startService(provider: provider.provider)
        withExtendedLifetime(provider) { CFRunLoopRun() }
    }
}
