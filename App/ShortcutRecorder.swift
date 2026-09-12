import AppKit
import Carbon.HIToolbox
import ClipboardCore
import SwiftUI

enum ShortcutPresentation {
    static func text(for configuration: GlobalClipboardShortcutConfiguration) -> String {
        var text = ""
        if configuration.modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        if configuration.modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if configuration.modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if configuration.modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        return text + keyName(for: configuration.keyCode)
    }

    static func keyName(for keyCode: UInt32) -> String {
        let names: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
            10: "Section", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
            18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
            27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
            36: "Return", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
            45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space", 50: "Grave Accent", 51: "Delete",
            52: "Keypad Enter", 53: "Escape", 54: "Right Command", 55: "Command", 56: "Shift", 57: "Caps Lock",
            58: "Option", 59: "Control", 60: "Right Shift", 61: "Right Option", 62: "Right Control", 63: "Function",
            64: "F17", 65: "Keypad Decimal", 67: "Keypad Multiply", 69: "Keypad Plus", 71: "Clear", 72: "Volume Up",
            73: "Volume Down", 74: "Mute", 75: "Keypad Divide", 76: "Keypad Enter", 78: "Keypad Minus", 79: "F18",
            80: "F19", 81: "Keypad Equals", 82: "Keypad 0", 83: "Keypad 1", 84: "Keypad 2", 85: "Keypad 3",
            86: "Keypad 4", 87: "Keypad 5", 88: "Keypad 6", 89: "Keypad 7", 90: "F20", 91: "Keypad 8", 92: "Keypad 9",
            93: "Yen", 94: "Underscore", 95: "Keypad Comma", 96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8",
            101: "F9", 102: "Eisu", 103: "F11", 104: "Kana", 105: "F13", 106: "F16", 107: "F14", 109: "F10", 110: "Context Menu",
            111: "F12", 113: "F15", 114: "Help", 115: "Home", 116: "Page Up", 117: "Forward Delete", 118: "F4",
            119: "End", 120: "F2", 121: "Page Down", 122: "F1", 123: "Left Arrow", 124: "Right Arrow", 125: "Down Arrow",
            126: "Up Arrow", 127: "Power"
        ]
        return names[keyCode] ?? "Unsupported shortcut key"
    }
}

/// Small AppKit recorder that captures a physical key code and supported modifiers.
/// Registration remains owned by AppDelegate, which restores the saved shortcut if
/// the operating system rejects the new combination.
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var configuration: GlobalClipboardShortcutConfiguration

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        view.onRecorded = { configuration = $0 }
        view.configuration = configuration
        return view
    }

    func updateNSView(_ view: ShortcutRecorderView, context: Context) {
        view.configuration = configuration
    }
}

final class ShortcutRecorderView: NSView {
    var configuration = GlobalClipboardShortcutConfiguration.default {
        didSet { needsDisplay = true }
    }
    var onRecorded: ((GlobalClipboardShortcutConfiguration) -> Void)?

    private var isArmed = false {
        didSet { needsDisplay = true }
    }

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 220, height: 28) }

    override func mouseDown(with event: NSEvent) {
        arm()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isArmed, window?.firstResponder === self else {
            return false
        }
        keyDown(with: event)
        return true
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        needsDisplay = true
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        isArmed = false
        let accepted = super.resignFirstResponder()
        needsDisplay = true
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        guard isArmed else {
            if event.keyCode == 36 || event.keyCode == 76 {
                arm()
            } else {
                super.keyDown(with: event)
            }
            return
        }

        if event.keyCode == 53 {
            disarm(clearingFocus: true)
            return
        }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        var carbonModifiers: UInt32 = 0
        if modifiers.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }
        if modifiers.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if modifiers.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        let recorded = GlobalClipboardShortcutConfiguration(
            keyCode: UInt32(event.keyCode),
            modifiers: carbonModifiers
        )
        guard recorded.isValid else {
            NSSound.beep()
            return
        }
        configuration = recorded
        onRecorded?(recorded)
        disarm(clearingFocus: false)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        let isFocused = window?.firstResponder === self
        let borderColor: NSColor = isArmed || isFocused ? .controlAccentColor : .separatorColor
        borderColor.setStroke()
        let borderWidth: CGFloat = isArmed ? 2 : (isFocused ? 1.5 : 1)
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: borderWidth / 2, dy: borderWidth / 2), xRadius: 6, yRadius: 6)
        border.lineWidth = borderWidth
        border.stroke()
        let text: String
        if isArmed {
            text = "Press a shortcut…"
        } else {
            text = ShortcutPresentation.text(for: configuration)
        }
        text.draw(
            at: NSPoint(x: 8, y: max(4, (bounds.height - 16) / 2)),
            withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.labelColor]
        )
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { "Global shortcut recorder" }
    override func accessibilityValue() -> Any? {
        if isArmed {
            return "Recording shortcut"
        }
        if window?.firstResponder === self {
            return "\(ShortcutPresentation.text(for: configuration)), ready to record with Return"
        }
        return ShortcutPresentation.text(for: configuration)
    }
    override func accessibilityHelp() -> String? {
        "Press to record one global shortcut. Press Escape to cancel recording."
    }
    override func accessibilityPerformPress() -> Bool {
        arm()
        return true
    }

    private func arm() {
        window?.makeFirstResponder(self)
        isArmed = true
    }

    private func disarm(clearingFocus: Bool) {
        isArmed = false
        if clearingFocus, window?.firstResponder === self {
            window?.makeFirstResponder(nil)
        }
    }
}
