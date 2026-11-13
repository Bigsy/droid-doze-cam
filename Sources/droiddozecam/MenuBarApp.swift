import AppKit
import DroidDozeCamCore

@MainActor
final class MenuBarApp: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let setup = CameraSetup()
    private let updater = AppUpdater()
    private lazy var settings = CameraSettingsWindow(setup: setup, updater: updater)
    private let updateItem = NSMenuItem(title: "Check for Updates…", action: nil, keyEquivalent: "")
    private let serviceState = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let serviceDetail = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let mirrorItem = NSMenuItem(title: "Mirror", action: #selector(toggleMirror), keyEquivalent: "")
    private let blurItem = NSMenuItem(title: "Blur Background", action: #selector(toggleBlur), keyEquivalent: "")
    private let torchItem = NSMenuItem(title: "Torch", action: #selector(toggleTorch), keyEquivalent: "")
    private let zoomItem = NSMenuItem()
    private let zoomControl = CameraZoomControl(frame: NSRect(x: 72, y: 3, width: 216, height: 24))
    private let cameraItem = NSMenuItem(title: "Switch Front/Back Camera", action: #selector(switchCamera), keyEquivalent: "")
    private let store = CameraSettingsStore()
    /// The phone whose torch and zoom the menu shows. Finding the plugged-in phone lists USB devices,
    /// so it is refreshed in the background each time the menu opens.
    private var menuPhone = CameraSetup.knownPhones.first
    private let statusFile = ServiceStatusFile(directory: supportDirectory)
    private var statusTimer: Timer?

    override init() {
        super.init()
        let menu = NSMenu()
        let heading = NSMenuItem(title: "DroidDozeCam", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        serviceState.isEnabled = false
        serviceDetail.isEnabled = false
        menu.addItem(serviceState)
        menu.addItem(serviceDetail)
        menu.addItem(.separator())
        // Zoom is a slider in the menu, so the picture can be watched while it is dragged.
        let zoomRow = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 30))
        let zoomLabel = NSTextField(labelWithString: "Zoom")
        zoomLabel.font = .menuFont(ofSize: 0)
        zoomLabel.frame = NSRect(x: 21, y: 6, width: 48, height: 18)
        zoomControl.showReadoutOnly()
        zoomControl.target = self
        zoomControl.action = #selector(zoomChanged)
        zoomRow.addSubview(zoomLabel)
        zoomRow.addSubview(zoomControl)
        zoomItem.view = zoomRow
        for item in [mirrorItem, blurItem, torchItem, zoomItem, cameraItem] {
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        updateItem.target = updater
        updateItem.action = #selector(AppUpdater.checkForUpdates)
        menu.addItem(updateItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit DroidDozeCam", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        menu.delegate = self
        statusItem.menu = menu
        NSApplication.shared.delegate = self
        let timer = Timer(timeInterval: 2, target: self, selector: #selector(updateServiceStatus), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
        updateServiceStatus()
        settings.show(setupTab: setup.needsFirstRunSetup)
        updater.start()
    }

    /// Opening DroidDozeCam.app again while the menu runs.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings.show()
        return false
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateServiceStatus()
        let image = store.read()
        mirrorItem.state = image.mirror ? .on : .off
        blurItem.state = image.backgroundBlur ? .on : .off
        showPhoneControls()
        let status = statusFile.read()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let phone = CameraSetup.currentPhone(status)
            DispatchQueue.main.async { [weak self] in
                guard let self, phone != self.menuPhone else { return }
                self.menuPhone = phone
                self.showPhoneControls()
            }
        }
    }

    /// Torch and zoom are saved per phone and camera.
    private func showPhoneControls() {
        let saved = store.readCapture(for: menuPhone)
        torchItem.state = saved.cameraTorch ? .on : .off
        let range = settings.phoneZoomRange(for: menuPhone, saved: saved)
        zoomControl.configure(minimum: range.lowerBound, maximum: range.upperBound, selected: saved.cameraZoom)
        zoomControl.isEnabled = menuPhone != nil
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem === updateItem { return updater.canCheck }
        return menuItem !== torchItem || menuPhone != nil
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard updater.isInstalling else { return .terminateNow }
        do { try updater.maintenance.prepare(); return .terminateNow }
        catch {
            let alert = NSAlert()
            alert.messageText = "Update paused"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return .terminateCancel
        }
    }

    @objc private func toggleMirror() { writeImage(mirror: !store.read().mirror) }
    @objc private func toggleBlur() { writeImage(backgroundBlur: !store.read().backgroundBlur) }

    /// The running picture takes these within half a second.
    private func writeImage(mirror: Bool? = nil, backgroundBlur: Bool? = nil) {
        let old = store.read()
        store.write(CameraTransform(rotation: old.rotation, mirror: mirror ?? old.mirror, fit: old.fit, zoom: old.zoom,
                                    backgroundBlur: backgroundBlur ?? old.backgroundBlur, blurRadius: old.blurRadius))
        settings.reload()
    }

    /// A running picture takes torch and zoom without restarting; otherwise they apply when capture starts.
    @objc private func toggleTorch() { changeCapture { $0.withCameraControls(torch: !$0.cameraTorch) } }
    @objc private func zoomChanged() {
        let zoom = zoomControl.zoom
        changeCapture { $0.withCameraControls(zoom: zoom) }
    }

    /// Switching restarts capture. Source size, zoom and torch belong to a camera, so they are not carried over.
    @objc private func switchCamera() {
        changeCapture {
            CameraCaptureSettings(size: $0.size, fps: $0.fps, bitrate: $0.bitrate,
                                  facing: $0.facing == "front" ? "back" : "front", videoEncoder: $0.videoEncoder)
        }
    }

    /// Camera choices are saved per phone, and finding the plugged-in phone lists USB devices.
    private func changeCapture(_ change: @escaping @Sendable (CameraCaptureSettings) -> CameraCaptureSettings) {
        let status = statusFile.read()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let phone = CameraSetup.currentPhone(status)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.menuPhone = phone
                let changed = change(self.store.readCapture(for: phone))
                // Zoom, torch and a camera by ID are kept per phone, so they need one.
                guard changed.isSupported, phone != nil || changed.cameraID == nil else { return }
                self.store.writeCapture(changed, for: phone)
                self.settings.reload()
                self.showPhoneControls()
            }
        }
    }

    @objc private func updateServiceStatus() {
        let (title, detail, symbol) = describe(statusFile.read())
        serviceState.title = title
        serviceDetail.title = detail ?? ""
        serviceDetail.isHidden = detail == nil
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "DroidDozeCam: \(title)")
                ?? NSImage(systemSymbolName: "video", accessibilityDescription: "DroidDozeCam")
            button.toolTip = "DroidDozeCam: \(title)"
        }
    }

    private func describe(_ status: ServiceStatus?) -> (title: String, detail: String?, symbol: String) {
        // A status left by a service that has exited is stale.
        guard let status, kill(status.pid, 0) == 0 else {
            return setup.needsFirstRunSetup
                ? ("Camera not set up", "Open Settings to set it up.", "video.slash")
                : ("Camera service not running", "Settings → Setup can restart it.", "video.slash")
        }
        switch status.state {
        case .idle: return ("Ready for a Mac app", nil, "video")
        case .starting: return ("Starting \(status.detail)…", nil, "video.fill")
        case .streaming: return ("Streaming from \(status.detail)", nil, "video.fill")
        case .reconnecting: return ("Reconnecting to the phone…", status.detail, "video.badge.ellipsis")
        case .problem: return ("Camera in use, phone unavailable", status.detail, "exclamationmark.triangle")
        }
    }

    @objc private func openSettings() { settings.show() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}

@MainActor
private final class CameraSettingsWindow: NSObject, NSWindowDelegate {
    private let updater: AppUpdater
    private let automaticUpdates = NSButton(checkboxWithTitle: "Automatically check for updates", target: nil, action: nil)
    private let checkUpdates = NSButton(title: "Check for Updates…", target: nil, action: nil)
    private let updateDetail = NSTextField(wrappingLabelWithString: "")
    private struct CameraChoice {
        let title: String
        let facing: String
        let id: String?
    }
    private let store = CameraSettingsStore()
    private let setup: CameraSetup
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 548),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private let tabs = NSTabView(frame: .zero)
    private let showPreview = NSButton(checkboxWithTitle: "Show preview", target: nil, action: nil)
    private let preview = SettingsPreview(frame: .zero)
    private let previewHeight: NSLayoutConstraint
    private let readiness = NSStackView()
    private let setupHeading = NSTextField(labelWithString: "Checking setup…")
    private let setupGuidance = NSTextField(wrappingLabelWithString: "")
    private let sizes: [VideoSize] = [.vga, .hd, .fullHD, .qhd, .ultraHD]
    /// The phone whose camera choice is shown and saved: the service's phone, else the one plugged in.
    private var activeSerial: String?
    private var availableCameras: [AndroidCameraInfo] = []
    private var availableEncoders: [AndroidVideoEncoder] = []
    private var sourceSizes: [VideoSize?] = [nil]
    private let cameraSize = NSPopUpButton(frame: .zero, pullsDown: false)
    private let encoder = NSPopUpButton(frame: .zero, pullsDown: false)
    private let cameraZoom = CameraZoomControl(frame: .zero)
    private let torch = NSButton(checkboxWithTitle: "Torch", target: nil, action: nil)
    private let capabilities = NSTextField(wrappingLabelWithString: "Connect a phone to discover camera modes and encoders.")
    private var cameraLoad: UInt64 = 0
    private var readinessCheck: UInt64 = 0
    private var cameraChoices = [
        CameraChoice(title: "Back (automatic)", facing: "back", id: nil),
        CameraChoice(title: "Front (automatic)", facing: "front", id: nil),
        CameraChoice(title: "External (automatic)", facing: "external", id: nil)
    ]
    private let resolution = NSPopUpButton(frame: .zero, pullsDown: false)
    private let frameRate = NSPopUpButton(frame: .zero, pullsDown: false)
    private let bitrate = NSPopUpButton(frame: .zero, pullsDown: false)
    private let facing = NSPopUpButton(frame: .zero, pullsDown: false)
    private let rotation = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fit = NSPopUpButton(frame: .zero, pullsDown: false)
    private let zoom = NSPopUpButton(frame: .zero, pullsDown: false)
    private let mirror = NSButton(checkboxWithTitle: "Mirror horizontally", target: nil, action: nil)
    private let backgroundBlur = NSButton(checkboxWithTitle: "Blur background", target: nil, action: nil)
    private let blurStrength = NSSlider(value: 24, minValue: Double(CameraTransform.blurRadii.lowerBound),
                                        maxValue: Double(CameraTransform.blurRadii.upperBound), target: nil, action: nil)

    init(setup: CameraSetup, updater: AppUpdater) {
        self.setup = setup
        self.updater = updater
        previewHeight = preview.heightAnchor.constraint(equalToConstant: 0)
        super.init()
        window.title = "DroidDozeCam Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        setup.onStatusChanged = { [weak self] in self?.refreshReadiness() }

        for (index, title) in ["480p", "720p", "1080p", "1440p", "4K (experimental)"].enumerated() {
            resolution.addItem(withTitle: title)
            resolution.lastItem?.tag = index
        }
        for rate in CameraCaptureSettings.frameRates {
            frameRate.addItem(withTitle: rate == 120 ? "120 fps (experimental)" : "\(rate) fps")
            frameRate.lastItem?.tag = rate
        }
        for mbps in [4, 8, 12, 20, 40, 60] {
            bitrate.addItem(withTitle: "\(mbps) Mbps")
            bitrate.lastItem?.tag = mbps * 1_000_000
        }
        populateCameraChoices()
        for angle in [0, 90, 180, 270] {
            rotation.addItem(withTitle: "\(angle)° clockwise")
            rotation.lastItem?.tag = angle
        }
        fit.addItems(withTitles: ["Fit (black bars)", "Fill (crop)"])
        fit.item(at: 0)?.tag = 0
        fit.item(at: 1)?.tag = 1
        for factor in [1.0, 1.25, 1.5, 2.0, 3.0, 4.0] {
            zoom.addItem(withTitle: factor == 1 ? "1× (no crop)" : "\(factor)×")
            zoom.lastItem?.tag = Int(factor * 100)
        }

        for control in [resolution, frameRate, bitrate, facing, cameraSize, encoder] {
            control.target = self
            control.action = #selector(saveCapture)
        }
        cameraZoom.widthAnchor.constraint(equalToConstant: 320).isActive = true
        cameraZoom.target = self; cameraZoom.action = #selector(saveCapture)
        torch.target = self; torch.action = #selector(saveCapture)
        capabilities.textColor = .secondaryLabelColor
        blurStrength.isContinuous = true // The stream picks up the new strength within half a second.
        for control: NSControl in [rotation, fit, zoom, blurStrength] {
            control.target = self
            control.action = #selector(saveAppearance)
        }

        mirror.target = self
        mirror.action = #selector(saveAppearance)
        backgroundBlur.target = self
        backgroundBlur.action = #selector(saveAppearance)
        let captureTitle = heading("Capture")
        let captureRows = NSStackView(views: [
            row("Output size", resolution), row("Frame rate", frameRate),
            row("Bitrate", bitrate), row("Camera", facing), row("Source size", cameraSize),
            row("H.264 encoder", encoder), row("Camera zoom", cameraZoom), torch
        ])
        captureRows.orientation = .vertical
        captureRows.alignment = .leading
        captureRows.spacing = 9

        let appearanceTitle = heading("Image")
        let appearanceRows = NSStackView(views: [
            row("Rotation", rotation), row("Framing", fit), row("Mac crop", zoom),
            mirror, backgroundBlur, row("Blur strength", blurStrength)
        ])
        appearanceRows.orientation = .vertical
        appearanceRows.alignment = .leading
        appearanceRows.spacing = 9

        let captureNote = NSTextField(wrappingLabelWithString:
            "Saves automatically. Zoom and torch change on the running picture, zoom when released; other changes restart capture briefly.")
        captureNote.textColor = .secondaryLabelColor
        frameRate.toolTip = "Maximum capture rate. Calls using 30 fps or less request 30 fps from the phone. 120 fps requires a supported high-speed mode; 4K supports up to 60 fps. Reported modes are not guaranteed."
        cameraSize.toolTip = "Resolution captured on the phone before scaling to the output size. Leave Automatic selected unless you need a specific mode."
        encoder.toolTip = "Leave Automatic selected unless you need to try another H.264 encoder."
        cameraZoom.toolTip = "Zoom on the phone before encoding. Lens switching depends on the phone. Release to apply. A running picture zooms in steps of about 6%, so it can be slightly off until capture next starts."
        torch.toolTip = "Turns on the light if the selected phone camera supports it."
        addTab("Capture", views: [captureTitle, captureRows, capabilities, captureNote])

        let imageNote = NSTextField(wrappingLabelWithString:
            "Mac crop enlarges the received image. Camera zoom in Capture asks the phone to zoom before encoding; lens switching depends on the phone. Background blur runs on this Mac.")
        imageNote.textColor = .secondaryLabelColor
        addTab("Image", views: [appearanceTitle, appearanceRows, imageNote])

        setupHeading.font = .boldSystemFont(ofSize: 16)
        setupGuidance.textColor = .secondaryLabelColor
        readiness.orientation = .vertical
        readiness.alignment = .leading
        readiness.spacing = 12
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refreshReadiness))
        let setUp = NSButton(title: "Set Up Camera…", target: self, action: #selector(setUpCamera))
        let restartService = NSButton(title: "Restart Service", target: self, action: #selector(restartCameraService))
        let download = NSButton(title: "Download ADB…", target: self, action: #selector(downloadADB))
        let choose = NSButton(title: "Choose Existing…", target: self, action: #selector(chooseADB))
        let remove = NSButton(title: "Remove Camera Setup…", target: self, action: #selector(removeCameraSetup))
        let setupButtons = NSStackView(views: [setUp, refresh])
        setupButtons.spacing = 10
        let adbButtons = NSStackView(views: [download, choose])
        adbButtons.spacing = 10
        let maintenance = NSStackView(views: [restartService, remove])
        maintenance.spacing = 10
        let divider = NSBox()
        divider.boxType = .separator
        divider.widthAnchor.constraint(equalToConstant: 480).isActive = true
        addTab("Setup", views: [setupHeading, setupGuidance, readiness, setupButtons, divider,
                               heading("ADB on this Mac"), adbButtons, heading("Maintenance"), maintenance])

        checkUpdates.target = updater
        checkUpdates.action = #selector(AppUpdater.checkForUpdates)
        automaticUpdates.target = self
        automaticUpdates.action = #selector(toggleAutomaticUpdates)
        let releases = NSButton(title: "GitHub Releases", target: self, action: #selector(openReleases))
        let updateButtons = NSStackView(views: [checkUpdates, releases])
        updateButtons.spacing = 10
        updateDetail.textColor = .secondaryLabelColor
        addTab("Updates", views: [heading("DroidDozeCam \(Constants.version)"), updateButtons, automaticUpdates, updateDetail])
        updater.onChange = { [weak self] in self?.refreshUpdates() }
        refreshUpdates()

        showPreview.target = self
        showPreview.action = #selector(togglePreview)
        showPreview.toolTip = "Shows the picture Mac apps receive. The phone camera runs while this is ticked."
        preview.isHidden = true
        let content = window.contentView!
        for view: NSView in [showPreview, preview, tabs] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            showPreview.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            showPreview.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            preview.topAnchor.constraint(equalTo: showPreview.bottomAnchor, constant: 6),
            preview.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            preview.widthAnchor.constraint(equalTo: preview.heightAnchor, multiplier: 16.0 / 9.0),
            previewHeight,
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            tabs.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 6),
            tabs.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
    }

    private func refreshUpdates() {
        checkUpdates.isEnabled = updater.canCheck
        automaticUpdates.isEnabled = updater.unavailableReason == nil
        automaticUpdates.state = updater.automaticChecks ? .on : .off
        updateDetail.stringValue = updater.unavailableReason ?? "Checks daily when enabled. You choose when to install. Close the preview and stop using the camera before updating. Settings and downloaded ADB are retained."
    }

    @objc private func toggleAutomaticUpdates() { updater.setAutomaticChecks(automaticUpdates.state == .on) }
    @objc private func openReleases() { NSWorkspace.shared.open(URL(string: "https://github.com/Bigsy/droid-doze-cam/releases")!) }
    @objc private func togglePreview() { setPreview(showPreview.state == .on) }

    /// The window grows by the height of the picture and keeps its title bar where it is. The picture
    /// is as wide as the tabs when the screen has room, and smaller on a short screen.
    private func setPreview(_ shown: Bool) {
        let old = previewHeight.constant
        var height: CGFloat = 0
        if shown {
            let room = window.screen?.visibleFrame.height ?? .greatestFiniteMagnitude
            height = max(160, min(312, room - (window.frame.height - old)))
        }
        showPreview.state = shown ? .on : .off
        preview.isHidden = !shown
        previewHeight.constant = height
        var frame = window.frame
        frame.size.height += height - old
        frame.origin.y -= height - old
        if let visible = window.screen?.visibleFrame {
            frame.origin.y = max(frame.origin.y, min(visible.minY, visible.maxY - frame.height))
        }
        window.setFrame(frame, display: true)
        if shown { preview.start() } else { preview.stop() }
    }

    /// The phone camera must not keep running behind a closed window, and Settings opens without it.
    func windowWillClose(_ notification: Notification) { setPreview(false) }

    private func addTab(_ title: String, views: [NSView]) {
        let item = NSTabViewItem(identifier: title)
        item.label = title
        let content = NSView(frame: .zero)
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18)
        ])
        for view in views where view is NSTextField {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        item.view = content
        tabs.addTabViewItem(item)
    }

    private func heading(_ title: String) -> NSTextField {
        let field = NSTextField(labelWithString: title)
        field.font = .boldSystemFont(ofSize: 13)
        return field
    }

    private func row(_ title: String, _ control: NSControl) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 110).isActive = true
        let view = NSStackView(views: [label, control])
        view.orientation = .horizontal
        view.alignment = .centerY
        view.spacing = 16
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: 215).isActive = true
        return view
    }

    func show(setupTab: Bool = false) {
        loadControls()
        refreshReadiness()
        if setupTab { tabs.selectTabViewItem(withIdentifier: "Setup") }
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        loadCameraCapabilities()
    }

    /// Shows a change made from the menu bar.
    func reload() { loadControls() }

    /// The phone zoom range for the camera saved for `serial`: the phone's own once its cameras have
    /// been read, else wide enough for the saved ratio.
    func phoneZoomRange(for serial: String?, saved: CameraCaptureSettings) -> ClosedRange<Double> {
        let cameras = serial != nil && serial == activeSerial ? availableCameras : []
        let info = cameras.first { camera in saved.cameraID.map { camera.id == $0 } ?? (camera.facing == saved.facing) }
        return Self.zoomRange(info, saved: saved.cameraZoom)
    }

    private static func zoomRange(_ info: AndroidCameraInfo?, saved: Double) -> ClosedRange<Double> {
        let lower = min(100, max(0.1, info?.minimumZoom ?? min(1, saved)))
        let upper = max(lower, min(100, info?.maximumZoom ?? max(4, saved)))
        return lower...upper
    }

    private func loadControls() {
        // The service reads the choices saved for the phone it uses, including while that phone is unplugged.
        // Show the phone in use, else stay on the plugged-in phone found earlier, else the preferred phone.
        let known = CameraSetup.knownPhones
        let serial = CameraSetup.phoneInUse(ServiceStatusFile(directory: supportDirectory).read())
            ?? activeSerial.flatMap { known.contains($0) ? $0 : nil } ?? known.first
        if let serial, serial != activeSerial { activeSerial = serial; availableCameras = []; availableEncoders = [] }
        let savedCapture = store.readCapture(for: activeSerial)
        refreshCameraChoices(cameras: availableCameras, saved: savedCapture)
        resolution.selectItem(withTag: sizes.firstIndex(of: savedCapture.size) ?? 2)
        frameRate.selectItem(withTag: savedCapture.fps)
        bitrate.selectItem(withTag: savedCapture.bitrate)
        selectCamera(savedCapture)
        refreshPhoneControls(savedCapture)
        updateFrameRateAvailability()
        let appearance = store.read()
        rotation.selectItem(withTag: appearance.rotation)
        fit.selectItem(withTag: appearance.fit == .fill ? 1 : 0)
        zoom.selectItem(withTag: zoom.itemArray.min(by: {
            abs(Double($0.tag) / 100 - appearance.zoom) < abs(Double($1.tag) / 100 - appearance.zoom)
        })?.tag ?? 100)
        mirror.state = appearance.mirror ? .on : .off
        backgroundBlur.state = appearance.backgroundBlur ? .on : .off
        blurStrength.integerValue = appearance.blurRadius
        blurStrength.isEnabled = appearance.backgroundBlur
    }

    /// Asking the phone for its cameras takes seconds, so it runs off the main thread. The phone is the
    /// one the service is using, else the set-up phone that is plugged in.
    private func loadCameraCapabilities() {
        cameraLoad &+= 1
        let load = cameraLoad
        capabilities.isHidden = false
        capabilities.stringValue = "Reading phone capabilities…"
        let inUse = CameraSetup.phoneInUse(ServiceStatusFile(directory: supportDirectory).read())
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                let tools = try AndroidTools(Configuration())
                let serial = try inUse ?? ADBDevice.select(tools.devices(), known: CameraSetup.knownPhones).serial
                return try tools.cameras(serial: serial)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.cameraLoad == load else { return }
                switch result {
                case .success(let listing):
                    self.activeSerial = listing.device.serial
                    self.availableCameras = listing.cameras
                    self.availableEncoders = listing.encoders
                    let saved = self.store.readCapture(for: self.activeSerial)
                    self.refreshCameraChoices(cameras: listing.cameras, saved: saved)
                    self.selectCamera(saved)
                    self.refreshPhoneControls(saved)
                    self.updateFrameRateAvailability()
                case .failure:
                    self.capabilities.isHidden = false
                    self.capabilities.stringValue = "Phone unavailable. Check Setup to reconnect."
                }
            }
        }
    }

    private func selectCamera(_ saved: CameraCaptureSettings) {
        facing.selectItem(withTag: cameraChoices.firstIndex(where: {
            $0.id == saved.cameraID && $0.facing == saved.facing
        }) ?? 0)
    }

    @objc private func refreshReadiness() {
        readinessCheck &+= 1
        let check = readinessCheck
        setupHeading.stringValue = "Checking setup…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let report = CameraSetup.readiness()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.readinessCheck == check else { return }
                self.setupHeading.stringValue = report.ready ? "Ready for calls" : "Finish setup"
                self.setupGuidance.stringValue = report.guidance
                for view in self.readiness.arrangedSubviews {
                    self.readiness.removeArrangedSubview(view)
                    view.removeFromSuperview()
                }
                for item in report.items {
                    let icon = NSImageView(image: NSImage(systemSymbolName: item.ready ? "checkmark.circle.fill" : "circle", accessibilityDescription: item.ready ? "Ready" : "Needs attention")!)
                    icon.contentTintColor = item.ready ? .systemGreen : .secondaryLabelColor
                    icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
                    let name = NSTextField(labelWithString: item.name)
                    name.font = .systemFont(ofSize: 13, weight: .medium)
                    name.widthAnchor.constraint(equalToConstant: 70).isActive = true
                    let detail = NSTextField(wrappingLabelWithString: item.detail)
                    detail.textColor = .secondaryLabelColor
                    detail.widthAnchor.constraint(equalToConstant: 350).isActive = true
                    let line = NSStackView(views: [icon, name, detail])
                    line.spacing = 10
                    line.alignment = .centerY
                    self.readiness.addArrangedSubview(line)
                }
            }
        }
    }

    @objc private func setUpCamera() {
        setup.begin()
        refreshReadiness()
    }

    @objc private func restartCameraService() {
        setup.restartService()
        refreshReadiness()
    }

    @objc private func downloadADB() {
        setup.downloadADB()
        refreshReadiness()
    }

    @objc private func chooseADB() {
        setup.chooseADB()
        refreshReadiness()
    }

    @objc private func removeCameraSetup() {
        setup.remove()
        refreshReadiness()
    }

    private func populateCameraChoices() {
        facing.removeAllItems()
        for (index, choice) in cameraChoices.enumerated() {
            facing.addItem(withTitle: choice.title)
            facing.lastItem?.tag = index
        }
    }

    private func refreshCameraChoices(cameras: [AndroidCameraInfo], saved: CameraCaptureSettings) {
        cameraChoices = Array(cameraChoices.prefix(3))
        for camera in cameras {
            cameraChoices.append(CameraChoice(title: "\(camera.facing.capitalized) camera (ID \(camera.id))", facing: camera.facing, id: camera.id))
        }
        if let id = saved.cameraID, !cameraChoices.contains(where: { $0.id == id }) {
            cameraChoices.append(CameraChoice(title: "Saved camera (ID \(id))", facing: saved.facing, id: id))
        }
        populateCameraChoices()
    }

    private func cameraInfo() -> AndroidCameraInfo? {
        let choice = cameraChoices[facing.selectedItem?.tag ?? 0]
        return availableCameras.first { camera in
            if let id = choice.id { return camera.id == id }
            return camera.facing == choice.facing
        }
    }

    private func refreshPhoneControls(_ saved: CameraCaptureSettings) {
        let info = cameraInfo()
        sourceSizes = [nil]
        for mode in info?.modes ?? [] where !sourceSizes.contains(mode.size) { sourceSizes.append(mode.size) }
        if let savedSize = saved.cameraSize, !sourceSizes.contains(savedSize) { sourceSizes.append(savedSize) }
        cameraSize.removeAllItems()
        for (index, size) in sourceSizes.enumerated() {
            cameraSize.addItem(withTitle: size?.description ?? "Automatic (match output)")
            cameraSize.lastItem?.tag = index
        }
        cameraSize.selectItem(withTag: sourceSizes.firstIndex(of: saved.cameraSize) ?? 0)
        encoder.removeAllItems(); encoder.addItem(withTitle: "Automatic")
        for item in availableEncoders {
            encoder.addItem(withTitle: item.name + (item.hardware ? " (hardware)" : ""))
            encoder.lastItem?.representedObject = item.name
        }
        if let name = saved.videoEncoder {
            if let item = encoder.itemArray.first(where: { $0.representedObject as? String == name }) { encoder.select(item) }
            else { encoder.addItem(withTitle: name + " (saved)"); encoder.lastItem?.representedObject = name; encoder.select(encoder.lastItem) }
        }
        let range = Self.zoomRange(info, saved: saved.cameraZoom)
        cameraZoom.configure(minimum: range.lowerBound, maximum: range.upperBound, selected: saved.cameraZoom)
        torch.state = saved.cameraTorch ? .on : .off
        for control: NSControl in [cameraSize, encoder, cameraZoom, torch] { control.isEnabled = activeSerial != nil }
        capabilities.isHidden = info != nil
        capabilities.stringValue = "Connect your phone to load camera options."
    }

    private func updateFrameRateAvailability() {
        let output = sizes[resolution.selectedItem?.tag ?? 2]
        let selectedSource = sourceSizes[cameraSize.selectedItem?.tag ?? 0]
        let info = cameraInfo()
        frameRate.autoenablesItems = false
        for item in frameRate.itemArray {
            item.isEnabled = !(output == .ultraHD && item.tag > 60)
            let source = selectedSource ?? (item.tag > 60 ? output : nil)
            let reported = info?.reports(size: source, fps: item.tag)
            item.title = "\(item.tag) fps" + (reported == false ? " (not reported)" : item.tag > 60 ? " (high speed)" : "")
        }
        if output == .ultraHD && frameRate.selectedItem?.tag == 120 { frameRate.selectItem(withTag: 60) }
    }

    @objc private func saveCapture() {
        let camera = cameraChoices[facing.selectedItem?.tag ?? 0]
        let old = store.readCapture(for: activeSerial)
        if old.cameraID != camera.id || old.facing != camera.facing {
            // Source size, zoom and torch belong to this camera; don't carry them to a different lens.
            refreshPhoneControls(CameraCaptureSettings(size: old.size, fps: old.fps, bitrate: old.bitrate,
                facing: camera.facing, cameraID: camera.id, videoEncoder: old.videoEncoder))
        }
        updateFrameRateAvailability()
        let selected = CameraCaptureSettings(size: sizes[resolution.selectedItem?.tag ?? 2],
            fps: frameRate.selectedItem?.tag ?? 60,
            bitrate: bitrate.selectedItem?.tag ?? 20_000_000,
            facing: camera.facing, cameraID: camera.id,
            cameraSize: sourceSizes[cameraSize.selectedItem?.tag ?? 0],
            cameraZoom: cameraZoom.zoom, cameraTorch: torch.state == .on,
            videoEncoder: encoder.selectedItem?.representedObject as? String)
        store.writeCapture(selected, for: activeSerial)
    }

    @objc private func saveAppearance() {
        blurStrength.isEnabled = backgroundBlur.state == .on
        store.write(CameraTransform(rotation: rotation.selectedItem?.tag ?? 0,
                                    mirror: mirror.state == .on,
                                    fit: fit.selectedItem?.tag == 1 ? .fill : .fit,
                                    zoom: Double(zoom.selectedItem?.tag ?? 100) / 100,
                                    backgroundBlur: backgroundBlur.state == .on,
                                    blurRadius: blurStrength.integerValue))
    }
}
