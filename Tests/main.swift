// Assert-based self-check for the tap gesture (top-level code, so it must be main.swift). Run scripts/test.sh.
import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    if !condition() { print("FAIL line \(line): \(message)"); exit(1) }
}

var g = TapGesture()
// Double-tap starts.
g.triggerDown(at: 0.00); check(g.triggerUp(at: 0.10, active: false) == .none, "first tap only arms")
g.triggerDown(at: 0.30); check(g.triggerUp(at: 0.38, active: false) == .start, "second quick tap starts")
// While listening, one tap stops.
g.triggerDown(at: 5.00); check(g.triggerUp(at: 5.10, active: true) == .stop, "single tap stops while listening")

// Slow second tap does not start.
var h = TapGesture()
h.triggerDown(at: 0); check(h.holdCheck(at: 0.5, active: false) == .start, "holding alone starts")
check(h.triggerUp(at: 2.0, active: true) == .stop, "releasing a hold finishes")
h = TapGesture()
h.triggerDown(at: 0); _ = h.holdCheck(at: 0.5, active: false)
check(h.otherInput() == .cancel, "⌘+key during hold cancels")
check(h.triggerUp(at: 0.8, active: false) == .none, "release after cancelled hold does nothing")
h = TapGesture()
h.triggerDown(at: 0); h.otherInput(); check(h.holdCheck(at: 0.5, active: false) == .none, "⌘C held is not hold-to-talk")
h = TapGesture()
h.triggerDown(at: 0); check(h.holdCheck(at: 0.5, active: true) == .none, "hold while listening does nothing")
h = TapGesture()
h.triggerDown(at: 0); check(h.holdCheck(at: 0.2, active: false) == .none, "short press is not a hold")

g = TapGesture()
g.triggerDown(at: 0); _ = g.triggerUp(at: 0.1, active: false)
g.triggerDown(at: 1.0); check(g.triggerUp(at: 1.1, active: false) == .none, "gap too long")

// A held key is not a tap.
g = TapGesture()
g.triggerDown(at: 0); _ = g.triggerUp(at: 0.1, active: false)
g.triggerDown(at: 0.3); check(g.triggerUp(at: 1.2, active: false) == .none, "held press is not a tap")

// ⌘C between taps: the shortcut spoils the press and voids the pending tap.
g = TapGesture()
g.triggerDown(at: 0); _ = g.triggerUp(at: 0.1, active: false)
g.triggerDown(at: 0.2); g.otherInput(); check(g.triggerUp(at: 0.3, active: false) == .none, "⌘C does not start")
g.triggerDown(at: 0.4); check(g.triggerUp(at: 0.45, active: false) == .none, "pending tap was voided by ⌘C")

// ⌘V while listening does not stop dictation.
g = TapGesture()
g.triggerDown(at: 0); g.otherInput(); check(g.triggerUp(at: 0.1, active: true) == .none, "shortcut while listening keeps going")

// Both ⌘ keys overlapping (hold left ⌘, ⌘C, tap right ⌘): never a clean tap, spoil survives.
g = TapGesture()
g.triggerDown(at: 0); g.otherInput(); g.triggerDown(at: 0.1)
check(g.triggerUp(at: 0.15, active: true) == .none, "overlapping command keys do not stop")
g = TapGesture()
g.triggerDown(at: 0); g.triggerDown(at: 0.05)
check(g.triggerUp(at: 0.1, active: true) == .none, "two keys down at once is not a tap")

// ⌘-click: the click (reported as other input) spoils the press.
g = TapGesture()
g.triggerDown(at: 0); g.otherInput(); check(g.triggerUp(at: 0.2, active: true) == .none, "⌘-click does not stop")

check(ShortcutTrigger.deviceMask(forKeyCode: 54) == 0x10 && ShortcutTrigger.deviceMask(forKeyCode: 55) == 0x08, "device masks")

// Release without a recorded press is ignored.
g = TapGesture()
check(g.triggerUp(at: 1, active: true) == .none, "stray release ignored")

check(ShortcutTrigger.eitherCommand.keyCodes == [54, 55], "either command covers both keys")
check(ShortcutTrigger.controlOptionSpace.isModifierGesture == false, "classic shortcut is not a gesture")
check(ShortcutTrigger.rightCommand.startHint == "Double-tap right ⌘", "hint text")
print("ShortcutTests: all checks passed")
