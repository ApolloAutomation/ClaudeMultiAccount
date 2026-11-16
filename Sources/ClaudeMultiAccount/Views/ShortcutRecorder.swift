import SwiftUI
import AppKit
import Carbon.HIToolbox
import CMACore

/// Carbon modifier masks used by `HotKeySpec`.
enum CarbonModifier {
    static let command = UInt32(cmdKey)
    static let shift = UInt32(shiftKey)
    static let option = UInt32(optionKey)
    static let control = UInt32(controlKey)

    static func from(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= command }
        if flags.contains(.shift) { mask |= shift }
        if flags.contains(.option) { mask |= option }
        if flags.contains(.control) { mask |= control }
        return mask
    }
}

extension HotKeySpec {
    var displayString: String {
        var text = ""
        if modifiers & CarbonModifier.control != 0 { text += "⌃" }
        if modifiers & CarbonModifier.option != 0 { text += "⌥" }
        if modifiers & CarbonModifier.shift != 0 { text += "⇧" }
        if modifiers & CarbonModifier.command != 0 { text += "⌘" }
        return text + KeyNames.name(for: keyCode)
    }
}

enum KeyNames {
    private static let table: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
        kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
        kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
        kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
        kVK_F19: "F19", kVK_F20: "F20",
    ]

    static func name(for keyCode: UInt32) -> String {
        table[Int(keyCode)] ?? "Key \(keyCode)"
    }
}

/// Click to record, then press a key combination. Esc cancels, Delete clears.
/// Requires at least one of ⌘ ⌥ ⌃ so plain typing is never captured globally.
struct ShortcutRecorder: View {
    var shortcut: HotKeySpec?
    var onChange: (HotKeySpec?) -> Void

    @State private var recorder = RecorderMonitor()

    var body: some View {
        HStack(spacing: 6) {
            Button {
                recorder.isRecording ? recorder.stop() : recorder.start { onChange($0) }
            } label: {
                Text(label)
                    .monospacedDigit()
                    .frame(minWidth: 120)
                    .foregroundStyle(recorder.isRecording || shortcut == nil ? .secondary : .primary)
            }
            .buttonStyle(.bordered)
            .help(recorder.isRecording ? "Press Esc to cancel" : "Click and press a key combination")

            if shortcut != nil && !recorder.isRecording {
                Button {
                    onChange(nil)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove shortcut")
                .accessibilityLabel("Remove shortcut")
            }
        }
        .onDisappear { recorder.stop() }
        .overlay(alignment: .bottomLeading) {
            if let hint = recorder.hint {
                Text(hint).font(.caption).foregroundStyle(.orange).offset(y: 16)
            }
        }
    }

    private var label: String {
        if recorder.isRecording { return "Press keys…" }
        return shortcut?.displayString ?? "Record Shortcut"
    }
}

@Observable
@MainActor
final class RecorderMonitor {
    private(set) var isRecording = false
    private(set) var hint: String?
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var onRecord: ((HotKeySpec?) -> Void)?

    func start(_ onRecord: @escaping (HotKeySpec?) -> Void) {
        stop()
        self.onRecord = onRecord
        isRecording = true
        hint = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            let keyCode = event.keyCode
            let flags = event.modifierFlags
            let consumed = MainActor.assumeIsolated {
                self?.handle(keyCode: keyCode, flags: flags) ?? false
            }
            return consumed ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    /// Returns true when the event was consumed.
    private func handle(keyCode: UInt16, flags rawFlags: NSEvent.ModifierFlags) -> Bool {
        let flags = rawFlags.intersection(.deviceIndependentFlagsMask)
        let modifiers = CarbonModifier.from(flags)
        let code = Int(keyCode)
        if modifiers == 0 && code == kVK_Escape {
            stop()
            return true
        }
        if modifiers == 0 && (code == kVK_Delete || code == kVK_ForwardDelete) {
            stop()
            onRecord?(nil)
            return true
        }
        let strong = modifiers & (CarbonModifier.command | CarbonModifier.option | CarbonModifier.control)
        guard strong != 0 else {
            hint = "Include ⌘, ⌥ or ⌃"
            NSSound.beep()
            return true
        }
        hint = nil
        stop()
        onRecord?(HotKeySpec(keyCode: UInt32(keyCode), modifiers: modifiers))
        return true
    }
}
