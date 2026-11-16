import AppKit
import CMACore
import Foundation
import os

/// Reads and sets the default handler for a URL scheme.
public protocol URLSchemeRegistry: Sendable {
    func handler(forScheme scheme: String) -> URL?
    func setHandler(_ appURL: URL, forScheme scheme: String) async throws
}

public struct WorkspaceSchemeRegistry: URLSchemeRegistry {
    public init() {}
    public func handler(forScheme scheme: String) -> URL? {
        guard let probe = URL(string: "\(scheme)://") else { return nil }
        return NSWorkspace.shared.urlForApplication(toOpen: probe)
    }
    public func setHandler(_ appURL: URL, forScheme scheme: String) async throws {
        try await NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: scheme)
    }
}

/// Owns `claude://` while link routing is on. Claude Desktop re-registers itself on every launch,
/// so we watch its launches (plus wake and a 60 s safety net) and re-claim after a debounce, with backoff.
@MainActor
public final class LinkHandlerRegistration {
    public let registry: any URLSchemeRegistry
    public let ourAppURL: URL
    public let claudeAppURL: @MainActor () -> URL?
    public let debounce: Duration
    public let safetyInterval: Duration
    public private(set) var isEnabled = false
    public private(set) var reclaimCount = 0

    private let log = Logger(subsystem: AppPaths.bundleID, category: "links")
    private var observers: [NSObjectProtocol] = []
    private var pending: Task<Void, Never>?
    private var safetyTask: Task<Void, Never>?
    private var recentReclaims: [Date] = []
    private var backoff: Duration = .zero

    public init(registry: any URLSchemeRegistry = WorkspaceSchemeRegistry(), ourAppURL: URL = Bundle.main.bundleURL,
                claudeAppURL: @escaping @MainActor () -> URL?, debounce: Duration = .seconds(3), safetyInterval: Duration = .seconds(60)) {
        self.registry = registry; self.ourAppURL = ourAppURL; self.claudeAppURL = claudeAppURL
        self.debounce = debounce; self.safetyInterval = safetyInterval
    }

    public var isOurs: Bool { Self.same(registry.handler(forScheme: LinkRouting.scheme), ourAppURL) }

    static func same(_ a: URL?, _ b: URL) -> Bool {
        guard let a else { return false }
        return a.standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
            == b.standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
    }

    public func enable() async throws {
        guard !isEnabled else { return }
        isEnabled = true
        do {
            try await registry.setHandler(ourAppURL, forScheme: LinkRouting.scheme)
        } catch {
            isEnabled = false // nothing is being watched, so don't claim to be on
            throw error
        }
        startWatching()
    }

    /// Hands the scheme back to Claude once and stops watching.
    public func disable() async throws {
        isEnabled = false
        stopWatching()
        if isOurs, let claude = claudeAppURL() {
            try await registry.setHandler(claude, forScheme: LinkRouting.scheme)
        }
    }

    /// Re-claim now if someone else holds the scheme. Returns true if a re-claim happened.
    @discardableResult
    public func reclaimIfNeeded(now: Date = Date()) async -> Bool {
        guard isEnabled, !isOurs else { return false }
        recentReclaims = recentReclaims.filter { now.timeIntervalSince($0) < 600 } + [now]
        if recentReclaims.count > 5 {
            backoff = min(max(backoff * 2, .seconds(30)), .seconds(600))
            log.notice("claude:// re-claimed \(self.recentReclaims.count) times in 10 min; backing off")
        } else {
            backoff = .zero
        }
        do {
            try await registry.setHandler(ourAppURL, forScheme: LinkRouting.scheme)
            reclaimCount += 1
            log.info("re-claimed claude://")
            return true
        } catch {
            log.error("re-claim failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Debounced re-check (Claude registers itself shortly after launch). A check that is already pending is
    /// kept, never restarted: restarting on every tick would starve the check once debounce + backoff exceeds
    /// the safety interval.
    public func scheduleCheck() {
        guard isEnabled, pending == nil else { return }
        let delay = debounce + backoff
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.pending = nil
            await self?.reclaimIfNeeded()
        }
    }

    private func startWatching() {
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == AppPaths.claudeBundleID else { return }
            MainActor.assumeIsolated { self?.scheduleCheck() }
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleCheck() }
        })
        let interval = safetyInterval
        safetyTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                self?.scheduleCheck()
            }
        }
    }

    private func stopWatching() {
        for o in observers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        observers.removeAll()
        pending?.cancel(); pending = nil
        safetyTask?.cancel(); safetyTask = nil
    }
}
