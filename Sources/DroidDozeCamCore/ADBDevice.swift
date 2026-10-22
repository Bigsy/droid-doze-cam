import Foundation

public struct ADBDevice: Equatable, Codable {
    public let serial: String
    public let state: String
    public let model: String?
    public let usbPath: String?
    public var isUSB: Bool { usbPath != nil }
    public static func parse(_ text: String) -> [ADBDevice] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2, !line.hasPrefix("List of devices"), !line.hasPrefix("*"),
                  ["device", "unauthorized", "offline", "no"].contains(fields[1]) else { return nil }
            func field(_ key: String) -> String? { fields.first(where: { $0.hasPrefix(key + ":") }).map { String($0.dropFirst(key.count + 1)) } }
            return ADBDevice(serial: fields[0], state: fields[1], model: field("model"), usbPath: field("usb"))
        }
    }
    public static func select(_ devices: [ADBDevice], serial: String?) throws -> ADBDevice {
        if let serial {
            guard let d = devices.first(where: { $0.serial == serial }) else { throw DroidDozeCamError.message("USB device '\(serial)' is not connected.") }
            guard d.state == "device" else { throw DroidDozeCamError.message("Android '\(serial)' is \(d.state). Unlock the phone and authorize USB debugging.") }
            guard d.isUSB else { throw DroidDozeCamError.message("Selected Android is not a USB transport. Wireless ADB is intentionally rejected.") }
            return d
        }
        let usb = devices.filter { $0.isUSB && $0.state == "device" }
        guard usb.count == 1 else {
            if usb.count > 1 { throw DroidDozeCamError.message("Several Android USB devices are connected. Specify --serial.") }
            if devices.contains(where: { $0.state == "unauthorized" }) { throw DroidDozeCamError.message("Android is unauthorized. Unlock it and accept USB debugging for this Mac.") }
            throw DroidDozeCamError.message("No authorized USB Android device. Enable USB debugging, use a data cable, and run droiddozecam devices.")
        }
        return usb[0]
    }
}
