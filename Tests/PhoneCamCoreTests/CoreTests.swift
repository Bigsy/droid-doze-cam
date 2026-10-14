import Foundation
import XCTest
@testable import PhoneCamCore

final class ConfigurationTests: XCTestCase {
    func testDefaults() throws { let c = try Configuration.parse(["run"]); XCTAssertEqual(c.source, .auto); XCTAssertEqual(c.size, .hd); XCTAssertEqual(c.fps, 30) }
    func testValidOptions() throws {
        let c = try Configuration.parse(["run","--source=android","--size","1920x1080","--fps","60","--bitrate","12M","--rotate","90","--mirror","--fit","fill","--no-reconnect","--duration","3.5"])
        XCTAssertEqual(c.bitrate,12_000_000); XCTAssertEqual(c.rotation,90); XCTAssertTrue(c.mirror); XCTAssertFalse(c.reconnect); XCTAssertEqual(c.duration,3.5)
    }
    func testHelpVersion() throws { XCTAssertEqual(try Configuration.parse([]).command,"help"); XCTAssertEqual(try Configuration.parse(["run","--help"]).command,"help"); XCTAssertEqual(try Configuration.parse(["--version"]).command,"version") }
    func testPreviewSyphonAndExtensionModesStayDistinct() throws {
        let preview = try Configuration.parse(["preview","--source","android","--syphon","--syphon-framework","/Applications/OBS.app/Contents/Frameworks/Syphon.framework"])
        XCTAssertEqual(preview.command,"preview"); XCTAssertTrue(preview.syphon)
        XCTAssertNotNil(preview.syphonFrameworkPath); XCTAssertNil(preview.duration)
        XCTAssertTrue(try Configuration.parse(["probe","--source","test","--syphon"]).syphon)
        XCTAssertFalse(try Configuration.parse(["run"]).syphon)
        for args in [["run","--syphon"],["doctor","--syphon"],
                     ["preview","--syphon-framework","/tmp/Syphon.framework"],["probe","--syphon=false"]] {
            XCTAssertThrowsError(try Configuration.parse(args),"Should reject \(args)")
        }
    }
    func testRejectBadArguments() {
        for args in [["wat"],["run","--fps","999"],["run","--size","1x2"],["run","--size","3840x2160","--fps","120"],["run","--duration","nan"],["run","--duration","inf"],["run","--bitrate","99999999999999999999999999M"],["run","--bitrate","0"],["run","--rotate","45"],["run","--zoom","0.5"],["run","--zoom","nan"],["run","--fps"],["run","--mirror=true"],["run","--fps","30","--fps","60"],["run","--camera-id","0","--facing","front"],["run","--camera-id","0;id"],["run","--unknown","a"],["status","--source","test"],["run","--source","uvc","--serial","a"],["run","--device","x","--serial","y"]] {
            XCTAssertThrowsError(try Configuration.parse(args),"Should reject \(args)")
        }
    }
    func testVideoSize() throws { XCTAssertEqual(try VideoSize("1280X720"),.hd); XCTAssertEqual(try VideoSize("2560x1440"),.qhd); XCTAssertThrowsError(try VideoSize("1279x720")); XCTAssertThrowsError(try VideoSize("1280x720x2")) }
    func testServeDefaultsToUSBAndRejectsPreviewOptions() throws {
        let c = try Configuration.parse(["serve", "--serial", "USB123"])
        XCTAssertEqual(c.source, .android); XCTAssertEqual(c.size, .fullHD); XCTAssertEqual(c.fps, 60)
        XCTAssertEqual(c.bitrate, 20_000_000)
        XCTAssertThrowsError(try Configuration.parse(["serve", "--syphon"]))
        XCTAssertThrowsError(try Configuration.parse(["probe", "--demand-dir", "/tmp"]))
    }
    func testTransformOverrides() throws {
        let inherited = try Configuration.parse(["serve"])
        XCTAssertFalse(inherited.rotationIsExplicit)
        XCTAssertFalse(inherited.mirrorIsExplicit)
        let overridden = try Configuration.parse(["serve", "--rotate", "0", "--no-mirror"])
        XCTAssertTrue(overridden.rotationIsExplicit)
        XCTAssertTrue(overridden.mirrorIsExplicit)
        XCTAssertFalse(overridden.mirror)
        XCTAssertThrowsError(try Configuration.parse(["serve", "--mirror", "--no-mirror"]))
        XCTAssertEqual(try Configuration.parse(["serve", "--zoom", "1.5"]).zoom, 1.5)
    }

    func testHighResolutionAndHighFrameRateModes() throws {
        XCTAssertEqual(try Configuration.parse(["serve", "--size", "2560x1440", "--fps", "60"]).captureSettings.size, .qhd)
        XCTAssertEqual(try Configuration.parse(["serve", "--size", "3840x2160", "--fps", "60"]).captureSettings.size, .ultraHD)
        XCTAssertEqual(try Configuration.parse(["serve", "--size", "1920x1080", "--fps", "120"]).captureSettings.fps, 120)
        XCTAssertEqual(VideoSize.supported.prefix(4), [.hd, .fullHD, .vga, .ultraHD])
        XCTAssertFalse(CameraCaptureSettings(size: .ultraHD, fps: 120, bitrate: 20_000_000, facing: "back").isSupported)
    }

    func testSavedCaptureRespectsExplicitOptions() throws {
        let saved = CameraCaptureSettings(size: .ultraHD, fps: 60, bitrate: 40_000_000, facing: "front", cameraID: "1")
        let inherited = try Configuration.parse(["serve"]).applyingSavedCapture(saved)
        XCTAssertEqual(inherited.captureSettings, saved)
        let override = try Configuration.parse(["serve", "--size", "1920x1080", "--fps", "120", "--facing", "back"])
            .applyingSavedCapture(saved)
        XCTAssertEqual(override.size, .fullHD)
        XCTAssertEqual(override.fps, 120)
        XCTAssertEqual(override.bitrate, 40_000_000)
        XCTAssertEqual(override.facing, "back")
        XCTAssertNil(override.cameraID)
        XCTAssertEqual(try Configuration.parse(["serve", "--camera-id", "2"]).applyingSavedCapture(saved).cameraID, "2")
        let highSpeed = CameraCaptureSettings(size: .fullHD, fps: 120, bitrate: 20_000_000, facing: "back")
        XCTAssertEqual(try Configuration.parse(["serve", "--size", "3840x2160"]).applyingSavedCapture(highSpeed).fps, 60)
        XCTAssertEqual(try Configuration.parse(["serve", "--fps", "120"]).applyingSavedCapture(saved).size, .fullHD)
    }
}

final class AndroidCameraInfoTests: XCTestCase {
    func testParsesPhoneReportedCameraIDsWithoutLensAssumptions() {
        let output = """
        List of cameras:
          --camera-id=0    (back, 4080x3060)
          --camera-id=1    (front, 4000x3000)
          --camera-id=2    (back, 4000x3000)
          --camera-id=3    (front, 3392x2544)
        """
        XCTAssertEqual(AndroidCameraInfo.parse(output).map { "\($0.facing):\($0.id)" },
                       ["back:0", "front:1", "back:2", "front:3"])
    }
}

final class CameraSettingsStoreTests: XCTestCase {
    func testSettingsPersistAcrossStoreInstances() {
        let suite = "DroidDozeCamTests.\(UUID().uuidString)"
        let firstDefaults = UserDefaults(suiteName: suite)!
        defer { firstDefaults.removePersistentDomain(forName: suite) }
        let first = CameraSettingsStore(defaults: firstDefaults)
        XCTAssertEqual(first.read(), CameraTransform(rotation: 0, mirror: false))
        first.write(CameraTransform(rotation: 270, mirror: true, fit: .fill, zoom: 1.5,
                                    backgroundBlur: true, blurRadius: 40))
        let second = CameraSettingsStore(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertEqual(second.read(), CameraTransform(rotation: 270, mirror: true, fit: .fill, zoom: 1.5,
                                                     backgroundBlur: true, blurRadius: 40))
        let capture = CameraCaptureSettings(size: .qhd, fps: 60, bitrate: 40_000_000, facing: "front")
        first.writeCapture(capture)
        XCTAssertEqual(second.readCapture(), capture)
        let phoneCamera = CameraCaptureSettings(size: .qhd, fps: 60, bitrate: 40_000_000, facing: "back", cameraID: "2")
        first.writeCapture(phoneCamera, for: "PHONE_A")
        XCTAssertEqual(second.readCapture(for: "PHONE_A"), phoneCamera)
        XCTAssertNil(second.readCapture(for: "PHONE_B").cameraID)
        XCTAssertEqual(second.readCapture(for: "PHONE_B").facing, "back")
        XCTAssertNil(second.readCapture().cameraID)
        let frontAuto = CameraCaptureSettings(size: .qhd, fps: 60, bitrate: 40_000_000, facing: "front")
        first.writeCapture(frontAuto, for: "PHONE_B")
        XCTAssertEqual(second.readCapture(for: "PHONE_B"), frontAuto)
        XCTAssertEqual(second.readCapture(for: "PHONE_A"), phoneCamera)
        firstDefaults.set(45, forKey: "camera.rotation")
        XCTAssertEqual(second.read().rotation, 0)
    }
}

final class CameraDemandTests: XCTestCase {
    func testLeaseExpiresAfterExtensionStopsOrCrashes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = CameraDemandFile(directory: directory)
        XCTAssertFalse(file.current())
        try file.publish(active: true)
        XCTAssertTrue(file.current())
        let active = try JSONDecoder().decode(CameraDemand.self, from: Data(contentsOf: file.url))
        XCTAssertFalse(file.current(at: active.updatedAt + 5))
        try file.publish(active: false)
        XCTAssertFalse(file.current())
    }
}
final class ProtocolTests: XCTestCase {
    private func packet(_ flags: UInt64, _ size: UInt32) -> Data { var f = flags.bigEndian; var s = size.bigEndian; var d = Data(bytes:&f,count:8); d.append(Data(bytes:&s,count:4)); return d }
    func testPacketFlags() throws { let h = try PacketHeader(data:packet((1<<62)|123,42)); XCTAssertTrue(h.isKeyFrame); XCTAssertFalse(h.isConfiguration); XCTAssertEqual(h.presentationTimeMicroseconds,123); XCTAssertEqual(h.size,42) }
    func testConfigPacket() throws { XCTAssertTrue(try PacketHeader(data:packet(1<<63,20)).isConfiguration) }
    func testInvalidPacketLengths() { for n: UInt32 in [0,UInt32.max,UInt32(Constants.maxPacketBytes+1)] { XCTAssertThrowsError(try PacketHeader(data:packet(0,n))) }; XCTAssertThrowsError(try PacketHeader(data:Data(repeating:0,count:11))) }
    func testVideoHeader() throws {
        let d = Data([0x68,0x32,0x36,0x34,0,0,5,0,0,0,2,0xd0]); let h = try StreamHeader(data:d); XCTAssertEqual(h.width,1280); XCTAssertEqual(h.height,720)
        var wrong = d; wrong[0] = 0; XCTAssertThrowsError(try StreamHeader(data:wrong))
    }
    func testAnnexBMultipleStartCodes() throws {
        let input = Data([0,0,0,1,0x67,0x42,0x80,0,0,1,0x68,0xaa,0x80,0,0,0,1,0x65,0xbb,0x80])
        let nals = try AnnexB.nalUnits(input); XCTAssertEqual(nals.count,3); XCTAssertEqual(nals[0],Data([0x67,0x42,0x80]))
        XCTAssertEqual(try AnnexB.avcc(nals).prefix(7), Data([0,0,0,3,0x67,0x42,0x80]))
    }
    func testMalformedAnnexB() { for d in [Data(),Data([1,2,3]),Data([0,0,1]),Data([0,0,1,0xff]),Data([9,0,0,1,0x67])] { XCTAssertThrowsError(try AnnexB.nalUnits(d)) } }
    func testUnalignedSlice() throws { let d = Data([9,0,0,0,5,8]); XCTAssertEqual(try d[1...4].bigEndianUInt32(at:0),5); XCTAssertThrowsError(try d.bigEndianUInt64(at:0)) }
    func testPacketBoundsFuzz() {
        var rng: UInt64 = 0x123456789abcdef
        for _ in 0..<3000 { rng = rng &* 6364136223846793005 &+ 1; let n = UInt32(truncatingIfNeeded: rng >> 32)
            if let h = try? PacketHeader(data:packet(rng,n)) { XCTAssertTrue((1...Constants.maxPacketBytes).contains(h.size)) }
        }
    }
}
final class StateTests: XCTestCase {
    func testMailbox() { let box = LatestValue<Int>(); box.put(1); box.put(2); XCTAssertEqual(box.take(),2); XCTAssertNil(box.take()); XCTAssertEqual(box.overwritten,1) }
    func testMailboxConcurrent() {
        let box = LatestValue<Int>(); DispatchQueue.concurrentPerform(iterations:10000) { box.put($0); _ = box.take() }; box.clear(); XCTAssertNil(box.take())
    }
    func testCancellation() { let c = Cancellation(); XCTAssertFalse(c.isCancelled); c.cancel(); XCTAssertTrue(c.isCancelled) }
    func testBackoff() { var b = RetryBackoff(); XCTAssertEqual((0..<7).map { _ in b.next() },[0.5,1,2,4,8,8,8]); b.reset(); XCTAssertEqual(b.next(),0.5) }
    func testClockReset() { var c = MonotonicClock(); XCTAssertEqual(c.next(hostNanoseconds:100),100); XCTAssertEqual(c.next(hostNanoseconds:99),101); XCTAssertEqual(c.next(hostNanoseconds:101),102) }
}
final class ADBTests: XCTestCase {
    let text = """
    List of devices attached
    USB123 device usb:1-2 product:test model:Pixel_8 device:shiba transport_id:1
    192.168.1.2:5555 device product:test model:Remote transport_id:2
    USB999 unauthorized usb:2-3 transport_id:3
    """
    func testSelection() throws { let devices = ADBDevice.parse(text); XCTAssertEqual(devices.count,3); XCTAssertEqual(try ADBDevice.select(devices,serial:nil).serial,"USB123") }
    func testRejectWireless() { XCTAssertThrowsError(try ADBDevice.select(ADBDevice.parse(text),serial:"192.168.1.2:5555")) }
    func testAuthorization() { XCTAssertThrowsError(try ADBDevice.select(ADBDevice.parse(text),serial:"USB999")) }
    func testAmbiguous() { XCTAssertThrowsError(try ADBDevice.select(ADBDevice.parse(text + "\nOTHER device usb:3-4 model:P"),serial:nil)) }
    func testEmpty() { XCTAssertThrowsError(try ADBDevice.select([],serial:nil)) }
}

final class SessionIDTests: XCTestCase {
    func testLeadingZerosMatchServerSocketName() throws {
        XCTAssertEqual(try ScrcpySessionID(1).hex, "00000001")
        XCTAssertEqual(try ScrcpySessionID(0xabcdef).socketName, "scrcpy_00abcdef")
    }
    func testSigned31BitBoundary() throws {
        XCTAssertEqual(try ScrcpySessionID(0x7fffffff).hex, "7fffffff")
        XCTAssertThrowsError(try ScrcpySessionID(0x80000000))
        XCTAssertThrowsError(try ScrcpySessionID(UInt32.max))
    }
}
