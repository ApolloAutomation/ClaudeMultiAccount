import Carbon
import CMACore
import Foundation

public enum HotKeyError: Error, Equatable {
    case noModifier
    case alreadyInUse
    case registrationFailed(Int32)
}

/// Global shortcuts via Carbon `RegisterEventHotKey`.
@MainActor
public final class HotKeyCenter {
    public static let shared = HotKeyCenter()
    nonisolated static let signature: OSType = 0x434D_416B // 'CMAk'
    nonisolated static let modifierMask = UInt32(cmdKey | optionKey | controlKey | shiftKey)

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: @MainActor () -> Void] = [:]
    private var idsByOwner: [UUID: UInt32] = [:]
    private var nextID: UInt32 = 1
    private var handlerRef: EventHandlerRef?

    public init() {}

    public nonisolated static func validate(_ spec: HotKeySpec) -> HotKeyError? {
        spec.modifiers & modifierMask == 0 ? .noModifier : nil
    }

    public func isRegistered(_ owner: UUID) -> Bool { idsByOwner[owner] != nil }

    /// Replaces any existing shortcut for `owner`.
    public func register(_ spec: HotKeySpec, for owner: UUID, handler: @escaping @MainActor () -> Void) throws {
        if let e = Self.validate(spec) { throw e }
        try installHandlerIfNeeded()
        unregister(owner)
        let id = nextID
        nextID &+= 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(spec.keyCode, spec.modifiers & Self.modifierMask,
                                         EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        if status == OSStatus(eventHotKeyExistsErr) { throw HotKeyError.alreadyInUse }
        guard status == noErr, let ref else { throw HotKeyError.registrationFailed(status) }
        refs[id] = ref
        handlers[id] = handler
        idsByOwner[owner] = id
    }

    public func unregister(_ owner: UUID) {
        guard let id = idsByOwner.removeValue(forKey: owner) else { return }
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        handlers[id] = nil
    }

    public func unregisterAll() {
        for owner in Array(idsByOwner.keys) { unregister(owner) }
    }

    func fire(_ id: UInt32) { handlers[id]?() }

    private func installHandlerIfNeeded() throws {
        guard handlerRef == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hk = EventHotKeyID()
            let s = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                      nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard s == noErr, hk.signature == HotKeyCenter.signature else { return OSStatus(eventNotHandledErr) }
            let id = hk.id
            MainActor.assumeIsolated { HotKeyCenter.shared.fire(id) }
            return noErr
        }, 1, &type, nil, &handlerRef)
        guard status == noErr else { throw HotKeyError.registrationFailed(status) }
    }
}
