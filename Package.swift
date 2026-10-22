// swift-tools-version: 5.9
import PackageDescription

var products: [Product] = [.library(name: "DroidDozeCamCore", targets: ["DroidDozeCamCore"])]
var targets: [Target] = [
    .target(name: "DroidDozeCamCore"),
    .testTarget(name: "DroidDozeCamCoreTests", dependencies: ["DroidDozeCamCore"])
]
#if os(macOS)
products += [
    .executable(name: "droiddozecam", targets: ["droiddozecam"]),
    .executable(name: "DroidDozeCamCameraExtension", targets: ["DroidDozeCamCameraExtension"])
]
targets += [
    .target(name: "DroidDozeCamMedia", dependencies: ["DroidDozeCamCore"], linkerSettings: [
        .linkedFramework("CoreMedia"), .linkedFramework("CoreVideo"),
        .linkedFramework("CoreImage"), .linkedFramework("Metal"), .linkedFramework("MetalPerformanceShaders"),
        .linkedFramework("IOSurface"), .linkedFramework("Vision"), .linkedFramework("CoreML")
    ]),
    .target(name: "DroidDozeCamSyphon", publicHeadersPath: "include", cSettings: [.unsafeFlags(["-fobjc-arc"])], linkerSettings: [
        .linkedFramework("Foundation"), .linkedFramework("AppKit"), .linkedFramework("Metal"), .linkedFramework("CoreVideo")
    ]),
    .executableTarget(name: "droiddozecam", dependencies: ["DroidDozeCamCore", "DroidDozeCamMedia", "DroidDozeCamSyphon"], linkerSettings: [
        .linkedFramework("AVFoundation"), .linkedFramework("CoreMediaIO"),
        .linkedFramework("SystemExtensions"), .linkedFramework("AppKit"),
        .linkedFramework("VideoToolbox"), .linkedFramework("Security")
    ]),
    .executableTarget(name: "DroidDozeCamCameraExtension", dependencies: ["DroidDozeCamCore", "DroidDozeCamMedia"], linkerSettings: [
        .linkedFramework("CoreMediaIO"), .linkedFramework("IOKit"), .linkedFramework("Security")
    ]),
    .testTarget(name: "DroidDozeCamMediaTests", dependencies: ["DroidDozeCamMedia", "DroidDozeCamCore"])
]
#endif

let package = Package(name: "DroidDozeCam", platforms: [.macOS(.v13)], products: products, targets: targets)
