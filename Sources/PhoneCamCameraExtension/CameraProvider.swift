import Foundation
import CoreMediaIO
import CoreMedia
import CoreVideo
import IOKit.audio
import Security
import os
import PhoneCamCore
import PhoneCamMedia

private let cameraLog = Logger(subsystem: "dev.flyfish.phonecam", category: "CameraExtension")

/// All device, stream-property, rendering and asynchronous-consumption state is serialized here.
final class CameraProvider: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var camera: CameraDevice!
    let workQueue = DispatchQueue(label: "PhoneCam.extension", qos: .userInteractive, autoreleaseFrequency: .workItem)
    private let key = DispatchSpecificKey<UInt8>()
    override init() {
        super.init()
        workQueue.setSpecific(key: key, value: 1)
        provider = CMIOExtensionProvider(source: self, clientQueue: workQueue)
        do { camera = try CameraDevice(owner: self); try provider.addDevice(camera.device) }
        catch { fatalError("PhoneCam extension initialization: \(error)") }
    }
    func sync<T>(_ block: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: key) != nil { return try block() }
        return try workQueue.sync(execute: block)
    }
    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }
    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let p = CMIOExtensionProviderProperties(dictionary: [:]); p.manufacturer = "PhoneCam"; return p
    }
    func setProviderProperties(_ properties: CMIOExtensionProviderProperties) throws {}
    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) { sync { camera.disconnected(client) } }
}

final class CameraDevice: NSObject, CMIOExtensionDeviceSource {
    unowned let owner: CameraProvider
    private(set) var device: CMIOExtensionDevice!
    private(set) var output: CameraStream!
    private(set) var input: CameraStream!
    private var renderer: FrameRenderer
    private var sourceUsers = 0
    private var sourceTimer: DispatchSourceTimer?
    private var sinkUsers = 0
    private var sinkGeneration: UInt64 = 0
    private var latest: CVPixelBuffer?
    private var latestArrival: Double = 0
    private var latestGeneration: UInt64 = 0
    private var convertedGeneration: UInt64 = UInt64.max
    private var converted: CVPixelBuffer?
    private var clock = MonotonicClock()
    private var lastErrorLog: Double = 0
    init(owner: CameraProvider) throws {
        self.owner = owner; renderer = try FrameRenderer(size: .hd)
        super.init()
        _ = try renderer.black() // Reserve an immutable privacy frame before client buffers can fill the pool.
        device = CMIOExtensionDevice(localizedName: Constants.cameraName, deviceID: UUID(uuidString: Constants.deviceUUID)!,
                                     legacyDeviceID: Constants.deviceUUID, source: self)
        output = try CameraStream(device: self, sink: false)
        input = try CameraStream(device: self, sink: true)
        try device.addStream(output.stream); try device.addStream(input.stream)
    }
    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }
    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let p = CMIOExtensionDeviceProperties(dictionary: [:]); p.transportType = kIOAudioDeviceTransportTypeVirtual
        p.model = "PhoneCam USB Video Bridge"; return p
    }
    func setDeviceProperties(_ properties: CMIOExtensionDeviceProperties) throws {}
    func outputFormatChanged(index: Int, duration: CMTime) throws {
        let size = VideoSize.supported[index]
        if renderer.size != size {
            let replacement = try FrameRenderer(size: size)
            _ = try replacement.black()
            renderer = replacement; converted = nil; convertedGeneration = .max
        }
        if sourceUsers > 0 { scheduleSource(duration: duration) }
    }
    private func scheduleSource(duration: CMTime) {
        sourceTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: owner.workQueue)
        timer.schedule(deadline: .now(), repeating: duration.seconds, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.emit() }; sourceTimer = timer; timer.resume()
    }
    func startOutput() { sourceUsers += 1; if sourceUsers == 1 { scheduleSource(duration: output.duration) } }
    func stopOutput() {
        sourceUsers = max(0, sourceUsers - 1)
        if sourceUsers == 0 { sourceTimer?.cancel(); sourceTimer = nil; converted = nil; convertedGeneration = .max }
    }
    private func report(_ error: Error) {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastErrorLog > 5 { cameraLog.error("Video processing: \(String(describing: error), privacy: .public)"); lastErrorLog = now }
    }
    private func emit() {
        guard sourceUsers > 0 else { return }
        autoreleasepool {
            do {
                let pixel: CVPixelBuffer
                if let latest, ProcessInfo.processInfo.systemUptime - latestArrival <= Constants.staleFrameSeconds {
                    if converted == nil || convertedGeneration != latestGeneration {
                        converted = try renderer.convert(latest); convertedGeneration = latestGeneration
                    }
                    pixel = converted!
                } else {
                    latest = nil; converted = nil; convertedGeneration = .max
                    pixel = try renderer.black()
                }
                let ns = clock.next(hostNanoseconds: Int64(VideoFrames.nanoseconds(VideoFrames.now)))
                let sample = try VideoFrames.sample(pixel, time: CMTime(value: ns, timescale: 1_000_000_000), duration: output.duration)
                output.stream.send(sample, discontinuity: [], hostTimeInNanoseconds: UInt64(ns))
            } catch { report(error) }
        }
    }
    func startInput() throws {
        guard let client = input.client else { throw PhoneCamError.message("No authorized camera producer.") }
        sinkUsers += 1
        if sinkUsers == 1 { sinkGeneration &+= 1; consume(client: client, generation: sinkGeneration) }
    }
    func stopInput() {
        sinkUsers = max(0, sinkUsers - 1)
        if sinkUsers == 0 {
            sinkGeneration &+= 1; input.client = nil; latest = nil; converted = nil; convertedGeneration = .max
        }
    }
    func disconnected(_ client: CMIOExtensionClient) {
        if input.client?.clientID == client.clientID { sinkUsers = 1; stopInput() }
    }
    private func consume(client: CMIOExtensionClient, generation: UInt64) {
        guard sinkUsers > 0, generation == sinkGeneration else { return }
        input.stream.consumeSampleBuffer(from: client) { [weak self] sample, sequence, _, hasMore, error in
            guard let self else { return }
            self.owner.workQueue.async {
                guard self.sinkUsers > 0, generation == self.sinkGeneration else { return }
                if let sample, let pixel = CMSampleBufferGetImageBuffer(sample) {
                    let size = VideoSize.supported[self.input.activeIndex]
                    let age = CMTimeSubtract(VideoFrames.now, CMSampleBufferGetPresentationTimeStamp(sample)).seconds
                    // Bound dimensions, require our advertised format, reject old queued samples after stalls.
                    if CVPixelBufferGetWidth(pixel) == size.width, CVPixelBufferGetHeight(pixel) == size.height,
                       CVPixelBufferGetPixelFormatType(pixel) == VideoFrames.pixelFormat,
                       age.isFinite, age >= -0.25, age <= Constants.staleFrameSeconds {
                        self.latest = pixel; self.latestArrival = ProcessInfo.processInfo.systemUptime - max(0, age)
                        self.latestGeneration &+= 1
                    }
                    self.input.stream.notifyScheduledOutputChanged(CMIOExtensionScheduledOutput(
                        sequenceNumber: sequence, hostTimeInNanoseconds: VideoFrames.nanoseconds(VideoFrames.now)))
                }
                if let error { self.report(error) }
                // Always schedule, never synchronously recurse. Only one consume request is outstanding.
                let delay = error != nil ? 0.1 : (hasMore ? 0.0 : (sample == nil ? 0.005 : 0.0))
                self.owner.workQueue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.consume(client: client, generation: generation) }
            }
        }
    }
}

final class CameraStream: NSObject, CMIOExtensionStreamSource {
    unowned let camera: CameraDevice
    let sink: Bool
    private(set) var stream: CMIOExtensionStream!
    let formats: [CMIOExtensionStreamFormat]
    var activeIndex = 0
    var duration = CMTime(value: 1, timescale: 30)
    var client: CMIOExtensionClient?
    init(device: CameraDevice, sink: Bool) throws {
        camera = device; self.sink = sink
        formats = try VideoSize.supported.map {
            CMIOExtensionStreamFormat(formatDescription: try VideoFrames.description(size: $0),
                maxFrameDuration: CMTime(value: 1, timescale: 15), minFrameDuration: CMTime(value: 1, timescale: 60), validFrameDurations: nil)
        }
        super.init()
        stream = CMIOExtensionStream(localizedName: sink ? "PhoneCam Producer" : "PhoneCam Video",
            streamID: UUID(uuidString: sink ? Constants.sinkUUID : Constants.sourceUUID)!, direction: sink ? .sink : .source,
            clockType: .hostTime, source: self)
    }
    var availableProperties: Set<CMIOExtensionProperty> {
        var result: Set<CMIOExtensionProperty> = [.streamActiveFormatIndex, .streamFrameDuration]
        if sink { result.formUnion([.streamSinkBufferQueueSize, .streamSinkBuffersRequiredForStartup]) }
        return result
    }
    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        camera.owner.sync {
            let p = CMIOExtensionStreamProperties(dictionary: [:]); p.activeFormatIndex = activeIndex; p.frameDuration = duration
            if sink { p.sinkBufferQueueSize = 2; p.sinkBuffersRequiredForStartup = 1 }
            return p
        }
    }
    func setStreamProperties(_ properties: CMIOExtensionStreamProperties) throws {
        try camera.owner.sync {
            let index = properties.activeFormatIndex ?? activeIndex
            let time = properties.frameDuration ?? duration
            guard formats.indices.contains(index), time.isNumeric, time.seconds.isFinite,
                  time.seconds >= 1.0/60.0 - 0.00001, time.seconds <= 1.0/15.0 + 0.00001 else {
                throw PhoneCamError.message("Unsupported camera format or frame duration.")
            }
            if !sink { try camera.outputFormatChanged(index: index, duration: time) }
            activeIndex = index; duration = time
        }
    }
    private func trusted(_ candidate: CMIOExtensionClient) -> Bool {
        guard let expectedID = Bundle.main.object(forInfoDictionaryKey: "PhoneCamHostBundleIdentifier") as? String,
              let team = Bundle.main.object(forInfoDictionaryKey: "PhoneCamTeamIdentifier") as? String,
              team.count == 10, candidate.signingID == expectedID else { return false }
        // Do not trust a caller's claimed PID or bundle ID alone; require an Apple-issued signature from our team.
        var guest: SecCode?, requirement: SecRequirement?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: candidate.pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(rawValue: 0), &guest) == errSecSuccess, let guest else { return false }
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(expectedID)\""
        guard SecRequirementCreateWithString(text as CFString, SecCSFlags(rawValue: 0), &requirement) == errSecSuccess, let requirement else { return false }
        return SecCodeCheckValidity(guest, SecCSFlags(rawValue: 0), requirement) == errSecSuccess
    }
    func authorizedToStartStream(for candidate: CMIOExtensionClient) -> Bool {
        camera.owner.sync {
            guard sink else { return true } // Camera consumers are additionally subject to the OS's camera permission model.
            guard client == nil || client?.clientID == candidate.clientID, trusted(candidate) else {
                cameraLog.error("Rejected producer; use the correctly signed PhoneCam host app."); return false
            }
            client = candidate; return true
        }
    }
    func startStream() throws { try camera.owner.sync { if sink { try camera.startInput() } else { camera.startOutput() } } }
    func stopStream() throws { camera.owner.sync { if sink { camera.stopInput() } else { camera.stopOutput() } } }
}
