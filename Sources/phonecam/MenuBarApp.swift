import AppKit
import PhoneCamCore

@MainActor
final class MenuBarApp: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let settings = CameraSettingsWindow()
    private let setup = CameraSetup()

    override init() {
        super.init()
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "video", accessibilityDescription: "DroidDozeCam")
            button.toolTip = "DroidDozeCam"
        }
        let menu = NSMenu()
        let heading = NSMenuItem(title: "DroidDozeCam", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        menu.addItem(.separator())
        let readinessItem = NSMenuItem(title: "Camera Readiness…", action: #selector(openReadiness), keyEquivalent: "")
        readinessItem.target = self
        menu.addItem(readinessItem)
        let setupItem = NSMenuItem(title: "Set Up Camera…", action: #selector(setUpCamera), keyEquivalent: "")
        setupItem.target = self
        menu.addItem(setupItem)
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let removeItem = NSMenuItem(title: "Remove Camera Setup…", action: #selector(removeCameraSetup), keyEquivalent: "")
        removeItem.target = self
        menu.addItem(removeItem)
        let quitItem = NSMenuItem(title: "Quit DroidDozeCam", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
        settings.show()
        if setup.needsFirstRunSetup {
            DispatchQueue.main.async { [weak self] in self?.setup.showChecklist() }
        }
    }

    @objc private func openReadiness() { setup.showChecklist() }
    @objc private func openSettings() { settings.show() }
    @objc private func setUpCamera() { setup.begin() }
    @objc private func removeCameraSetup() { setup.remove() }
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
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 610),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private let sizes: [VideoSize] = [.vga, .hd, .fullHD, .qhd, .ultraHD]
    private var activeSerial: String?
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
    private let blurStrength = NSPopUpButton(frame: .zero, pullsDown: false)

    override init() {
        super.init()
        window.title = "DroidDozeCam Settings"
        window.isReleasedWhenClosed = false
        window.center()

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
        for (title, radius) in [("Light", 12), ("Medium", 24), ("Strong", 40)] {
            blurStrength.addItem(withTitle: title)
            blurStrength.lastItem?.tag = radius
        }

        for control in [resolution, frameRate, bitrate, facing] {
            control.target = self
            control.action = #selector(saveCapture)
        }
        for control in [rotation, fit, zoom, blurStrength] {
            control.target = self
            control.action = #selector(saveAppearance)
        }

        mirror.target = self
        mirror.action = #selector(saveAppearance)
        backgroundBlur.target = self
        backgroundBlur.action = #selector(saveAppearance)
        let captureTitle = heading("Android USB capture")
        let captureRows = NSStackView(views: [
            row("Resolution", resolution), row("Frame rate", frameRate),
            row("Bitrate", bitrate), row("Camera", facing)
        ])
        captureRows.orientation = .vertical
        captureRows.alignment = .leading
        captureRows.spacing = 9

        let appearanceTitle = heading("Image")
        let appearanceRows = NSStackView(views: [
            row("Rotation", rotation), row("Framing", fit), row("Zoom / crop", zoom),
            mirror, backgroundBlur, row("Blur strength", blurStrength)
        ])
        appearanceRows.orientation = .vertical
        appearanceRows.alignment = .leading
        appearanceRows.spacing = 9

        let note = NSTextField(wrappingLabelWithString:
            "Settings save automatically. Camera changes restart the stream. Zoom crops the centre of the image live; it does not switch phone lenses. Background blur runs on this Mac. 4K supports up to 60 fps; 120 fps needs a supported high-speed camera mode.")
        note.textColor = .secondaryLabelColor
        let content = NSStackView(views: [captureTitle, captureRows, appearanceTitle, appearanceRows, note])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            content.centerYAnchor.constraint(equalTo: window.contentView!.centerYAnchor),
            captureRows.widthAnchor.constraint(equalTo: content.widthAnchor),
            appearanceRows.widthAnchor.constraint(equalTo: content.widthAnchor),
            note.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
    }

    private func heading(_ title: String) -> NSTextField {
        let field = NSTextField(labelWithString: title)
        field.font = .boldSystemFont(ofSize: 13)
        return field
    }

    private func row(_ title: String, _ control: NSPopUpButton) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 110).isActive = true
        let view = NSStackView(views: [label, control])
        view.orientation = .horizontal
        view.alignment = .centerY
        view.spacing = 16
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: 215).isActive = true
        return view
    }

    func show() {
        let listing = try? AndroidTools(Configuration()).cameras()
        activeSerial = listing?.device.serial
        let savedCapture = store.readCapture(for: activeSerial)
        refreshCameraChoices(cameras: listing?.cameras ?? [], saved: savedCapture)
        resolution.selectItem(withTag: sizes.firstIndex(of: savedCapture.size) ?? 2)
        frameRate.selectItem(withTag: savedCapture.fps)
        bitrate.selectItem(withTag: savedCapture.bitrate)
        facing.selectItem(withTag: cameraChoices.firstIndex(where: {
            $0.id == savedCapture.cameraID && $0.facing == savedCapture.facing
        }) ?? 0)
        updateFrameRateAvailability()
        let appearance = store.read()
        rotation.selectItem(withTag: appearance.rotation)
        fit.selectItem(withTag: appearance.fit == .fill ? 1 : 0)
        zoom.selectItem(withTag: zoom.itemArray.min(by: {
            abs(Double($0.tag) / 100 - appearance.zoom) < abs(Double($1.tag) / 100 - appearance.zoom)
        })?.tag ?? 100)
        mirror.state = appearance.mirror ? .on : .off
        backgroundBlur.state = appearance.backgroundBlur ? .on : .off
        blurStrength.selectItem(withTag: appearance.blurRadius)
        blurStrength.isEnabled = appearance.backgroundBlur
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
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

    private func updateFrameRateAvailability() {
        let is4K = sizes[resolution.selectedItem?.tag ?? 2] == .ultraHD
        frameRate.itemArray.first(where: { $0.tag == 120 })?.isEnabled = !is4K
        if is4K && frameRate.selectedItem?.tag == 120 { frameRate.selectItem(withTag: 60) }
    }

    @objc private func saveCapture() {
        updateFrameRateAvailability()
        let camera = cameraChoices[facing.selectedItem?.tag ?? 0]
        let selected = CameraCaptureSettings(size: sizes[resolution.selectedItem?.tag ?? 2],
            fps: frameRate.selectedItem?.tag ?? 60,
            bitrate: bitrate.selectedItem?.tag ?? 20_000_000,
            facing: camera.facing, cameraID: camera.id)
        store.writeCapture(selected, for: activeSerial)
    }

    @objc private func saveAppearance() {
        blurStrength.isEnabled = backgroundBlur.state == .on
        store.write(CameraTransform(rotation: rotation.selectedItem?.tag ?? 0,
                                    mirror: mirror.state == .on,
                                    fit: fit.selectedItem?.tag == 1 ? .fill : .fit,
                                    zoom: Double(zoom.selectedItem?.tag ?? 100) / 100,
                                    backgroundBlur: backgroundBlur.state == .on,
                                    blurRadius: blurStrength.selectedItem?.tag ?? 24))
    }
}
