import Foundation
import CoreMedia
import CoreVideo
import CoreImage
import Metal
import IOSurface
import DroidDozeCamCore

public enum VideoFrames {
    public static let pixelFormat = kCVPixelFormatType_32BGRA
    public static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw DroidDozeCamError.message("\(operation) failed (OSStatus \(status)).") }
    }
    public static var now: CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }
    public static func nanoseconds(_ time: CMTime) -> UInt64 {
        let t = CMTimeConvertScale(time, timescale: 1_000_000_000, method: .default)
        return t.isValid && t.value > 0 ? UInt64(t.value) : 0
    }
    public static func description(size: VideoSize) throws -> CMVideoFormatDescription {
        var result: CMVideoFormatDescription?
        try check(CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: pixelFormat,
            width: Int32(size.width), height: Int32(size.height), extensions: nil, formatDescriptionOut: &result), "Create video format")
        guard let result else { throw DroidDozeCamError.message("Missing video format description.") }; return result
    }
    public static func sample(_ pixel: CVPixelBuffer, time: CMTime, fps: Int) throws -> CMSampleBuffer {
        return try sample(pixel, time: time, duration: CMTime(value: 1, timescale: Int32(fps)))
    }
    public static func sample(_ pixel: CVPixelBuffer, time: CMTime, duration: CMTime) throws -> CMSampleBuffer {
        var description: CMVideoFormatDescription?
        try check(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: pixel, formatDescriptionOut: &description), "Describe pixel buffer")
        guard let description else { throw DroidDozeCamError.message("Pixel buffer has no format.") }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        try check(CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel,
            dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: description,
            sampleTiming: &timing, sampleBufferOut: &result), "Create sample buffer")
        guard let result else { throw DroidDozeCamError.message("Missing sample buffer.") }; return result
    }
}

/// Use only from one serialization queue. Output buffers are IOSurface backed and immutable after return.
public final class FrameRenderer {
    public let size: VideoSize
    public let usesMetal: Bool
    private let context: CIContext
    private let metalBlur: MetalBlurCompositor?
    private let pool: CVPixelBufferPool
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var cachedBlack: CVPixelBuffer?
    private let threshold = [kCVPixelBufferPoolAllocationThresholdKey: 8] as CFDictionary
    public init(size: VideoSize) throws {
        self.size = size
        if let device = MTLCreateSystemDefaultDevice() {
            usesMetal = true
            context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
            metalBlur = try? MetalBlurCompositor(device: device, size: size)
        } else {
            usesMetal = false
            context = CIContext(options: [.cacheIntermediates: false])
            metalBlur = nil
        }
        var pool: CVPixelBufferPool?
        let attributes: [String: Any] = [
            kCVPixelBufferWidthKey as String: size.width,
            kCVPixelBufferHeightKey as String: size.height,
            kCVPixelBufferPixelFormatTypeKey as String: VideoFrames.pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferCGImageCompatibilityKey as String: true
        ]
        try VideoFrames.check(CVPixelBufferPoolCreate(kCFAllocatorDefault,
            [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary, attributes as CFDictionary, &pool), "Create pixel pool")
        guard let pool else { throw DroidDozeCamError.message("Could not create pixel buffer pool.") }; self.pool = pool
    }
    public var blurCompositing: String { metalBlur != nil ? "Metal" : usesMetal ? "Core Image on Metal" : "Core Image CPU" }
    private var bounds: CGRect { CGRect(x: 0, y: 0, width: size.width, height: size.height) }
    private func allocate() throws -> CVPixelBuffer {
        var pixel: CVPixelBuffer?
        try VideoFrames.check(CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, threshold, &pixel), "Allocate bounded pixel buffer")
        guard let pixel else { throw DroidDozeCamError.message("Pixel pool is exhausted.") }
        return pixel
    }
    private func render(_ image: CIImage) throws -> CVPixelBuffer {
        let pixel = try allocate()
        context.render(image, to: pixel, bounds: bounds, colorSpace: colorSpace)
        CVBufferSetAttachment(pixel, kCVImageBufferCGColorSpaceKey, colorSpace, .shouldPropagate)
        return pixel
    }
    public func convert(_ input: CVPixelBuffer, rotation: Int = 0, mirror: Bool = false, fit: FitMode = .fit, zoom: Double = 1) throws -> CVPixelBuffer {
        guard zoom.isFinite && (1...4).contains(zoom) else { throw DroidDozeCamError.message("Zoom must be between 1 and 4.") }
        if rotation == 0 && !mirror && zoom == 1 && CVPixelBufferGetWidth(input) == size.width && CVPixelBufferGetHeight(input) == size.height &&
            CVPixelBufferGetPixelFormatType(input) == VideoFrames.pixelFormat && CVPixelBufferGetIOSurface(input) != nil {
            return input // No CPU copy or GPU conversion when the buffer already matches.
        }
        var image = CIImage(cvPixelBuffer: input)
        let orientation: Int32 = rotation == 90 ? 6 : rotation == 180 ? 3 : rotation == 270 ? 8 : 1
        image = image.oriented(forExifOrientation: orientation)
        var extent = image.extent
        guard extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite else { throw DroidDozeCamError.message("Invalid image extent.") }
        image = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        if mirror {
            image = image.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: extent.width, ty: 0))
        }
        if zoom > 1 {
            let factor = CGFloat(zoom)
            let crop = CGRect(x: extent.width * (1 - 1 / factor) / 2,
                              y: extent.height * (1 - 1 / factor) / 2,
                              width: extent.width / factor, height: extent.height / factor)
            image = image.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            extent = image.extent
        }
        let sx = CGFloat(size.width) / extent.width, sy = CGFloat(size.height) / extent.height
        let scale = fit == .fill ? max(sx, sy) : min(sx, sy)
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        extent = image.extent
        image = image.transformed(by: CGAffineTransform(translationX: (CGFloat(size.width) - extent.width) / 2 - extent.minX,
            y: (CGFloat(size.height) - extent.height) / 2 - extent.minY))
        let black = CIImage(color: .black).cropped(to: bounds)
        return try render(image.composited(over: black).cropped(to: bounds))
    }
    /// Keep the person sharp and blur everything outside the Vision mask. A missing mask
    /// blurs the whole frame while segmentation starts, so enabling the effect takes effect immediately.
    public func blurBackground(_ input: CVPixelBuffer, mask: CVPixelBuffer?, radius: Int) throws -> CVPixelBuffer {
        guard radius > 0 else { return input }
        if let metalBlur, CVPixelBufferGetIOSurface(input) != nil, CVPixelBufferGetPixelFormatType(input) == VideoFrames.pixelFormat,
           CVPixelBufferGetWidth(input) == size.width, CVPixelBufferGetHeight(input) == size.height,
           mask.map({ CVPixelBufferGetPixelFormatType($0) == kCVPixelFormatType_OneComponent8 }) ?? true {
            let pixel = try allocate()
            try metalBlur.render(input, mask: mask, radius: radius, into: pixel)
            CVBufferSetAttachment(pixel, kCVImageBufferCGColorSpaceKey, colorSpace, .shouldPropagate)
            return pixel
        }
        let foreground = CIImage(cvPixelBuffer: input).cropped(to: bounds)
        let background = foreground.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: bounds)
        guard let mask else { return try render(background) }
        let rawMask = CIImage(cvPixelBuffer: mask)
        let scaledMask = rawMask.transformed(by: CGAffineTransform(
            scaleX: bounds.width / rawMask.extent.width,
            y: bounds.height / rawMask.extent.height))
        let softMask = scaledMask.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 2])
            .cropped(to: bounds)
        let composited = foreground.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: background,
            kCIInputMaskImageKey: softMask
        ])
        return try render(composited.cropped(to: bounds))
    }
    public func black() throws -> CVPixelBuffer {
        if let cachedBlack { return cachedBlack }
        let frame = try render(CIImage(color: .black).cropped(to: bounds)); cachedBlack = frame; return frame
    }
    public func testPattern(frame: UInt64) throws -> CVPixelBuffer {
        let colors: [CIColor] = [.white, CIColor(red: 1, green: 1, blue: 0), CIColor(red: 0, green: 1, blue: 1), .green, CIColor(red: 1, green: 0, blue: 1), .red, .blue, .black]
        var image = CIImage(color: .black).cropped(to: bounds)
        for (i, color) in colors.enumerated() {
            let rect = CGRect(x: CGFloat(i) * bounds.width / 8, y: 0, width: ceil(bounds.width / 8), height: bounds.height)
            image = CIImage(color: color).cropped(to: rect).composited(over: image)
        }
        let y = CGFloat(frame % UInt64(size.height))
        image = CIImage(color: .white).cropped(to: CGRect(x: 0, y: y, width: bounds.width, height: 8)).composited(over: image)
        return try render(image.cropped(to: bounds))
    }
}
