// swift-tools-version: 5.9
import PackageDescription

var products: [Product] = [.library(name: "PhoneCamCore", targets: ["PhoneCamCore"])]
var targets: [Target] = [
    .target(name: "PhoneCamCore"),
    .testTarget(name: "PhoneCamCoreTests", dependencies: ["PhoneCamCore"])
]
#if os(macOS)
products += [
    .executable(name: "phonecam", targets: ["phonecam"]),
    .executable(name: "PhoneCamCameraExtension", targets: ["PhoneCamCameraExtension"])
]
targets += [
    .target(name: "PhoneCamMedia", dependencies: ["PhoneCamCore"], linkerSettings: [
        .linkedFramework("CoreMedia"), .linkedFramework("CoreVideo"),
        .linkedFramework("CoreImage"), .linkedFramework("Metal"), .linkedFramework("IOSurface")
    ]),
    .target(name: "PhoneCamSyphon", publicHeadersPath: "include", cSettings: [.unsafeFlags(["-fobjc-arc"])], linkerSettings: [
        .linkedFramework("Foundation"), .linkedFramework("AppKit"), .linkedFramework("Metal"), .linkedFramework("CoreVideo")
    ]),
    .executableTarget(name: "phonecam", dependencies: ["PhoneCamCore", "PhoneCamMedia", "PhoneCamSyphon"], linkerSettings: [
        .linkedFramework("AVFoundation"), .linkedFramework("CoreMediaIO"),
        .linkedFramework("SystemExtensions"), .linkedFramework("AppKit"),
        .linkedFramework("VideoToolbox"), .linkedFramework("Security")
    ]),
    .executableTarget(name: "PhoneCamCameraExtension", dependencies: ["PhoneCamCore", "PhoneCamMedia"], linkerSettings: [
        .linkedFramework("CoreMediaIO"), .linkedFramework("IOKit"), .linkedFramework("Security")
    ]),
    .testTarget(name: "PhoneCamMediaTests", dependencies: ["PhoneCamMedia", "PhoneCamCore"])
]
#endif

let package = Package(name: "PhoneCam", platforms: [.macOS(.v13)], products: products, targets: targets)
