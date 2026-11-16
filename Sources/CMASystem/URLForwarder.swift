import AppKit
import Carbon
import CMACore
import Foundation

public enum URLForwarderError: Error, Equatable {
    case invalidURL
    case sendFailed(String)
}

/// Delivers a `claude://` link to one specific Claude process with a GURL Apple Event.
public enum URLForwarder {
    public static func event(for url: URL, pid: pid_t) -> NSAppleEventDescriptor {
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        let e = NSAppleEventDescriptor(eventClass: AEEventClass(kInternetEventClass), eventID: AEEventID(kAEGetURL),
                                       targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID),
                                       transactionID: AETransactionID(kAnyTransactionID))
        e.setParam(NSAppleEventDescriptor(string: url.absoluteString), forKeyword: AEKeyword(keyDirectObject))
        return e
    }

    public static func forward(_ url: URL, toPID pid: pid_t, timeout: TimeInterval = 5) throws {
        guard LinkRouting.isValid(url) else { throw URLForwarderError.invalidURL }
        do {
            _ = try event(for: url, pid: pid).sendEvent(options: [.noReply], timeout: timeout)
        } catch {
            throw URLForwarderError.sendFailed(error.localizedDescription)
        }
    }

    /// The URL carried by an incoming kAEGetURL event, if valid.
    public static func url(fromGetURLEvent event: NSAppleEventDescriptor) -> URL? {
        guard let s = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let u = URL(string: s), LinkRouting.isValid(u) else { return nil }
        return u
    }
}
