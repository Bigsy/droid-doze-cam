import Foundation
import XCTest
@testable import DroidDozeCamCore

final class ScrcpyProtocolTests: XCTestCase {
    // Byte fixtures follow scrcpy v5.0.1 Streamer.java, including a session resize mid-stream.
    func testSessionAndPacketRecordsStayAligned() throws {
        let session = Data([0x80,0,0,0, 0,0,7,0x80, 0,0,4,0x38])
        let config = Data([0x40,0,0,0,0,0,0,0, 0,0,0,2])
        let keyframe = Data([0x20,0,0,0,0,0,0,123, 0,0,0,3])
        let resize = Data([0x80,0,0,1, 0,0,5,0, 0,0,2,0xd0])
        let stream = session + config + Data([0x67,0x68]) + keyframe + Data([0x65,1,2]) + resize
        var offset = 0
        var sessions: [SessionHeader] = []
        var packets: [PacketHeader] = []
        while offset < stream.count {
            let record = try VideoRecordHeader(data: stream.subdata(in: offset..<offset+12))
            offset += 12
            switch record {
            case .session(let header): sessions.append(header)
            case .packet(let header): packets.append(header); offset += header.size
            }
        }
        XCTAssertEqual(offset, stream.count)
        XCTAssertEqual(sessions.map(\.width), [1920,1280])
        XCTAssertEqual(sessions.map(\.height), [1080,720])
        XCTAssertFalse(sessions[0].clientResize); XCTAssertTrue(sessions[1].clientResize)
        XCTAssertTrue(packets[0].isConfiguration); XCTAssertFalse(packets[0].isKeyFrame)
        XCTAssertTrue(packets[1].isKeyFrame); XCTAssertFalse(packets[1].isConfiguration)
        XCTAssertEqual(packets[1].presentationTimeMicroseconds,123)
        XCTAssertThrowsError(try PacketHeader(data:session))
    }

    func testRejectsInvalidSessionsAndDisabledStreams() {
        for bytes: [UInt8] in [
            [0x80,0,0,2, 0,0,5,0, 0,0,2,0xd0], // unknown flags
            [0x80,0,0,0, 0,0,0,0, 0,0,2,0xd0], // zero width
            [0x80,0,0,0, 0,0,0x20,1, 0,0,2,0xd0], // dimension > 8192
            [0x80,0,0,0, 0,0,0x20,0, 0,0,0x20,0], // unsafe total pixel count
            [0x80,0,0,0]
        ] { XCTAssertThrowsError(try VideoRecordHeader(data:Data(bytes))) }
        for bytes: [UInt8] in [[0,0,0,0], [0,0,0,1], [0x68,0x32,0x36,0x35], [0x68]] {
            XCTAssertThrowsError(try StreamHeader(data:Data(bytes)))
        }
    }
}

final class ScrcpyCapabilitiesTests: XCTestCase {
    func testParsesSizesRatesZoomAndEncoders() throws {
        let output = """
        [server] INFO: List of video encoders:
            --video-codec=h264 --video-encoder=c2.qti.avc.encoder (hw) [vendor]
            --video-codec=h264 --video-encoder=c2.android.avc.encoder (sw)
            --video-codec=h265 --video-encoder=c2.qti.hevc.encoder (hw)
        [server] INFO: List of cameras:
            --camera-id=0    (back, 4080x3060, fps={15, 30, 60}, zoom-range=[0.5, 10])
                - 1920x1080
                - 1280x720
              High speed capture (--camera-high-speed):
                - 1920x1080 (fps={120, 240})
            --camera-id=1    (front, 4000x3000, fps={30}, zoom-range=[1, 4])
                - 1280x720
            --camera-id=2    (back, 4000x3000, zoom-range=[0,5, 10])
                - 1x2
                - malformed
        """
        let cameras = AndroidCameraInfo.parse(output)
        XCTAssertEqual(cameras.count,3)
        let back = cameras[0]
        XCTAssertEqual(back.minimumZoom,0.5); XCTAssertEqual(back.maximumZoom,10)
        XCTAssertEqual(back.modes.count,3)
        XCTAssertEqual(back.reports(size:.fullHD,fps:120),true)
        XCTAssertEqual(back.reports(size:.hd,fps:120),false)
        XCTAssertEqual(back.reports(size:.hd,fps:60),true)
        XCTAssertEqual(back.reports(size:.ultraHD,fps:30),false)
        XCTAssertFalse(cameras[1].modes[0].highSpeed)
        XCTAssertEqual(cameras[1].modes[0].frameRates,[30])
        XCTAssertEqual(cameras[2].minimumZoom,0.5)
        XCTAssertTrue(cameras[2].modes.isEmpty)
        XCTAssertNil(cameras[2].reports(size:nil,fps:30))
        let encoders = AndroidVideoEncoder.parse(output)
        XCTAssertEqual(encoders.map(\.name),["c2.qti.avc.encoder","c2.android.avc.encoder"])
        XCTAssertEqual(encoders.map(\.hardware),[true,false])
    }

    func testMissingRatesAreUnknownAndMalformedEncodersIgnored() {
        let cameras = AndroidCameraInfo.parse("--camera-id=0 (back, 1920x1080)\n  - 1280x720")
        XCTAssertNil(cameras.first?.reports(size:.hd,fps:30))
        XCTAssertTrue(AndroidVideoEncoder.parse("--video-codec=h264 --video-encoder=bad;command").isEmpty)
        XCTAssertTrue(AndroidCameraInfo.parse("ERROR: No cameras available").isEmpty)
    }
}

final class ScrcpySettingsTests: XCTestCase {
    private let saved = CameraCaptureSettings(size:.fullHD, fps:60, bitrate:20_000_000, facing:"back", cameraID:"0",
        cameraSize:.qhd, cameraZoom:2.5, cameraTorch:true, videoEncoder:"c2.qti.avc.encoder")

    func testSavedOptionsAndExplicitResets() throws {
        XCTAssertEqual(try Configuration.parse(["serve"]).applyingSavedCapture(saved).captureSettings,saved)
        let front = CameraCaptureSettings(size:.fullHD,fps:60,bitrate:20_000_000,facing:"front",cameraID:"1",cameraZoom:2)
        XCTAssertEqual(try Configuration.parse(["serve","--camera-id","1"]).applyingSavedCapture(front).captureSettings,front)
        let reset = try Configuration.parse(["serve","--android-size","auto","--camera-zoom","1","--no-camera-torch","--video-encoder","auto"])
            .applyingSavedCapture(saved)
        XCTAssertNil(reset.androidSize); XCTAssertEqual(reset.cameraZoom,1)
        XCTAssertFalse(reset.cameraTorch); XCTAssertNil(reset.videoEncoder)
        let otherLens = try Configuration.parse(["serve","--camera-id","2"]).applyingSavedCapture(saved)
        XCTAssertNil(otherLens.androidSize); XCTAssertEqual(otherLens.cameraZoom,1); XCTAssertFalse(otherLens.cameraTorch)
        XCTAssertEqual(otherLens.videoEncoder,saved.videoEncoder)
        let testPattern = try Configuration.parse(["serve","--source","test"]).applyingSavedCapture(saved)
        XCTAssertNil(testPattern.androidSize); XCTAssertFalse(testPattern.cameraTorch); XCTAssertNil(testPattern.videoEncoder)
        let slower = saved.matching(requestedFPS:30)
        XCTAssertEqual(slower.fps,30); XCTAssertEqual(slower.cameraSize,saved.cameraSize)
        XCTAssertEqual(slower.cameraZoom,2.5); XCTAssertTrue(slower.cameraTorch)
        XCTAssertEqual(slower.videoEncoder,saved.videoEncoder)
    }

    func testPerPhoneControlsNeverLeakToAnotherPhone() {
        let suite = "DroidDozeCamTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        CameraSettingsStore(defaults:defaults).writeCapture(saved,for:"PHONE_A")
        let store = CameraSettingsStore(defaults:UserDefaults(suiteName:suite)!)
        XCTAssertEqual(store.readCapture(for:"PHONE_A"),saved)
        for serial: String? in [nil,"PHONE_B"] {
            let other = store.readCapture(for:serial)
            XCTAssertNil(other.cameraSize); XCTAssertEqual(other.cameraZoom,1)
            XCTAssertFalse(other.cameraTorch); XCTAssertNil(other.videoEncoder)
        }
    }

    func testNewOptionsRejectInvalidInputsAndNonAndroidSources() throws {
        XCTAssertEqual(try Configuration.parse(["preview","--camera-zoom","0.5"]).source,.android)
        XCTAssertTrue(try Configuration.parse(["cameras","--serial","USB123","--json"]).json)
        for options in [
            ["run","--camera-zoom","nan"], ["run","--camera-zoom","0"], ["run","--camera-zoom","101"],
            ["run","--video-encoder","bad;command"], ["run","--video-encoder",""],
            ["run","--camera-torch","--no-camera-torch"], ["run","--camera-torch=true"],
            ["run","--source","uvc","--camera-zoom","2"], ["serve","--source","test","--camera-torch"],
            ["run","--device","camera","--android-size","auto"], ["cameras","--fps","30"]
        ] { XCTAssertThrowsError(try Configuration.parse(options),"Should reject \(options)") }
    }

    func testPhoneSettingsRestartCapture() {
        for changed in [
            CameraCaptureSettings(size:.fullHD,fps:60,bitrate:20_000_000,facing:"back",cameraSize:.hd),
            CameraCaptureSettings(size:.fullHD,fps:60,bitrate:20_000_000,facing:"back",cameraZoom:2),
            CameraCaptureSettings(size:.fullHD,fps:60,bitrate:20_000_000,facing:"back",cameraTorch:true),
            CameraCaptureSettings(size:.fullHD,fps:60,bitrate:20_000_000,facing:"back",videoEncoder:"c2.qti.avc.encoder")
        ] {
            var policy = OnDemandPolicy()
            _ = policy.update(now:0,wanted:true,desired:.standard,sessionFinished:false)
            policy.started(.standard)
            XCTAssertEqual(policy.update(now:1,wanted:true,desired:changed,sessionFinished:false),
                [.stop("Capture settings changed; restarting the USB stream.")])
        }
    }
}

final class ScrcpyServerOptionsTests: XCTestCase {
    private func options(_ arguments: [String]) throws -> [String] {
        try ScrcpyVideoOptions.arguments(Configuration.parse(["preview"] + arguments),session:ScrcpySessionID(1))
    }

    func testCameraOnlyCaptureDoesNotEnableAudioControlOrWake() throws {
        let arguments = try options([])
        for value in ["video_source=camera","video_codec=h264","audio=false","control=false","power_on=false",
                      "clipboard_autosync=false","send_stream_meta=true","send_frame_meta=true","cleanup=true","scid=00000001"] {
            XCTAssertTrue(arguments.contains(value),value)
        }
        XCTAssertFalse(arguments.contains(where: { $0.hasPrefix("send_codec_meta=") }))
        XCTAssertTrue(try options(["--size","640x480"]).contains("camera_ar=640:480"))
    }

    func testExactAndHighSpeedModesExcludeAutomaticSizing() throws {
        let exact = try options(["--android-size","2560x1440","--camera-id","2","--camera-zoom","2.5","--camera-torch","--video-encoder","c2.qti.avc.encoder"])
        for value in ["camera_size=2560x1440","camera_id=2","camera_zoom=2.5","camera_torch=true","video_encoder=c2.qti.avc.encoder"] {
            XCTAssertTrue(exact.contains(value),value)
        }
        XCTAssertFalse(exact.contains(where: { $0.hasPrefix("camera_facing=") }))
        let highSpeed = try options(["--fps","120","--size","1920x1080"])
        XCTAssertTrue(highSpeed.contains("camera_high_speed=true")); XCTAssertTrue(highSpeed.contains("camera_size=1920x1080"))
        for arguments in [exact,highSpeed] {
            XCTAssertFalse(arguments.contains(where: { $0.hasPrefix("max_size=") || $0.hasPrefix("camera_ar=") }))
        }
    }
}
