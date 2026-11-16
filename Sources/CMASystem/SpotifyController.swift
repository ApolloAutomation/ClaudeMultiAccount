import AppKit
import CMACore
import Foundation

/// Pauses/resumes Spotify through constant AppleScript sources. Never launches Spotify.
@MainActor
public final class SpotifyController {
    public static let bundleID = "com.spotify.client"
    static let stateSource = #"tell application id "com.spotify.client" to return (player state as string)"#
    static let pauseSource = #"tell application id "com.spotify.client" to pause"#
    static let playSource = #"tell application id "com.spotify.client" to play"#

    public init() {}

    public var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty }

    public func isPlaying() -> Bool {
        guard isRunning else { return false }
        return run(Self.stateSource)?.stringValue == "playing"
    }

    @discardableResult public func pause() -> Bool { isRunning && run(Self.pauseSource) != nil }
    @discardableResult public func play() -> Bool { isRunning && run(Self.playSource) != nil }

    private func run(_ source: String) -> NSAppleEventDescriptor? {
        var err: NSDictionary?
        let r = NSAppleScript(source: source)?.executeAndReturnError(&err)
        return err == nil ? r : nil
    }
}

/// Pauses Spotify while Claude uses the mic; resumes 1.5 s after the mic stops, only if we paused it.
@MainActor
public final class MusicPauseCoordinator {
    public let spotify: SpotifyController
    public let monitor: MicUsageMonitor
    public let resumeDelay: Duration
    public private(set) var pausedByUs = false
    private var resumeTask: Task<Void, Never>?
    private var micActive = false

    public init(spotify: SpotifyController = SpotifyController(), monitor: MicUsageMonitor = MicUsageMonitor(),
                resumeDelay: Duration = .milliseconds(1500)) {
        self.spotify = spotify; self.monitor = monitor; self.resumeDelay = resumeDelay
    }

    public func start() {
        monitor.start { [weak self] active in
            Task { @MainActor in self?.micChanged(active) }
        }
    }

    public func stop() {
        monitor.stop()
        resumeTask?.cancel()
        if pausedByUs { spotify.play(); pausedByUs = false }
    }

    public func micChanged(_ active: Bool) {
        micActive = active
        if active {
            resumeTask?.cancel(); resumeTask = nil
            if !pausedByUs, spotify.isPlaying(), spotify.pause() { pausedByUs = true }
        } else if pausedByUs {
            resumeTask?.cancel()
            let delay = resumeDelay
            resumeTask = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard let self, !Task.isCancelled, !self.micActive, self.pausedByUs else { return }
                self.spotify.play()
                self.pausedByUs = false
            }
        }
    }
}
