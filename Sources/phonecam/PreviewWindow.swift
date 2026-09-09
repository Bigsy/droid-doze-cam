import Foundation
import AppKit
import AVFoundation
import CoreVideo
import PhoneCamCore
import PhoneCamMedia

/// A one-frame mailbox bounds producer-to-UI buffering even if the window is busy.
final class PreviewFrames: @unchecked Sendable {
    private let latest = LatestValue<CVPixelBuffer>()
    func put(_ pixel: CVPixelBuffer) { latest.put(pixel) }
    func take() -> CVPixelBuffer? { latest.take() }
    func clear() { latest.clear() }
}

@MainActor
final class PreviewWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let display = AVSampleBufferDisplayLayer()
    private let frames: PreviewFrames
    private let cancellation: Cancellation
    private let renderer: FrameRenderer
    private let fps: Int
    private var timer: Timer?
    private var lastArrival = ProcessInfo.processInfo.systemUptime
    private var displayedFrames: UInt64 = 0
    private var showingBlack = false

    init(configuration c: Configuration, frames: PreviewFrames, cancellation: Cancellation) throws {
        self.frames = frames; self.cancellation = cancellation; fps = c.fps
        renderer = try FrameRenderer(size:c.size)
        _ = try renderer.black()
        let width = min(960, c.size.width), height = Int(Double(width)*Double(c.size.height)/Double(c.size.width))
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:width,height:height),
                          styleMask:[.titled,.closable,.miniaturizable,.resizable], backing:.buffered, defer:false)
        super.init()
        window.title = "PhoneCam Live Preview"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentAspectRatio = NSSize(width:c.size.width,height:c.size.height)
        window.minSize = NSSize(width:320,height:200)
        let view = NSView(frame:NSRect(x:0,y:0,width:width,height:height))
        view.wantsLayer = true
        display.videoGravity = .resizeAspect
        display.backgroundColor = NSColor.black.cgColor
        view.layer = display
        window.contentView = view
        var timebase: CMTimebase?
        try VideoFrames.check(CMTimebaseCreateWithSourceClock(allocator:kCFAllocatorDefault,
            sourceClock:CMClockGetHostTimeClock(),timebaseOut:&timebase),"Create preview clock")
        guard let timebase else { throw PhoneCamError.message("Preview clock is unavailable.") }
        try VideoFrames.check(CMTimebaseSetTime(timebase,time:VideoFrames.now),"Set preview clock")
        try VideoFrames.check(CMTimebaseSetRate(timebase,rate:1),"Start preview clock")
        display.controlTimebase = timebase
    }

    func show() {
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps:true)
        let timer = Timer(timeInterval:1.0/Double(fps),target:self,selector:#selector(displayNext),userInfo:nil,repeats:true)
        self.timer = timer; RunLoop.main.add(timer,forMode:.common)
    }

    @objc private func displayNext() {
        guard !cancellation.isCancelled else { close(); return }
        let now = ProcessInfo.processInfo.systemUptime
        let pixel: CVPixelBuffer
        if let next = frames.take() {
            pixel = next; lastArrival = now; showingBlack = false
        } else if now-lastArrival > Constants.staleFrameSeconds && !showingBlack {
            do { pixel = try renderer.black(); showingBlack = true }
            catch { log("Preview: \(error.localizedDescription)"); cancellation.cancel(); return }
        } else { return }
        do {
            if display.status == .failed { display.flush() }
            guard display.isReadyForMoreMediaData else { return }
            let sample = try VideoFrames.sample(pixel,time:VideoFrames.now,fps:fps)
            display.enqueue(sample)
            if !showingBlack {
                displayedFrames &+= 1
                if displayedFrames == 1 { log("Preview received its first processed frame.") }
            }
        } catch { log("Preview: \(error.localizedDescription)"); cancellation.cancel() }
    }

    func close() {
        timer?.invalidate(); timer = nil
        frames.clear(); display.flushAndRemoveImage()
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate(); timer = nil
        frames.clear(); cancellation.cancel()
        log("Preview closed after \(displayedFrames) displayed frames.")
    }
}
