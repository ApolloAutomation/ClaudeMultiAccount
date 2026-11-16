import CMACore
import CoreAudio
import Foundation

/// Detects whether a Claude process is capturing audio, via CoreAudio per-process objects (polled).
public final class MicUsageMonitor: @unchecked Sendable {
    public let bundlePrefix: String
    public let interval: TimeInterval
    private let queue = DispatchQueue(label: "\(AppPaths.bundleID).mic")
    private var timer: DispatchSourceTimer?
    private var last: Bool?

    public init(bundlePrefix: String = AppPaths.claudeBundleID, interval: TimeInterval = 1) {
        self.bundlePrefix = bundlePrefix; self.interval = interval
    }

    /// Calls `onChange` (on a background queue) whenever Claude's mic use flips. Fires once with the initial state.
    public func start(onChange: @escaping @Sendable (Bool) -> Void) {
        queue.sync {
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: interval)
            t.setEventHandler { [weak self] in
                guard let self else { return }
                let now = Self.isUsingInput(bundlePrefix: self.bundlePrefix)
                if now != self.last { self.last = now; onChange(now) }
            }
            timer = t
            t.resume()
        }
    }

    public func stop() {
        queue.sync { timer?.cancel(); timer = nil; last = nil }
    }

    deinit { timer?.cancel() }

    public static func isUsingInput(bundlePrefix: String) -> Bool {
        processObjects().contains { obj in
            guard let id = bundleID(obj), id.hasPrefix(bundlePrefix) else { return false }
            return uint32(obj, kAudioProcessPropertyIsRunningInput) != 0
        }
    }

    static func processObjects() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func bundleID(_ obj: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let s = withUnsafeMutablePointer(to: &ref) { AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, $0) }
        guard s == noErr, let ref else { return nil }
        return ref.takeRetainedValue() as String
    }

    static func uint32(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &v) == noErr else { return 0 }
        return v
    }
}
