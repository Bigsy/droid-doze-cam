import AppKit

private final class ZoomTrackingSlider: NSSlider {
    var isDragging = false
    var didFinishDragging: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        isDragging = true
        super.mouseDown(with: event)
        isDragging = false
        didFinishDragging?()
    }
}

/// Smooth phone zoom with a live, editable numeric value.
final class CameraZoomControl: NSControl, NSTextFieldDelegate {
    private let readout = NSTextField(frame: .zero)
    private let unit = NSTextField(labelWithString: "×")
    private let slider = ZoomTrackingSlider(value: 1, minValue: 1, maxValue: 4, target: nil, action: nil)
    private let numberFormat = NumberFormatter()
    var zoom: Double { min(slider.maxValue, max(slider.minValue, (slider.doubleValue * 10).rounded() / 10)) }
    override var intrinsicContentSize: NSSize { NSSize(width: 320, height: 24) }
    override var isEnabled: Bool { didSet { updateEnabled() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Phone zoom controls")
        setAccessibilityChildren([slider, readout])
        slider.target = self
        slider.action = #selector(changed)
        slider.isContinuous = true // Update the readout while dragging; commit only on release.
        slider.didFinishDragging = { [weak self] in
            guard let self else { return }
            self.slider.doubleValue = self.zoom
            self.updateReadout()
            self.sendAction(self.action, to: self.target)
        }
        slider.numberOfTickMarks = 0
        slider.allowsTickMarkValuesOnly = false
        slider.setAccessibilityLabel("Camera zoom")
        numberFormat.numberStyle = .decimal
        numberFormat.usesGroupingSeparator = false
        numberFormat.minimumFractionDigits = 1
        numberFormat.maximumFractionDigits = 1
        numberFormat.allowsFloats = true
        readout.formatter = numberFormat
        readout.delegate = self
        readout.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        readout.alignment = .right
        readout.setAccessibilityLabel("Exact camera zoom")
        unit.textColor = .secondaryLabelColor
        addSubview(slider)
        addSubview(readout)
        addSubview(unit)
        configure(minimum: 1, maximum: 4, selected: 1)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(minimum: Double, maximum: Double, selected: Double) {
        slider.minValue = minimum
        slider.maxValue = maximum
        slider.doubleValue = min(maximum, max(minimum, selected))
        numberFormat.minimum = NSNumber(value: minimum)
        numberFormat.maximum = NSNumber(value: maximum)
        readout.toolTip = "Enter a zoom from \(numberFormat.string(from: NSNumber(value: minimum)) ?? "")× to \(numberFormat.string(from: NSNumber(value: maximum)) ?? "")×. Press Return to apply."
        slider.doubleValue = zoom
        updateEnabled()
        updateReadout()
    }

    override func layout() {
        super.layout()
        slider.frame = NSRect(x: 0, y: 0, width: max(0, bounds.width - 88), height: 24)
        readout.frame = NSRect(x: bounds.width - 78, y: 1, width: 62, height: 22)
        unit.frame = NSRect(x: bounds.width - 14, y: 3, width: 14, height: 18)
    }

    private func updateEnabled() {
        let enabled = isEnabled && slider.maxValue > slider.minValue
        slider.isEnabled = enabled
        readout.isEnabled = enabled
    }

    private func updateReadout() {
        readout.doubleValue = zoom
        slider.setAccessibilityValueDescription("\(readout.stringValue) times")
    }

    @objc private func changed() {
        updateReadout()
        if !slider.isDragging { sendAction(action, to: target) }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let value = numberFormat.number(from: readout.stringValue)?.doubleValue,
              value.isFinite, (slider.minValue...slider.maxValue).contains(value) else {
            updateReadout()
            NSSound.beep()
            return
        }
        slider.doubleValue = value
        slider.doubleValue = zoom
        updateReadout()
        sendAction(action, to: target)
    }
}
