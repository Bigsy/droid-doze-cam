import Foundation
import XCTest
@testable import DroidDozeCamCore

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
        XCTAssertEqual(try Configuration.parse(["serve", "--source", "test"]).source, .test)
        XCTAssertThrowsError(try Configuration.parse(["serve", "--source", "uvc"]))
        XCTAssertThrowsError(try Configuration.parse(["serve", "--source", "test", "--serial", "USB123"]))
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
        first.write(CameraTransform(rotation: 0, mirror: false, backgroundBlur: true, blurRadius: 33))
        XCTAssertEqual(second.read().blurRadius, 33)
        firstDefaults.set(500, forKey: "camera.blurRadius")
        XCTAssertEqual(second.read().blurRadius, 24)
        let capture = CameraCaptureSettings(size: .qhd, fps: 60, bitrate: 40_000_000, facing: "front")
        first.writeCapture(capture)
        XCTAssertEqual(second.readCapture(), capture)
        let savedCamera = CameraCaptureSettings(size: .qhd, fps: 60, bitrate: 40_000_000, facing: "back", cameraID: "2")
        first.writeCapture(savedCamera, for: "PHONE_A")
        XCTAssertEqual(second.readCapture(for: "PHONE_A"), savedCamera)
        XCTAssertNil(second.readCapture(for: "PHONE_B").cameraID)
        XCTAssertEqual(second.readCapture(for: "PHONE_B").facing, "back")
        XCTAssertNil(second.readCapture().cameraID)
        let frontAuto = CameraCaptureSettings(size: .qhd, fps: 60, bitrate: 40_000_000, facing: "front")
        first.writeCapture(frontAuto, for: "PHONE_B")
        XCTAssertEqual(second.readCapture(for: "PHONE_B"), frontAuto)
        XCTAssertEqual(second.readCapture(for: "PHONE_A"), savedCamera)
        firstDefaults.set(45, forKey: "camera.rotation")
        XCTAssertEqual(second.read().rotation, 0)
    }
    func testKnownPhonesKeepTheLatestFirstWithoutDuplicates() {
        let suite = "DroidDozeCamTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CameraSettingsStore(defaults: defaults)
        XCTAssertEqual(store.knownPhones(), [])
        store.rememberPhone("PHONE_A")
        store.rememberPhone("PHONE_B")
        store.rememberPhone("PHONE_A")
        XCTAssertEqual(CameraSettingsStore(defaults: UserDefaults(suiteName: suite)!).knownPhones(), ["PHONE_A", "PHONE_B"])
        store.forgetPhones()
        XCTAssertEqual(store.knownPhones(), [])
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
    func testPacketFlags() throws { let h = try PacketHeader(data:packet((1<<61)|123,42)); XCTAssertTrue(h.isKeyFrame); XCTAssertFalse(h.isConfiguration); XCTAssertEqual(h.presentationTimeMicroseconds,123); XCTAssertEqual(h.size,42) }
    func testConfigPacket() throws { XCTAssertTrue(try PacketHeader(data:packet(1<<62,20)).isConfiguration) }
    func testInvalidPacketLengths() { for n: UInt32 in [0,UInt32.max,UInt32(Constants.maxPacketBytes+1)] { XCTAssertThrowsError(try PacketHeader(data:packet(0,n))) }; XCTAssertThrowsError(try PacketHeader(data:Data(repeating:0,count:11))) }
    func testVideoHeader() throws {
        let d = Data([0x68,0x32,0x36,0x34]); XCTAssertNoThrow(try StreamHeader(data:d))
        XCTAssertThrowsError(try StreamHeader(data:d + Data(repeating: 0, count: 8)))
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
    func testKnownPhonesAreFollowedInOrder() throws {
        let both = ADBDevice.parse(text + "\nOTHER device usb:3-4 model:Galaxy")
        XCTAssertEqual(try ADBDevice.select(both, known: ["OTHER", "USB123"]).serial, "OTHER")
        XCTAssertEqual(try ADBDevice.select(both, known: ["USB123", "OTHER"]).serial, "USB123")
        XCTAssertEqual(try ADBDevice.select(ADBDevice.parse(text), known: ["OTHER", "USB123"]).serial, "USB123")
    }
    func testAPhoneThatWasNeverSetUpIsRefused() {
        XCTAssertThrowsError(try ADBDevice.select(ADBDevice.parse(text), known: ["OTHER"])) {
            XCTAssertTrue($0.localizedDescription.contains("has not been set up"), $0.localizedDescription)
        }
        XCTAssertThrowsError(try ADBDevice.select(ADBDevice.parse(text), known: ["USB999"])) {
            XCTAssertTrue($0.localizedDescription.contains("unauthorized"), $0.localizedDescription)
        }
        XCTAssertThrowsError(try ADBDevice.select(ADBDevice.parse(text), known: ["192.168.1.2:5555"]))
        XCTAssertThrowsError(try ADBDevice.select([], known: ["USB123"]))
    }
    func testWithoutKnownPhonesTheOnlyAuthorizedPhoneIsUsed() throws {
        XCTAssertEqual(try ADBDevice.select(ADBDevice.parse(text), known: []).serial, "USB123")
    }
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

final class OnDemandPolicyTests: XCTestCase {
    let hd = CameraCaptureSettings(size: .hd, fps: 30, bitrate: 8_000_000, facing: "back")
    let fullHD = CameraCaptureSettings.standard
    private func running(_ settings: CameraCaptureSettings) -> OnDemandPolicy {
        var policy = OnDemandPolicy()
        XCTAssertEqual(policy.update(now: 0, wanted: true, desired: settings, sessionFinished: false), [.start])
        policy.started(settings)
        return policy
    }

    func testStartsOnlyWhileAMacAppWantsTheCamera() {
        var policy = OnDemandPolicy()
        XCTAssertEqual(policy.update(now: 0, wanted: false, desired: hd, sessionFinished: false), [])
        XCTAssertEqual(policy.update(now: 0.2, wanted: true, desired: hd, sessionFinished: false), [.start])
        policy.started(hd)
        XCTAssertEqual(policy.update(now: 0.4, wanted: true, desired: hd, sessionFinished: false), [])
    }
    func testClosingTheCameraStopsOnceThenDarkensTheScreen() {
        var policy = running(hd)
        XCTAssertEqual(policy.update(now: 1, wanted: false, desired: hd, sessionFinished: false), [.stop("Mac camera closed; stopping USB capture.")])
        XCTAssertEqual(policy.update(now: 1.2, wanted: false, desired: fullHD, sessionFinished: false), [])
        XCTAssertEqual(policy.update(now: 1.4, wanted: false, desired: hd, sessionFinished: true), [.sleepPhoneScreen])
        XCTAssertFalse(policy.hasSession)
        XCTAssertEqual(policy.update(now: 1.6, wanted: true, desired: hd, sessionFinished: false), [.start])
    }
    func testReopeningBeforeTheStopFinishesStartsAgainStraightAway() {
        var policy = running(hd)
        _ = policy.update(now: 1, wanted: false, desired: hd, sessionFinished: false)
        XCTAssertEqual(policy.update(now: 1.2, wanted: true, desired: hd, sessionFinished: true), [.sleepPhoneScreen, .start])
    }
    func testSettingsChangeRestartsWithoutDarkeningTheScreen() {
        var policy = running(hd)
        XCTAssertEqual(policy.update(now: 1, wanted: true, desired: fullHD, sessionFinished: false), [.stop("Capture settings changed; restarting the USB stream.")])
        XCTAssertEqual(policy.update(now: 1.2, wanted: true, desired: fullHD, sessionFinished: false), [])
        XCTAssertEqual(policy.update(now: 1.4, wanted: true, desired: fullHD, sessionFinished: true), [.start])
    }
    func testClosingDuringASettingsRestartStillDarkensTheScreen() {
        var policy = running(hd)
        _ = policy.update(now: 1, wanted: true, desired: fullHD, sessionFinished: false)
        XCTAssertEqual(policy.update(now: 1.2, wanted: false, desired: fullHD, sessionFinished: false), [])
        XCTAssertEqual(policy.update(now: 1.4, wanted: false, desired: fullHD, sessionFinished: true), [.sleepPhoneScreen])
    }
    func testFailedSessionsAndStartsRetryAfterADelay() {
        var policy = running(hd)
        XCTAssertEqual(policy.update(now: 5, wanted: true, desired: hd, sessionFinished: true), [])
        XCTAssertEqual(policy.update(now: 6.9, wanted: true, desired: hd, sessionFinished: false), [])
        XCTAssertEqual(policy.update(now: 7, wanted: true, desired: hd, sessionFinished: false), [.start])
        policy.startFailed(now: 7)
        XCTAssertEqual(policy.update(now: 8, wanted: true, desired: hd, sessionFinished: false), [])
        XCTAssertEqual(policy.update(now: 9, wanted: true, desired: hd, sessionFinished: false), [.start])
    }
    func testSlowerAppsGetThirtyFramesPerSecond() {
        for requested in [30, 29.97, 25, 15] { XCTAssertEqual(fullHD.matching(requestedFPS: requested).fps, 30) }
        for requested in [60, 30.5, .nan, -1, nil] { XCTAssertEqual(fullHD.matching(requestedFPS: requested), fullHD) }
        XCTAssertEqual(fullHD.matching(requestedFPS: 30), CameraCaptureSettings(size: .fullHD, fps: 30, bitrate: 20_000_000, facing: "back"))
        let slow = CameraCaptureSettings(size: .hd, fps: 24, bitrate: 8_000_000, facing: "front")
        XCTAssertEqual(slow.matching(requestedFPS: 30), slow)
        let highSpeed = CameraCaptureSettings(size: .fullHD, fps: 120, bitrate: 20_000_000, facing: "back")
        XCTAssertEqual(highSpeed.matching(requestedFPS: 30).fps, 30)
        XCTAssertEqual(highSpeed.matching(requestedFPS: 60).fps, 120)
    }
    func testOnlyAFasterAppRestartsTheStream() {
        var policy = OnDemandPolicy()
        XCTAssertEqual(policy.update(now: 0, wanted: true, desired: fullHD, requestedFPS: 30, sessionFinished: false), [.start])
        policy.started(fullHD, fps: 30)
        XCTAssertEqual(policy.update(now: 0.2, wanted: true, desired: fullHD, requestedFPS: 30, sessionFinished: false), [])
        XCTAssertEqual(policy.update(now: 0.4, wanted: true, desired: fullHD, requestedFPS: nil, sessionFinished: false), [])
        XCTAssertEqual(policy.update(now: 0.6, wanted: true, desired: fullHD, requestedFPS: 60, sessionFinished: false),
                       [.stop("The Mac app asked for 60 fps; restarting the USB stream.")])
        XCTAssertEqual(policy.update(now: 0.8, wanted: true, desired: fullHD, requestedFPS: 60, sessionFinished: true), [.start])
        policy.started(fullHD, fps: 60)
        XCTAssertEqual(policy.update(now: 1, wanted: true, desired: fullHD, requestedFPS: 30, sessionFinished: false), [])
    }
    func testZoomAndTorchTakenByTheRunningSessionNeedNoRestart() {
        let zoomed = CameraCaptureSettings(size: .hd, fps: 30, bitrate: 8_000_000, facing: "back", cameraZoom: 2, cameraTorch: true)
        XCTAssertTrue(hd.sameExceptCameraControls(as: zoomed))
        XCTAssertFalse(hd.sameExceptCameraControls(as: fullHD))
        XCTAssertFalse(hd.sameExceptCameraControls(as: CameraCaptureSettings(size: .hd, fps: 30, bitrate: 8_000_000, facing: "front", cameraZoom: 2)))
        var policy = running(hd)
        XCTAssertEqual(policy.adjustableSettings, hd)
        policy.adjusted(to: zoomed)
        XCTAssertEqual(policy.update(now: 1, wanted: true, desired: zoomed, sessionFinished: false), [])
        // Without a control channel the same change restarts capture, and a stopping session takes no more changes.
        var restarting = running(hd)
        XCTAssertEqual(restarting.update(now: 1, wanted: true, desired: zoomed, sessionFinished: false),
                       [.stop("Capture settings changed; restarting the USB stream.")])
        XCTAssertNil(restarting.adjustableSettings)
        restarting.adjusted(to: zoomed)
        XCTAssertEqual(restarting.update(now: 1.2, wanted: true, desired: zoomed, sessionFinished: true), [.start])
        XCTAssertNil(OnDemandPolicy().adjustableSettings)
    }
    func testChangingZoomOrTorchKeepsTheRestOfTheCapture() {
        let saved = CameraCaptureSettings(size: .qhd, fps: 60, bitrate: 40_000_000, facing: "back", cameraID: "2",
                                          cameraSize: .fullHD, cameraZoom: 1.4, cameraTorch: false, videoEncoder: "c2.qti.avc.encoder")
        let zoomed = saved.withCameraControls(zoom: 3)
        XCTAssertEqual(zoomed.cameraZoom, 3)
        XCTAssertFalse(zoomed.cameraTorch)
        XCTAssertTrue(saved.sameExceptCameraControls(as: zoomed))
        let lit = zoomed.withCameraControls(torch: true)
        XCTAssertTrue(lit.cameraTorch)
        XCTAssertEqual(lit.cameraZoom, 3)
        XCTAssertEqual(lit.withCameraControls(zoom: 1.4, torch: false), saved)
    }
    func testForceBelongsToInstallExtension() throws {
        XCTAssertTrue(try Configuration.parse(["install-extension", "--force"]).force)
        XCTAssertFalse(try Configuration.parse(["install-extension"]).force)
        XCTAssertThrowsError(try Configuration.parse(["serve", "--force"]))
        XCTAssertThrowsError(try Configuration.parse(["install-extension", "--force=yes"]))
    }
}

final class FramePacerTests: XCTestCase {
    let period = 1.0 / 30
    private func afterAFrame(at time: Double) -> FramePacer {
        var pacer = FramePacer()
        XCTAssertEqual(pacer.frameArrived(now: time, period: period), .emit)
        pacer.emitted(now: time)
        return pacer
    }

    func testOnTimeFramesGoOutOnArrival() {
        var pacer = afterAFrame(at: 100)
        XCTAssertEqual(pacer.frameArrived(now: 100 + period, period: period), .emit)
        pacer.emitted(now: 100 + period)
        XCTAssertEqual(pacer.frameArrived(now: 100 + period * 1.8, period: period), .emit)
    }
    func testAnEarlyFrameWaitsForTheMinimumSpacingInsteadOfBeingSkipped() throws {
        var pacer = afterAFrame(at: 100)
        guard case .emitAfter(let delay) = pacer.frameArrived(now: 100 + period * 0.5, period: period) else {
            return XCTFail("An early frame must wait, not go out or be dropped.")
        }
        XCTAssertEqual(delay, period * 0.3, accuracy: 1e-9)
        XCTAssertTrue(pacer.delayEnded())
        XCTAssertFalse(pacer.delayEnded())
    }
    func testANewerFrameTakesTheWaitingFramesPlace() {
        var pacer = afterAFrame(at: 100)
        XCTAssertNotNil(pacer.frameArrived(now: 100 + period * 0.2, period: period))
        XCTAssertNil(pacer.frameArrived(now: 100 + period * 0.4, period: period))
        XCTAssertTrue(pacer.delayEnded())
    }
    func testAFrameSentMeanwhileEndsTheWait() {
        var pacer = afterAFrame(at: 100)
        XCTAssertNotNil(pacer.frameArrived(now: 100 + period * 0.7, period: period))
        pacer.emitted(now: 100 + period * 0.75)
        XCTAssertFalse(pacer.delayEnded())
        XCTAssertNotNil(pacer.frameArrived(now: 100 + period, period: period))
    }
    func testTheTimerRepeatsAQuietProducerAndSendsBlackAtTheFullRate() {
        let pacer = afterAFrame(at: 100)
        XCTAssertFalse(pacer.repeatDue(now: 100 + period * 1.4, period: period, hasFrame: true))
        XCTAssertTrue(pacer.repeatDue(now: 100 + period * 1.6, period: period, hasFrame: true))
        XCTAssertFalse(pacer.repeatDue(now: 100 + period * 0.7, period: period, hasFrame: false))
        XCTAssertTrue(pacer.repeatDue(now: 100 + period * 0.9, period: period, hasFrame: false))
    }
    /// Frames from the phone arrive up to 6 ms early or late. Driven the way the camera extension drives
    /// the pacer, every frame must reach the app, at least the minimum spacing apart and barely delayed.
    func testJitterNeitherSkipsNorBunchesFrames() {
        var pacer = FramePacer(), state: UInt64 = 42
        var waitingUntil: Double?, newest = -1, sent = -1, delivered = 0
        var lastEmit: Double?, smallestGap = Double.infinity, longestDelay = 0.0
        var arrivals: [Double] = []
        func emit(at time: Double) {
            if newest != sent { delivered += 1; longestDelay = max(longestDelay, time - arrivals[newest]) }
            if let lastEmit { smallestGap = min(smallestGap, time - lastEmit) }
            sent = newest; lastEmit = time; waitingUntil = nil
            pacer.emitted(now: time)
        }
        for frame in 0..<20_000 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let jitter = (Double(state >> 11) / Double(1 << 53) - 0.5) * 0.012
            let time = 100 + Double(frame) * period + jitter
            arrivals.append(time)
            if let due = waitingUntil, due <= time {
                waitingUntil = nil
                if pacer.delayEnded() { emit(at: due) }
            }
            newest = frame
            switch pacer.frameArrived(now: time, period: period) {
            case .emit: emit(at: time)
            case .emitAfter(let delay): waitingUntil = time + delay
            case nil: break
            }
        }
        XCTAssertGreaterThanOrEqual(delivered, arrivals.count - 1) // The last frame may still be waiting.
        XCTAssertGreaterThanOrEqual(smallestGap, period * FramePacer.minimumSpacing - 1e-9)
        XCTAssertLessThan(longestDelay, 0.012)
    }
}

final class ServiceStatusTests: XCTestCase {
    func testRoundTripAndOnlyTheOwnerRemovesIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = ServiceStatusFile(directory: directory)
        XCTAssertNil(file.read())
        let status = ServiceStatus(state: .streaming, detail: "SM_S918B", pid: 4242)
        try file.publish(status)
        XCTAssertEqual(file.read(), status)
        file.remove(ownedBy: 1)
        XCTAssertEqual(file.read(), status)
        file.remove(ownedBy: 4242)
        XCTAssertNil(file.read())
        try Data("not json".utf8).write(to: file.url)
        XCTAssertNil(file.read())
    }
    func testThePhoneInUseIsOptionalSoAnOlderStatusStillReads() throws {
        let older = try JSONDecoder().decode(ServiceStatus.self, from: Data(#"{"state":"idle","pid":3196,"detail":""}"#.utf8))
        XCTAssertEqual(older, ServiceStatus(state: .idle, detail: "", pid: 3196))
        XCTAssertNil(older.serial)
        let streaming = ServiceStatus(state: .streaming, detail: "SM_S918B", serial: "PHONE_A", pid: 7)
        XCTAssertEqual(try JSONDecoder().decode(ServiceStatus.self, from: JSONEncoder().encode(streaming)), streaming)
    }
}

final class LogRotationTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    func testRotatesTheFileTheDescriptorWritesTo() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("service.log").path
        // Opened the way launchd opens StandardErrorPath.
        let descriptor = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        XCTAssertEqual(write(descriptor, "0123456789", 10), 10)
        XCTAssertFalse(LogRotation.rotateIfNeeded(path: path, limit: 10, descriptors: [descriptor]))
        XCTAssertEqual(write(descriptor, "abc", 3), 3)
        XCTAssertTrue(LogRotation.rotateIfNeeded(path: path, limit: 10, descriptors: [descriptor]))
        XCTAssertEqual(write(descriptor, "new", 3), 3)
        XCTAssertEqual(try String(contentsOfFile: path + ".1", encoding: .utf8), "0123456789abc")
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "new")
    }
    func testLeavesALogItDoesNotWriteTo() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("service.log").path
        try Data(repeating: 65, count: 100).write(to: URL(fileURLWithPath: path))
        let other = open(directory.appendingPathComponent("other.log").path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        defer { close(other) }
        XCTAssertFalse(LogRotation.rotateIfNeeded(path: path, limit: 10, descriptors: [other]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + ".1"))
    }
}

#if os(macOS)
final class KernelCodeSignatureTests: XCTestCase {
    private func signature(of executable: String) throws -> KernelCodeSignature {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = ["10"]
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }
        return try XCTUnwrap(KernelCodeSignature(pid: process.processIdentifier))
    }
    func testPlatformBinaryIsNotDeveloperCode() throws {
        let s = try signature(of: "/bin/sleep")
        XCTAssertTrue(s.valid); XCTAssertEqual(s.identifier, "com.apple.sleep")
        XCTAssertEqual(s.validationCategory, 1)
        XCTAssertFalse(s.isAppleIssuedDeveloperCode)
    }
    func testAdHocSignatureCannotPassAsTheHostApp() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("sleep").path
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: copy)
        let codesign = try Process.run(URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["-f", "-s", "-", "-i", "com.hedworth.usbwakecam", copy])
        codesign.waitUntilExit()
        XCTAssertEqual(codesign.terminationStatus, 0)
        let s = try signature(of: copy)
        XCTAssertEqual(s.identifier, "com.hedworth.usbwakecam")
        XCTAssertNotNil(s.validationCategory)
        XCTAssertFalse(s.isAppleIssuedDeveloperCode)
    }
    func testMissingProcessHasNoSignature() { XCTAssertNil(KernelCodeSignature(pid: -1)); XCTAssertNil(KernelCodeSignature(pid: 999_999)) }
}
#endif
