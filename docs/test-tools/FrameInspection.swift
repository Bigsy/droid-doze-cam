import Foundation
import CoreVideo
import PhoneCamCore
import PhoneCamMedia

@main
struct FrameInspection {
    static func main() throws {
        let configuration = try Configuration.parse(["probe", "--source", "android", "--require-hardware"])
        let renderer = try FrameRenderer(size: .hd)
        let cancellation = Cancellation()
        let lock = NSLock()
        var frames = 0, detailed = 0, maximum = 0
        var hashes = Set<UInt64>()
        var failure: Error?
        DispatchQueue.global().asyncAfter(deadline: .now()+15) { cancellation.cancel() }
        do {
            try AndroidCapture().run(configuration: configuration, cancellation: cancellation) { input in
                lock.lock(); defer { lock.unlock() }
                do {
                    let pixel = try renderer.convert(input)
                    CVPixelBufferLockBaseAddress(pixel, .readOnly)
                    defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
                    let bytes = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
                    let stride = CVPixelBufferGetBytesPerRow(pixel)
                    var low = 255, high = 0, hash: UInt64 = 14695981039346656037
                    for y in Swift.stride(from: 0, to: 720, by: 40) {
                        for x in Swift.stride(from: 0, to: 1280, by: 40) {
                            let offset = y*stride+x*4
                            let value = (Int(bytes[offset])+Int(bytes[offset+1])+Int(bytes[offset+2]))/3
                            low = min(low,value); high = max(high,value)
                            for component in 0..<3 { hash = (hash ^ UInt64(bytes[offset+component])) &* 1099511628211 }
                        }
                    }
                    frames += 1
                    if high-low >= 10 { detailed += 1 }
                    maximum = max(maximum,high)
                    hashes.insert(hash)
                    if frames >= 90 { cancellation.cancel() }
                } catch { failure = error; cancellation.cancel() }
            }
        } catch { if !cancellation.isCancelled { throw error } }
        if let failure { throw failure }
        let report: [String: Any] = ["framesInspected":frames,"framesWithSpatialDetail":detailed,
            "maximumSampledLuma":maximum,"distinctSampleHashes":hashes.count,
            "outputSize":"1280x720","savedCameraFrames":false,
            "passed":frames >= 30 && detailed > 0 && maximum > 20 && hashes.count > 1]
        let data = try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
        FileHandle.standardOutput.write(data); print("")
        if report["passed"] as? Bool != true { exit(1) }
    }
}
