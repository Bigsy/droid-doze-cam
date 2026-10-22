import Foundation
import CoreVideo
import Metal
import MetalPerformanceShaders
import DroidDozeCamCore

/// Background blur with Metal Performance Shaders and textures allocated once. Core Image gets
/// and recycles IOSurface intermediates for every blur pass, and those kernel calls cost far more
/// CPU than the GPU work itself (about 17% of a core at 1080p60, against under 1% here).
/// Use only from the owning FrameRenderer's queue.
final class MetalBlurCompositor {
    /// The frame is read through an sRGB view, so the blend happens in linear light like Core Image.
    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void blendWithMask(texture2d<float, access::read> frame [[texture(0)]],
                              texture2d<float, access::sample> background [[texture(1)]],
                              texture2d<float, access::sample> mask [[texture(2)]],
                              texture2d<float, access::write> output [[texture(3)]],
                              uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
        constexpr sampler linear(filter::linear, address::clamp_to_edge);
        float2 uv = (float2(gid) + 0.5) / float2(output.get_width(), output.get_height());
        float3 c = saturate(mix(background.sample(linear, uv).rgb, frame.read(gid).rgb, mask.sample(linear, uv).r));
        c = select(1.055 * powr(c, 1.0 / 2.4) - 0.055, 12.92 * c, c <= 0.0031308);
        output.write(float4(c, 1), gid);
    }
    """
    /// Blur a quarter-size copy: the lightest strength (radius 12) is still sigma 3 there.
    private static let downscale = 4
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let cache: CVMetalTextureCache
    private let shrink: MPSImageLanczosScale
    private let small: MTLTexture, blurred: MTLTexture, noMask: MTLTexture
    private var blur: (radius: Int, kernel: MPSImageGaussianBlur)?
    private var uploadedMask: (source: CVPixelBuffer, texture: MTLTexture)?

    init(device: MTLDevice, size: VideoSize) throws {
        guard MPSSupportsMTLDevice(device), let queue = device.makeCommandQueue() else {
            throw DroidDozeCamError.message("Metal Performance Shaders are unavailable.")
        }
        self.device = device; self.queue = queue
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        guard let function = library.makeFunction(name: "blendWithMask") else { throw DroidDozeCamError.message("Missing blur shader.") }
        pipeline = try device.makeComputePipelineState(function: function)
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess, let cache else {
            throw DroidDozeCamError.message("Cannot create a Metal texture cache.")
        }
        self.cache = cache
        shrink = MPSImageLanczosScale(device: device)
        let width = max(1, size.width / Self.downscale), height = max(1, size.height / Self.downscale)
        small = try Self.texture(device, .rgba16Float, width, height, gpuOnly: true)
        blurred = try Self.texture(device, .rgba16Float, width, height, gpuOnly: true)
        noMask = try Self.texture(device, .r8Unorm, 1, 1, gpuOnly: false)
        var zero: UInt8 = 0
        noMask.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zero, bytesPerRow: 1)
    }

    private static func texture(_ device: MTLDevice, _ format: MTLPixelFormat, _ width: Int, _ height: Int, gpuOnly: Bool) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        if gpuOnly { descriptor.storageMode = .private }
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw DroidDozeCamError.message("Cannot allocate a Metal texture.") }
        return texture
    }

    /// Input and output are IOSurface-backed 32BGRA frames of the same size; the mask is OneComponent8 at any size.
    /// A missing mask blurs the whole frame. Returns after the GPU has finished writing the output.
    func render(_ input: CVPixelBuffer, mask: CVPixelBuffer?, radius: Int, into output: CVPixelBuffer) throws {
        var wrapped: [CVMetalTexture] = [] // Keeps the IOSurface textures alive until the GPU completes.
        func wrap(_ pixel: CVPixelBuffer, _ format: MTLPixelFormat) throws -> MTLTexture {
            var reference: CVMetalTexture?
            guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixel, nil, format,
                    CVPixelBufferGetWidth(pixel), CVPixelBufferGetHeight(pixel), 0, &reference) == kCVReturnSuccess,
                  let reference, let texture = CVMetalTextureGetTexture(reference) else {
                throw DroidDozeCamError.message("Cannot expose a frame as a Metal texture.")
            }
            wrapped.append(reference); return texture
        }
        let frame = try wrap(input, .bgra8Unorm_srgb), destination = try wrap(output, .bgra8Unorm)
        let maskTexture = try mask.map(upload) ?? noMask
        if blur?.radius != radius {
            let kernel = MPSImageGaussianBlur(device: device, sigma: Float(radius) / Float(Self.downscale))
            kernel.edgeMode = .clamp
            blur = (radius, kernel)
        }
        guard let blur, let commands = queue.makeCommandBuffer() else { throw DroidDozeCamError.message("Cannot create a Metal command buffer.") }
        shrink.encode(commandBuffer: commands, sourceTexture: frame, destinationTexture: small)
        blur.kernel.encode(commandBuffer: commands, sourceTexture: small, destinationTexture: blurred)
        guard let encoder = commands.makeComputeCommandEncoder() else { throw DroidDozeCamError.message("Cannot create a Metal compute encoder.") }
        encoder.setComputePipelineState(pipeline)
        for (index, texture) in [frame, blurred, maskTexture, destination].enumerated() { encoder.setTexture(texture, index: index) }
        let threadWidth = pipeline.threadExecutionWidth
        encoder.dispatchThreads(MTLSize(width: destination.width, height: destination.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadWidth, height: pipeline.maxTotalThreadsPerThreadgroup / threadWidth, depth: 1))
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        withExtendedLifetime(wrapped) {}
        if commands.status == .error {
            throw DroidDozeCamError.message("Background blur GPU pass failed: \(commands.error?.localizedDescription ?? "unknown error").")
        }
    }

    /// Copies a mask into a texture once per new mask (20 per second at most), whatever memory backs it.
    private func upload(_ mask: CVPixelBuffer) throws -> MTLTexture {
        if let uploadedMask, uploadedMask.source === mask { return uploadedMask.texture }
        let width = CVPixelBufferGetWidth(mask), height = CVPixelBufferGetHeight(mask)
        let texture = try uploadedMask.map(\.texture).flatMap { $0.width == width && $0.height == height ? $0 : nil }
            ?? Self.texture(device, .r8Unorm, width, height, gpuOnly: false)
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let bytes = CVPixelBufferGetBaseAddress(mask) else { throw DroidDozeCamError.message("Cannot read the person mask.") }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: bytes, bytesPerRow: CVPixelBufferGetBytesPerRow(mask))
        uploadedMask = (mask, texture)
        return texture
    }
}
