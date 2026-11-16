import AppKit
import CMACore
import QuartzCore

/// Colored, click-through border windows drawn over every normal window of one Claude pid.
@MainActor
final class BorderOverlayController {
    struct Style: Equatable {
        var show: Bool
        var color: ProfileColor
        var width: BorderWidth
    }

    private let pid: Int32
    private(set) var style: Style
    private var overlays: [CGWindowID: OverlayWindow] = [:]
    private var lastFrames: [CGWindowID: CGRect] = [:]
    private var lastChange: [CGWindowID: ContinuousClock.Instant] = [:]
    private var timer: Timer?
    private var interval: TimeInterval = 0
    static let cornerRadius: CGFloat = 16
    static let settleDelay: Duration = .milliseconds(150)

    init(pid: Int32, style: Style) {
        self.pid = pid
        self.style = style
    }

    func start() { schedule(1.0 / 30.0); tick() }

    func stop() {
        timer?.invalidate(); timer = nil
        overlays.values.forEach { $0.orderOut(nil) }
        overlays.removeAll(); lastFrames.removeAll(); lastChange.removeAll()
    }

    func update(style new: Style) {
        guard new != style else { return }
        style = new
        overlays.values.forEach { $0.apply(color: Self.nsColor(new.color), width: CGFloat(new.width.rawValue)) }
        tick()
    }

    static func nsColor(_ c: ProfileColor) -> NSColor {
        switch c {
        case .orange: .systemOrange
        case .blue: .systemBlue
        case .green: .systemGreen
        case .purple: .systemPurple
        case .pink: .systemPink
        case .red: .systemRed
        case .teal: .systemTeal
        case .gray: .systemGray
        }
    }

    private func schedule(_ seconds: TimeInterval) {
        guard seconds != interval || timer == nil else { return }
        interval = seconds
        timer?.invalidate()
        let t = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = seconds * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard style.show else {
            overlays.values.forEach { $0.orderOut(nil) }
            schedule(1.0 / 4.0)
            return
        }
        let now = ContinuousClock.now
        let windows = WindowTracker.windows(pid: pid)
        let live = Set(windows.map(\.id))
        for (id, w) in overlays where !live.contains(id) {
            w.orderOut(nil); overlays[id] = nil; lastFrames[id] = nil; lastChange[id] = nil
        }
        var moving = false
        for win in windows {
            if lastFrames[win.id] != win.frame {
                lastFrames[win.id] = win.frame
                lastChange[win.id] = now
            }
            let overlay = overlays[win.id] ?? {
                let o = OverlayWindow(color: Self.nsColor(style.color), width: CGFloat(style.width.rawValue))
                overlays[win.id] = o
                return o
            }()
            if let changed = lastChange[win.id], now - changed < Self.settleDelay {
                // Hide while the window is being dragged/resized; reshow once stable for 150 ms.
                moving = true
                if overlay.isVisible { overlay.orderOut(nil) }
                continue
            }
            overlay.place(frame: win.frame, radius: win.isFullScreen ? 0 : Self.cornerRadius)
            overlay.order(.above, relativeTo: Int(win.id))
        }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        schedule((front || moving) ? 1.0 / 30.0 : 1.0 / 4.0)
    }
}

/// Borderless, transparent, click-through window with a stroked rounded rect.
@MainActor
final class OverlayWindow: NSWindow {
    private let shape = CAShapeLayer()
    private var radius: CGFloat = -1

    init(color: NSColor, width: CGFloat) {
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .normal
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
        let view = NSView()
        view.wantsLayer = true
        view.layer?.addSublayer(shape)
        contentView = view
        shape.fillColor = nil
        apply(color: color, width: width)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func apply(color: NSColor, width: CGFloat) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shape.strokeColor = color.cgColor
        shape.lineWidth = width
        CATransaction.commit()
        radius = -1
        redraw()
    }

    func place(frame: CGRect, radius r: CGFloat) {
        let resized = frame.size != self.frame.size
        if frame != self.frame { setFrame(frame, display: false) }
        if resized || r != radius { radius = r; redraw() }
        if !isVisible { orderFront(nil) }
    }

    private func redraw() {
        guard let bounds = contentView?.bounds, bounds.width > 0 else { return }
        let inset = shape.lineWidth / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let r = max(0, max(radius, 0) - inset)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shape.frame = bounds
        shape.path = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        CATransaction.commit()
    }
}
