import XCTest
import CoreMedia
import CoreVideo
import IOSurface
@testable import PhoneCamMedia
import PhoneCamCore

final class MediaTests: XCTestCase {
    private func rgb(_ pixel: CVPixelBuffer, x: Int, y: Int) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pixel, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        let bytes = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
        let offset = y * CVPixelBufferGetBytesPerRow(pixel) + x * 4
        return [bytes[offset + 2], bytes[offset + 1], bytes[offset]]
    }

    func testPatternContainsColorAndMotion() throws {
        let renderer = try FrameRenderer(size: .vga)
        let first = try renderer.testPattern(frame: 0), later = try renderer.testPattern(frame: 100)
        XCTAssertEqual(rgb(first, x: 40, y: 240), [255, 255, 255])
        XCTAssertEqual(rgb(first, x: 600, y: 240), [0, 0, 0])
        let firstColumn = (0..<480).map { rgb(first, x: 600, y: $0) }
        let laterColumn = (0..<480).map { rgb(later, x: 600, y: $0) }
        XCTAssertNotEqual(firstColumn, laterColumn)
    }

    func testMirrorSwapsPixelColumns() throws {
        let renderer = try FrameRenderer(size: .vga)
        let original = try renderer.testPattern(frame: 0)
        let mirrored = try renderer.convert(original, mirror: true)
        XCTAssertEqual(rgb(mirrored, x: 40, y: 240), rgb(original, x: 599, y: 240))
        XCTAssertEqual(rgb(mirrored, x: 599, y: 240), rgb(original, x: 40, y: 240))
        XCTAssertNotEqual(rgb(original, x: 40, y: 240), rgb(mirrored, x: 40, y: 240))
    }

    func testBlackFrameAndIOSurface() throws {
        let renderer = try FrameRenderer(size:.hd)
        let a = try renderer.black(), b = try renderer.black()
        XCTAssertEqual(CVPixelBufferGetWidth(a),1280); XCTAssertEqual(CVPixelBufferGetHeight(a),720)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(a),kCVPixelFormatType_32BGRA)
        XCTAssertNotNil(CVPixelBufferGetIOSurface(a)); XCTAssertTrue(a === b)
    }
    func testMatchingBufferPassThrough() throws {
        let renderer = try FrameRenderer(size:.hd), pixel = try renderer.black()
        XCTAssertTrue(pixel === (try renderer.convert(pixel)))
    }
    func testRotationMirrorAndResize() throws {
        let source = try FrameRenderer(size:.hd), destination = try FrameRenderer(size:.vga)
        let pattern = try source.testPattern(frame:17)
        for angle in [0,90,180,270] {
            let output = try destination.convert(pattern,rotation:angle,mirror:true,fit:.fill)
            XCTAssertEqual(CVPixelBufferGetWidth(output),640)
            XCTAssertEqual(CVPixelBufferGetHeight(output),480)
        }
    }
    func testSampleTimeAndFormat() throws {
        let renderer = try FrameRenderer(size:.hd), pixel = try renderer.black()
        let time = CMTime(value:123456789,timescale:1_000_000_000)
        let sample = try VideoFrames.sample(pixel,time:time,fps:30)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sample),time)
        XCTAssertEqual(CMSampleBufferGetDuration(sample),CMTime(value:1,timescale:30))
        XCTAssertNotNil(CMSampleBufferGetImageBuffer(sample))
        XCTAssertEqual(VideoFrames.nanoseconds(time),123456789)
    }
    func testBlackPixelContents() throws {
        let pixel = try FrameRenderer(size:.vga).black()
        CVPixelBufferLockBaseAddress(pixel,.readOnly); defer { CVPixelBufferUnlockBaseAddress(pixel,.readOnly) }
        let bytes = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to:UInt8.self)
        XCTAssertEqual(bytes[0],0); XCTAssertEqual(bytes[1],0); XCTAssertEqual(bytes[2],0); XCTAssertEqual(bytes[3],255)
    }
    func testPoolIsBounded() throws {
        let renderer = try FrameRenderer(size:.vga)
        var frames: [CVPixelBuffer] = []
        for i in 0..<8 { frames.append(try renderer.testPattern(frame:UInt64(i))) }
        XCTAssertThrowsError(try renderer.testPattern(frame:9))
        frames.removeAll()
        XCTAssertNoThrow(try renderer.testPattern(frame:10))
    }
}
