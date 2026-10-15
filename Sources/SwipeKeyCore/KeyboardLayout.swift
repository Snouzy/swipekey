import Carbon
import CoreGraphics

/// Finds which physical key types a character in a keyboard layout.
public protocol KeyboardLayout {
    /// The key code whose key prints `character`, with or without Shift. Nil if no key does.
    func keyCode(for character: Character) -> CGKeyCode?
}

/// The layout currently selected in macOS (AZERTY, QWERTZ, Dvorak...), read at each call
/// so switching layouts takes effect without a restart.
public struct SystemKeyboardLayout: KeyboardLayout {
    public init() {}

    public func keyCode(for character: Character) -> CGKeyCode? {
        guard
            let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        let target = String(character).lowercased()

        return data.withUnsafeBytes { raw -> CGKeyCode? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            // Unshifted first, then with Shift: on AZERTY "1" is Shift + the "&" key.
            let shift = UInt32(shiftKey >> 8) & 0xFF
            for modifierState in [UInt32(0), shift] {
                for code in 0..<CGKeyCode(128) where !Self.keypad.contains(code) {
                    if Self.translate(code, modifierState: modifierState, layout: layout)?.lowercased() == target {
                        return code
                    }
                }
            }
            return nil
        }
    }

    /// Keypad keys type digits without Shift, which would win over the main row on AZERTY.
    private static let keypad: ClosedRange<CGKeyCode> = 65...92

    private static func translate(_ code: CGKeyCode, modifierState: UInt32, layout: UnsafePointer<UCKeyboardLayout>) -> String? {
        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(
            layout, code, UInt16(kUCKeyActionDisplay), modifierState, UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, chars.count, &length, &chars
        )
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}
