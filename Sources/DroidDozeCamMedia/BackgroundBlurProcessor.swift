import Foundation
import CoreVideo
import CoreML
import Vision

/// Segmentation runs independently of the camera's frame clock. Rendering uses the newest
/// completed mask, so a slow inference cannot stall the virtual camera or build a frame queue.
public final class BackgroundBlurProcessor {
    private let request = VNGeneratePersonSegmentationRequest()
    private let worker = DispatchQueue(label: "DroidDozeCam.personSegmentation", qos: .userInitiated)
    private let lock = NSLock()
    private var mask: CVPixelBuffer?
    private var enabled = false
    private var working = false
    private var generation: UInt64 = 0
    private var lastSubmitted = 0.0
    private var lastError = 0.0
    private var usingNeuralEngine = false
    public let computeDeviceDescription: String

    public init() {
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        var selectedDevice = "Vision automatic"
        if #available(macOS 15, *), let stages = try? request.supportedComputeStageDevices {
            for (stage, devices) in stages {
                if let neural = devices.first(where: {
                    if case .neuralEngine = $0 { return true }
                    return false
                }) {
                    request.setComputeDevice(neural, for: stage)
                    selectedDevice = "Apple Neural Engine"
                    usingNeuralEngine = true
                }
            }
        }
        computeDeviceDescription = selectedDevice
    }

    public func apply(to pixel: CVPixelBuffer, radius: Int, renderer: FrameRenderer) throws -> CVPixelBuffer {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        enabled = true
        let currentMask = mask
        let shouldSubmit = !working && now - lastSubmitted >= 1.0 / 20.0
        if shouldSubmit {
            working = true
            lastSubmitted = now
        }
        let frameGeneration = generation
        lock.unlock()

        if shouldSubmit {
            worker.async { [self, pixel] in
                let result: CVPixelBuffer?
                do {
                    result = try segment(pixel)
                } catch {
                    if usingNeuralEngine && fallBackToCPU() {
                        NSLog("DroidDozeCam Neural Engine segmentation failed; retrying on CPU: %@", error.localizedDescription)
                        result = try? segment(pixel)
                    } else {
                        result = nil
                        let now = ProcessInfo.processInfo.systemUptime
                        if now - lastError > 5 {
                            NSLog("DroidDozeCam person segmentation failed: %@", error.localizedDescription)
                            lastError = now
                        }
                    }
                }
                lock.lock()
                if generation == frameGeneration && enabled { mask = result }
                working = false
                lock.unlock()
            }
        }
        return try renderer.blurBackground(pixel, mask: currentMask, radius: radius)
    }

    private func segment(_ pixel: CVPixelBuffer) throws -> CVPixelBuffer? {
        try VNImageRequestHandler(cvPixelBuffer: pixel, options: [:]).perform([request])
        return request.results?.first?.pixelBuffer
    }

    private func fallBackToCPU() -> Bool {
        guard #available(macOS 15, *), let stages = try? request.supportedComputeStageDevices else { return false }
        var selectedCPU = false
        for (stage, devices) in stages {
            if let cpu = devices.first(where: {
                if case .cpu = $0 { return true }
                return false
            }) {
                request.setComputeDevice(cpu, for: stage)
                selectedCPU = true
            }
        }
        if selectedCPU { usingNeuralEngine = false }
        return selectedCPU
    }

    public func disable() {
        lock.lock()
        if enabled {
            enabled = false
            mask = nil
            generation &+= 1
        }
        lock.unlock()
    }
}
