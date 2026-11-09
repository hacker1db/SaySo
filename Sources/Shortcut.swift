import Foundation

/// Which key starts and stops dictation. Modifier triggers use a double-tap to start and a single tap
/// to finish (hands-free, no holding). Control–Option–Space stays available as a classic shortcut.
enum ShortcutTrigger: String, CaseIterable, Identifiable {
    case eitherCommand, rightCommand, leftCommand, rightOption, fn, controlOptionSpace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .eitherCommand: return "Command"
        case .rightCommand: return "Right Command"
        case .leftCommand: return "Left Command"
        case .rightOption: return "Right Option"
        case .fn: return "fn / Globe"
        case .controlOptionSpace: return "Control–Option–Space"
        }
    }

    /// Short key-cap label, e.g. for "Double-tap ⌘".
    var keyCap: String {
        switch self {
        case .eitherCommand: return "⌘"
        case .rightCommand: return "right ⌘"
        case .leftCommand: return "left ⌘"
        case .rightOption: return "right ⌥"
        case .fn: return "fn"
        case .controlOptionSpace: return "⌃⌥Space"
        }
    }

    var isModifierGesture: Bool { self != .controlOptionSpace }

    var startHint: String { isModifierGesture ? "Double-tap \(keyCap)" : "Press \(keyCap)" }
    var stopHint: String { isModifierGesture ? "tap \(keyCap) once" : "press \(keyCap) again" }

    /// Device-dependent modifier bit for one physical key (left/right are reported separately).
    static func deviceMask(forKeyCode code: UInt16) -> UInt? {
        switch code {
        case 55: return 0x08  // left ⌘
        case 54: return 0x10  // right ⌘
        case 58: return 0x20  // left ⌥
        case 61: return 0x40  // right ⌥
        default: return nil
        }
    }

    /// Hardware key codes (kVK_*) that count as this trigger in flags-changed events.
    var keyCodes: Set<UInt16> {
        switch self {
        case .eitherCommand: return [55, 54]
        case .rightCommand: return [54]
        case .leftCommand: return [55]
        case .rightOption: return [61]
        case .fn: return [63]
        case .controlOptionSpace: return []
        }
    }
}

/// Pure double-tap / single-tap recognizer for a modifier key.
/// A "tap" is a press and release of the trigger alone, short enough not to be a held shortcut.
/// Any other key or modifier during the press spoils it, so ⌘C, ⌘⇧4 and friends never trigger dictation.
struct TapGesture {
    enum Output: Equatable { case none, start, stop }

    var maxTap: TimeInterval = 0.35   // longest press that still counts as a tap
    var maxGap: TimeInterval = 0.40   // longest pause between the two taps of a double-tap

    private var downAt: TimeInterval?
    private var spoiled = false
    private var lastTapUp: TimeInterval?

    mutating func triggerDown(at t: TimeInterval) {
        // A second press while one is held (e.g. both ⌘ keys) is never a clean tap, and must not clear a spoil.
        if downAt != nil { spoiled = true; lastTapUp = nil; return }
        downAt = t
        spoiled = false
    }

    /// `active` is true while dictation is listening: then a single tap stops it.
    mutating func triggerUp(at t: TimeInterval, active: Bool) -> Output {
        guard let down = downAt else { return .none }
        downAt = nil
        guard !spoiled, t - down <= maxTap else { lastTapUp = nil; return .none }
        if active { lastTapUp = nil; return .stop }
        if let last = lastTapUp, down - last <= maxGap { lastTapUp = nil; return .start }
        lastTapUp = t
        return .none
    }

    /// Any other key or modifier: the current press is no longer a clean tap, and a pending first tap is void.
    mutating func otherInput() {
        if downAt != nil { spoiled = true }
        lastTapUp = nil
    }
}
