import Foundation
import CoreMediaIO
import CoreMedia
import CoreVideo
import DroidDozeCamCore
import DroidDozeCamMedia

private enum CMIOProperties {
    static func address(_ selector: UInt32, scope: UInt32 = UInt32(kCMIOObjectPropertyScopeGlobal)) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: UInt32(kCMIOObjectPropertyElementMain))
    }
    static func ids(_ object: CMIOObjectID, _ selector: UInt32) throws -> [CMIOObjectID] {
        var address = address(selector), bytes: UInt32 = 0, used: UInt32 = 0
        try VideoFrames.check(CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &bytes), "Read CMIO list size")
        guard bytes > 0 else { return [] }
        guard bytes <= 1_048_576, bytes % 4 == 0 else { throw DroidDozeCamError.message("Invalid CMIO object list.") }
        var result = [CMIOObjectID](repeating: 0, count: Int(bytes) / 4)
        let status = result.withUnsafeMutableBytes { CMIOObjectGetPropertyData(object, &address, 0, nil, bytes, &used, $0.baseAddress!) }
        try VideoFrames.check(status, "Read CMIO object list")
        return Array(result.prefix(Int(used) / 4))
    }
    static func uid(_ object: CMIOObjectID) -> String? { string(object, UInt32(kCMIODevicePropertyDeviceUID)) }
    static func string(_ object: CMIOObjectID, _ selector: UInt32) -> String? {
        var address = address(selector), used: UInt32 = 0
        // CMIO returns a retained CF object through an untyped pointer.
        var value: Unmanaged<CFString>?
        let result = CMIOObjectGetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout.size(ofValue: value)), &used, &value)
        guard result == noErr, let value else { return nil }; return value.takeRetainedValue() as String
    }
    static func double(_ object: CMIOObjectID, _ selector: UInt32) -> Double? {
        var address = address(selector), value: Float64 = 0, used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<Float64>.size), &used, &value) == noErr else { return nil }
        return value
    }
    static func direction(_ stream: CMIOStreamID) throws -> UInt32 {
        var address = address(UInt32(kCMIOStreamPropertyDirection)), value: UInt32 = 0, used: UInt32 = 0
        try VideoFrames.check(CMIOObjectGetPropertyData(stream, &address, 0, nil, 4, &used, &value), "Read stream direction")
        return value
    }
    static func set(_ object: CMIOObjectID, _ selector: UInt32, _ value: Double) throws {
        var address = address(selector), value = value
        try VideoFrames.check(CMIOObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<Double>.size), &value), "Set CMIO property \(selector)")
    }
    static func set(_ object: CMIOObjectID, _ selector: UInt32, _ value: CMFormatDescription) throws {
        var address = address(selector), reference = Unmanaged.passUnretained(value)
        try withExtendedLifetime(value) {
            try VideoFrames.check(CMIOObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout.size(ofValue: reference)), &reference), "Set CMIO property \(selector)")
        }
    }
}

/// Single producer: all send()/stop() operations belong to the render queue.
final class VirtualCameraWriter {
    private let deviceID: CMIODeviceID
    private let streamID: CMIOStreamID
    private var queue: CMSimpleQueue?
    private var running = false
    private let fps: Int
    private var clock = MonotonicClock()
    static func findDevice() throws -> CMIODeviceID? {
        let devices = try CMIOProperties.ids(CMIOObjectID(kCMIOObjectSystemObject), UInt32(kCMIOHardwarePropertyDevices))
        return devices.first { CMIOProperties.uid($0)?.caseInsensitiveCompare(Constants.deviceUUID) == .orderedSame }
    }
    /// nil distinguishes a missing camera from an available camera with no viewers.
    static func demand() -> Bool? {
        guard let device = try? findDevice() else { return nil }
        let selector = Constants.demandPropertyCode.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return CMIOProperties.string(device, selector) == "1"
    }
    /// The frame rate a Mac app set on the camera's source stream (direction 1), or nil when it cannot be read.
    /// Apps set it before they start streaming; without an app it still holds the last app's rate.
    static func requestedFrameRate() -> Double? {
        guard let device = try? findDevice(), let streams = try? CMIOProperties.ids(device, UInt32(kCMIODevicePropertyStreams)),
              let source = streams.first(where: { (try? CMIOProperties.direction($0)) == 1 }) else { return nil }
        return CMIOProperties.double(source, UInt32(kCMIOStreamPropertyFrameRate))
    }
    init(size: VideoSize, fps: Int) throws {
        guard let device = try Self.findDevice() else {
            throw DroidDozeCamError.message("DroidDozeCam camera extension is unavailable. Run droiddozecam install-extension, approve it in System Settings, then run droiddozecam status.")
        }
        deviceID = device; self.fps = fps
        let streams = try CMIOProperties.ids(device, UInt32(kCMIODevicePropertyStreams))
        // A CMIO output stream (direction == 0) is the extension's sink. Never depend on enumeration order.
        guard let sink = streams.first(where: { (try? CMIOProperties.direction($0)) == 0 }) else { throw DroidDozeCamError.message("DroidDozeCam has no writable sink stream.") }
        streamID = sink
        let description = try VideoFrames.description(size: size)
        try CMIOProperties.set(sink, UInt32(kCMIOStreamPropertyFormatDescription), description)
        try CMIOProperties.set(sink, UInt32(kCMIOStreamPropertyFrameRate), Double(fps))
        var copied: Unmanaged<CMSimpleQueue>?
        try VideoFrames.check(CMIOStreamCopyBufferQueue(sink, { _, _, _ in }, nil, &copied), "Copy camera sink queue")
        guard let copied else { throw DroidDozeCamError.message("CMIO did not provide a sink queue.") }
        queue = copied.takeRetainedValue()
        try VideoFrames.check(CMIODeviceStartStream(device, sink), "Start camera sink (check host/extension signatures)")
        running = true
    }
    deinit { stop() }
    func stop() {
        guard running else { return }
        running = false
        _ = CMIODeviceStopStream(deviceID, streamID)
        // Do not dequeue here: the DAL/CMIO consumer owns successfully enqueued samples.
        queue = nil
    }
    @discardableResult func send(_ pixel: CVPixelBuffer) throws -> Bool {
        guard running, let queue else { throw DroidDozeCamError.message("Camera sink is not running.") }
        guard CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue) else { return false }
        let ns = clock.next(hostNanoseconds: Int64(VideoFrames.nanoseconds(VideoFrames.now)))
        let sample = try VideoFrames.sample(pixel, time: CMTime(value: ns, timescale: 1_000_000_000), fps: fps)
        let retained = Unmanaged.passRetained(sample)
        let status = CMSimpleQueueEnqueue(queue, element: UnsafeRawPointer(retained.toOpaque()))
        if status != noErr { retained.release(); return false }
        return true
    }
}
