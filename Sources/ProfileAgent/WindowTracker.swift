import AppKit
import CoreGraphics

struct TrackedWindow: Equatable {
    let id: CGWindowID
    /// AppKit (bottom-left origin) global coordinates.
    let frame: CGRect
    let isFullScreen: Bool
}

/// Lists a pid's normal on-screen windows via CGWindowList (front to back).
@MainActor
enum WindowTracker {
    static func windows(pid: Int32) -> [TrackedWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let screens = NSScreen.screens
        let primaryHeight = screens.first?.frame.maxY ?? 0
        var out: [TrackedWindow] = []
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? Int32) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  ((info[kCGWindowAlpha as String] as? Double) ?? 0) > 0,
                  let num = info[kCGWindowNumber as String] as? UInt32,
                  let b = info[kCGWindowBounds as String] as? NSDictionary,
                  let cg = CGRect(dictionaryRepresentation: b),
                  cg.width >= 120, cg.height >= 80 else { continue }
            let frame = CGRect(x: cg.minX, y: primaryHeight - cg.maxY, width: cg.width, height: cg.height)
            let full = screens.contains { $0.frame.integral == frame.integral }
            out.append(TrackedWindow(id: num, frame: frame, isFullScreen: full))
        }
        return out
    }
}
