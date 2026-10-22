import Foundation

/// Arguments passed directly to the pinned server, not scrcpy's desktop CLI.
public enum ScrcpyVideoOptions {
    public static func arguments(_ c: Configuration, session: ScrcpySessionID) throws -> [String] {
        guard c.captureSettings.isSupported else { throw DroidDozeCamError.message("Invalid Android capture settings.") }
        var result = [
            "scid=\(session.hex)", "log_level=warn", "video=true", "audio=false", "control=false",
            "video_source=camera", "video_codec=h264", "tunnel_forward=true",
            "send_dummy_byte=true", "send_device_meta=false", "send_stream_meta=true", "send_frame_meta=true",
            "video_bit_rate=\(c.bitrate)", "camera_fps=\(c.fps)", "cleanup=true",
            "camera_zoom=\(c.cameraZoom)", "camera_torch=\(c.cameraTorch)", "power_on=false", "clipboard_autosync=false",
            "video_codec_options=i-frame-interval=1,max-bframes=0"
        ]
        if let encoder = c.videoEncoder { result.append("video_encoder=\(encoder)") }
        if let id = c.cameraID { result.append("camera_id=\(id)") }
        else { result.append("camera_facing=\(c.facing)") }
        if c.fps > 60 { result.append("camera_high_speed=true") }
        if let size = c.androidSize { result.append("camera_size=\(size)") }
        else if c.fps > 60 { result.append("camera_size=\(c.size)") }
        else { result += ["max_size=\(c.size.width)", "camera_ar=\(c.size.width):\(c.size.height)"] }
        return result
    }
}
