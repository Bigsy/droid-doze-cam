import AppKit
@preconcurrency import AVFoundation
import DroidDozeCamCore

/// The live picture in Settings. It opens the DroidDozeCam camera the way a call app does, so the phone
/// starts through the login service and the picture is the one Mac apps receive.
@MainActor
final class SettingsPreview: NSView {
    private static let permissionHelp =
        "Camera access is off for DroidDozeCam. Allow it in System Settings, under Privacy & Security, Camera."
    private let video = AVCaptureVideoPreviewLayer()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let statusFile = ServiceStatusFile(directory: supportDirectory)
    private let sessionQueue = DispatchQueue(label: "DroidDozeCam.settings-preview", qos: .userInitiated)
    private var session: AVCaptureSession?
    private var errorObserver: NSObjectProtocol?
    private var statusTimer: Timer?
    /// Counts starts and stops, so a late permission answer or error cannot act on a newer preview.
    private var generation: UInt64 = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let picture = NSView(frame: bounds)
        video.videoGravity = .resizeAspect
        video.backgroundColor = NSColor.black.cgColor
        picture.layer = video
        picture.wantsLayer = true
        picture.autoresizingMask = [.width, .height]
        addSubview(picture)
        message.textColor = .white
        message.alignment = .center
        message.isHidden = true
        message.translatesAutoresizingMaskIntoConstraints = false
        addSubview(message)
        // Long text wraps instead of widening the label. The width is below required because the view
        // has no width while the preview is hidden.
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let width = message.widthAnchor.constraint(equalTo: widthAnchor, constant: -32)
        width.priority = NSLayoutConstraint.Priority(999)
        NSLayoutConstraint.activate([
            message.centerXAnchor.constraint(equalTo: centerXAnchor),
            message.centerYAnchor.constraint(equalTo: centerYAnchor),
            width
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Camera preview")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func start() {
        stop()
        let attempt = generation
        show("Starting the phone camera…")
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: open()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == attempt else { return }
                    if allowed { self.open() } else { self.show(Self.permissionHelp) }
                }
            }
        default: show(Self.permissionHelp)
        }
    }

    func stop() {
        generation &+= 1
        statusTimer?.invalidate(); statusTimer = nil
        if let errorObserver { NotificationCenter.default.removeObserver(errorObserver) }
        errorObserver = nil
        video.session = nil
        if let session {
            self.session = nil
            sessionQueue.async { session.stopRunning() }
        }
        show("")
    }

    private func open() {
        guard let device = NativeDevices.all().first(where: NativeDevices.isOurs) else {
            show("The \(Constants.cameraName) camera was not found. Finish the Setup tab. If you have just set it up, quit and reopen DroidDozeCam.")
            return
        }
        // Every Mac app using the camera shares its format and frame rate. The preview keeps the ones
        // already selected, so opening it during a call does not change the call's picture or the
        // frame rate the service asks the phone for.
        let format = device.activeFormat
        let durations = (device.activeVideoMinFrameDuration, device.activeVideoMaxFrameDuration)
        let session = AVCaptureSession()
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw DroidDozeCamError.message("the camera cannot be added.") }
            session.addInput(input)
        } catch {
            show("The preview could not start: \(error.localizedDescription)")
            return
        }
        video.session = session
        if let connection = video.connection, connection.isVideoMirroringSupported {
            // The picture as other people see it; the Mirror setting is already applied to it.
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        self.session = session
        let attempt = generation
        errorObserver = NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "Capture error."
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == attempt else { return }
                self.stop()
                self.show("The preview stopped. \(reason) Untick Show preview and tick it again.")
            }
        }
        sessionQueue.async {
            // On macOS a starting session picks a format for its preset unless the device is locked.
            let locked = (try? device.lockForConfiguration()) != nil
            if locked {
                func supported(_ duration: CMTime) -> Bool {
                    duration.isNumeric && format.videoSupportedFrameRateRanges.contains {
                        CMTimeCompare($0.minFrameDuration, duration) <= 0 && CMTimeCompare(duration, $0.maxFrameDuration) <= 0
                    }
                }
                device.activeFormat = format
                // An unsupported duration raises an exception.
                if supported(durations.0), supported(durations.1) {
                    device.activeVideoMinFrameDuration = durations.0
                    device.activeVideoMaxFrameDuration = durations.1
                }
            }
            session.startRunning()
            if locked { device.unlockForConfiguration() }
        }
        let timer = Timer(timeInterval: 0.5, target: self, selector: #selector(updateStatus), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
        updateStatus()
    }

    /// The picture is black until the phone sends frames, so say what the service is waiting for.
    @objc private func updateStatus() {
        guard session != nil else { return }
        guard let status = statusFile.read(), kill(status.pid, 0) == 0 else {
            show("The camera service is not running. Restart it in the Setup tab.")
            return
        }
        switch status.state {
        case .idle: show("Starting the phone camera…")
        case .starting: show("Starting \(status.detail)…")
        case .streaming: show("")
        case .reconnecting: show("Reconnecting to the phone…\n\(status.detail)")
        case .problem: show("Phone unavailable\n\(status.detail)")
        }
    }

    private func show(_ text: String) {
        message.stringValue = text
        message.isHidden = text.isEmpty
    }
}
