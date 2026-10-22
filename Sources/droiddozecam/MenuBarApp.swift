import AppKit
import DroidDozeCamCore

@MainActor
final class MenuBarApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let setup = CameraSetup()
    private lazy var settings = CameraSettingsWindow(setup: setup)
    private let serviceState = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let serviceDetail = NSMenuItem(title: "", action: nil, keyEquivalent: "")
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
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
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
    }

    /// Opening DroidDozeCam.app again while the menu runs.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings.show()
        return false
    }

    func menuNeedsUpdate(_ menu: NSMenu) { updateServiceStatus() }

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
private final class CameraSettingsWindow: NSObject {
    private struct CameraChoice {
        let title: String
        let facing: String
        let id: String?
    }
    private let store = CameraSettingsStore()
    private let setup: CameraSetup
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 520),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private let tabs = NSTabView(frame: .zero)
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

    init(setup: CameraSetup) {
        self.setup = setup
        super.init()
        window.title = "DroidDozeCam Settings"
        window.isReleasedWhenClosed = false
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
            "Saves automatically. Capture restarts briefly; zoom applies on release.")
        captureNote.textColor = .secondaryLabelColor
        frameRate.toolTip = "Maximum capture rate. Calls using 30 fps or less request 30 fps from the phone. 120 fps requires a supported high-speed mode; 4K supports up to 60 fps. Reported modes are not guaranteed."
        cameraSize.toolTip = "Resolution captured on the phone before scaling to the output size. Leave Automatic selected unless you need a specific mode."
        encoder.toolTip = "Leave Automatic selected unless you need to try another H.264 encoder."
        cameraZoom.toolTip = "Zoom on the phone before encoding. Lens switching depends on the phone. Release to apply."
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

        tabs.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -12),
            tabs.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 12),
            tabs.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -12)
        ])
    }

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
        // The service only reads choices saved for its phone, including while that phone is unplugged.
        let serial = CameraSetup.serviceSerial
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
        refreshReadiness()
        if setupTab { tabs.selectTabViewItem(withIdentifier: "Setup") }
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        loadCameraCapabilities(serial: serial)
    }

    /// Asking the phone for its cameras takes seconds, so it runs off the main thread.
    private func loadCameraCapabilities(serial: String?) {
        cameraLoad &+= 1
        let load = cameraLoad
        capabilities.isHidden = false
        capabilities.stringValue = "Reading phone capabilities…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try AndroidTools(Configuration()).cameras(serial: serial) }
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
        let lower = min(100, max(0.1, info?.minimumZoom ?? min(1, saved.cameraZoom)))
        let upper = max(lower, min(100, info?.maximumZoom ?? max(4, saved.cameraZoom)))
        cameraZoom.configure(minimum: lower, maximum: upper, selected: saved.cameraZoom)
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
