import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import PhoneCamCore
import PhoneCamMedia

/// VideoToolbox hardware decoding, not an ffmpeg subprocess or a screen recording.
/// Confined to the USB reader thread except for the output callback.
final class H264Decoder {
    private var sps: Data?, pps: Data?
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var needsConfiguration = true
    private var waitingForIDR = true
    private let requireHardware: Bool
    private let onFrame: (CVPixelBuffer) -> Void
    private let decodeError = LatestValue<OSStatus>()
    init(requireHardware: Bool, onFrame: @escaping (CVPixelBuffer) -> Void) { self.requireHardware = requireHardware; self.onFrame = onFrame }
    deinit { invalidate() }
    private func invalidate() {
        if let session { VTDecompressionSessionWaitForAsynchronousFrames(session); VTDecompressionSessionInvalidate(session) }
        session = nil; format = nil
    }
    func resynchronize() { invalidate(); waitingForIDR = true; needsConfiguration = true }
    private func createSession() throws {
        guard let sps, let pps else { throw PhoneCamError.message("H.264 stream has no SPS/PPS configuration.") }
        invalidate()
        var description: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { s in pps.withUnsafeBytes { p -> OSStatus in
            let pointers: [UnsafePointer<UInt8>] = [s.bindMemory(to:UInt8.self).baseAddress!,p.bindMemory(to:UInt8.self).baseAddress!]
            let sizes = [sps.count,pps.count]
            return pointers.withUnsafeBufferPointer { ptrs in sizes.withUnsafeBufferPointer { lengths in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator:kCFAllocatorDefault,parameterSetCount:2,
                    parameterSetPointers:ptrs.baseAddress!,parameterSetSizes:lengths.baseAddress!,nalUnitHeaderLength:4,formatDescriptionOut:&description)
            } }
        } }
        try VideoFrames.check(status,"Create H.264 SPS/PPS format")
        guard let description else { throw PhoneCamError.message("H.264 format missing.") }
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        guard dimensions.width > 0, dimensions.height > 0, dimensions.width <= 8192, dimensions.height <= 8192,
              Int64(dimensions.width)*Int64(dimensions.height) <= 33_554_432 else { throw PhoneCamError.message("H.264 SPS declares unsafe dimensions.") }
        var specification: [String: Any] = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String:true]
        if requireHardware { specification[kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder as String] = true }
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String:[:], kCVPixelBufferMetalCompatibilityKey as String:true
        ]
        var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { refcon, _, status, _, image, _, _ in
            guard let refcon else { return }
            let decoder = Unmanaged<H264Decoder>.fromOpaque(refcon).takeUnretainedValue()
            if status != noErr { decoder.decodeError.put(status); return }
            if let image { decoder.onFrame(image) }
        },decompressionOutputRefCon:Unmanaged.passUnretained(self).toOpaque())
        var created: VTDecompressionSession?
        try VideoFrames.check(VTDecompressionSessionCreate(allocator:kCFAllocatorDefault,formatDescription:description,
            decoderSpecification:specification as CFDictionary,imageBufferAttributes:attributes as CFDictionary,
            outputCallback:&callback,decompressionSessionOut:&created),"Create VideoToolbox decoder")
        guard let created else { throw PhoneCamError.message("VideoToolbox decoder missing.") }
        session = created; format = description; needsConfiguration = false
        _ = VTSessionSetProperty(created,key:kVTDecompressionPropertyKey_RealTime,value:kCFBooleanTrue)
        var hardware: Unmanaged<CFTypeRef>?
        _ = VTSessionCopyProperty(created,key:kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,allocator:kCFAllocatorDefault,valueOut:&hardware)
        let accelerated = (hardware?.takeRetainedValue() as? NSNumber)?.boolValue ?? false
        log("H.264 decoder: \(accelerated ? "hardware" : "software fallback"), \(dimensions.width)x\(dimensions.height).")
        if requireHardware && !accelerated { throw PhoneCamError.message("Hardware decoding was required but is unavailable.") }
    }
    func consume(header: PacketHeader, payload: Data) throws {
        let nals = try AnnexB.nalUnits(payload)
        var media: [Data] = []
        var hasVCL = false, hasIDR = header.isKeyFrame
        for nal in nals {
            let kind = nal[nal.startIndex] & 0x1f
            switch kind {
            case 7: if sps != nal { sps = nal; needsConfiguration = true; waitingForIDR = true }
            case 8: if pps != nal { pps = nal; needsConfiguration = true; waitingForIDR = true }
            default:
                if (1...5).contains(kind) { hasVCL = true }; if kind == 5 { hasIDR = true }
                if kind != 9 { media.append(nal) }
            }
        }
        if header.isConfiguration || !hasVCL { return }
        if waitingForIDR && !hasIDR { return }
        if needsConfiguration || session == nil { try createSession() }
        waitingForIDR = false
        guard let session, let format else { throw PhoneCamError.message("H.264 session is not ready.") }
        let bytes = try AnnexB.avcc(media)
        var block: CMBlockBuffer?
        try VideoFrames.check(CMBlockBufferCreateWithMemoryBlock(allocator:kCFAllocatorDefault,memoryBlock:nil,
            blockLength:bytes.count,blockAllocator:kCFAllocatorDefault,customBlockSource:nil,offsetToData:0,
            dataLength:bytes.count,flags:0,blockBufferOut:&block),"Allocate H.264 packet")
        guard let block else { throw PhoneCamError.message("H.264 packet buffer missing.") }
        try bytes.withUnsafeBytes { p in try VideoFrames.check(CMBlockBufferReplaceDataBytes(with:p.baseAddress!,blockBuffer:block,offsetIntoDestination:0,dataLength:bytes.count),"Copy H.264 packet") }
        var timing = CMSampleTimingInfo(duration:.invalid,presentationTimeStamp:CMTime(value:Int64(header.presentationTimeMicroseconds),timescale:1_000_000),decodeTimeStamp:.invalid)
        var length = bytes.count
        var sample: CMSampleBuffer?
        try VideoFrames.check(CMSampleBufferCreateReady(allocator:kCFAllocatorDefault,dataBuffer:block,formatDescription:format,
            sampleCount:1,sampleTimingEntryCount:1,sampleTimingArray:&timing,sampleSizeEntryCount:1,sampleSizeArray:&length,sampleBufferOut:&sample),"Create H.264 sample")
        guard let sample else { throw PhoneCamError.message("H.264 sample missing.") }
        // No async flag: avoid an unbounded queue of submitted decode jobs. Output goes to a one-frame mailbox.
        try VideoFrames.check(VTDecompressionSessionDecodeFrame(session,sampleBuffer:sample,flags:[],frameRefcon:nil,infoFlagsOut:nil),"Decode H.264 frame")
        try VideoFrames.check(VTDecompressionSessionWaitForAsynchronousFrames(session),"Complete H.264 decode")
        if let error = decodeError.take() { throw PhoneCamError.message("VideoToolbox output error \(error).") }
    }
}
