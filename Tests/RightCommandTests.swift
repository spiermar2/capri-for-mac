import Foundation
import AppKit
import Carbon

/// Exercises only the tap detector, shortcut matching and delivery gate. It
/// never instantiates monitors, requests permission or generates desktop input.
@main
struct RightCommandTests {
    static func main() {
        var tests = 0
        var detector = RightCommandTapDetector()

        func expect(_ condition: Bool, _ label: String) {
            precondition(condition, label)
            tests += 1
            print("PASS \(label)")
        }

        func flags(_ code: UInt16, _ right: Bool, _ left: Bool = false,
                   _ other: Bool = false, _ time: Double) -> Bool {
            detector.modifierChanged(keyCode: code, rightDown: right,
                                    leftDown: left, hasOtherModifiers: other,
                                    timestamp: time)
        }

        expect(!flags(54, true, false, false, 1), "press alone does not summon")
        expect(flags(54, false, false, false, 1.2), "right-only tap summons on release")
        expect(!flags(54, false, false, false, 1.21), "duplicate release does not summon")
        expect(!flags(55, false, true, false, 2), "left press ignored")
        expect(!flags(55, false, false, false, 2.2), "left release ignored")

        _ = flags(54, true, false, false, 3)
        detector.cancelTap()
        expect(!flags(54, false, false, false, 3.2), "right plus key excluded")

        _ = flags(54, true, false, false, 4)
        detector.cancelTap()
        expect(!flags(54, false, false, false, 4.2), "right plus mouse excluded")

        _ = flags(54, true, true, false, 5)
        expect(!flags(54, false, true, false, 5.2), "left already held excludes right tap")

        _ = flags(54, true, false, false, 6)
        _ = flags(55, true, true, false, 6.1)
        _ = flags(55, true, false, false, 6.15)
        expect(!flags(54, false, false, false, 6.2), "left pressed during right tap excludes it")

        _ = flags(54, true, false, false, 7)
        _ = flags(56, true, false, true, 7.1)
        _ = flags(56, true, false, false, 7.15)
        expect(!flags(54, false, false, false, 7.2), "other modifier pressed and released excludes tap")

        _ = flags(54, true, false, true, 8)
        expect(!flags(54, false, false, false, 8.2), "other modifier initially held excludes tap")

        _ = flags(54, true, false, false, 9)
        expect(!flags(54, false, false, false, 9.7), "long hold excluded")

        _ = flags(54, true, false, false, 10)
        _ = flags(54, true, false, false, 10.5)
        expect(!flags(54, false, false, false, 10.7), "repeated press cannot restart hold timer")

        _ = flags(54, true, false, false, 11)
        expect(!flags(54, false, false, false, 10.9), "stale release timestamp excluded")

        _ = flags(56, true, false, true, 12)
        expect(!flags(54, false, false, false, 12.2), "missing right press cannot create a tap")

        _ = flags(54, true, false, false, 13)
        detector.reset()
        expect(!flags(54, false, false, false, 13.2), "reset discards pending tap")

        _ = flags(54, true, false, false, 14)
        expect(flags(54, false, false, false, 14.1), "new clean tap works after cancelled sequences")

        let cKey = UInt16(kVK_ANSI_C)
        expect(CompanionHotKeyAction.matching(keyCode: cKey, modifiers: [.option, .command]) == .summon,
               "Option Command C keeps summon and dormant behavior")
        expect(CompanionHotKeyAction.matching(keyCode: cKey, modifiers: [.control, .option, .command]) == .visibility,
               "Control Option Command C selects full visibility instead of summon")
        expect(CompanionHotKeyAction.matching(keyCode: cKey, modifiers: [.option, .command, .capsLock, .numericPad]) == .summon,
               "summon ignores caps lock and numeric-pad state")
        expect(CompanionHotKeyAction.matching(keyCode: cKey, modifiers: [.control, .option, .command, .capsLock, .numericPad]) == .visibility,
               "visibility ignores caps lock and numeric-pad state")
        expect(CompanionHotKeyAction.matching(keyCode: cKey, modifiers: [.shift, .option, .command]) == nil,
               "extra Shift does not consume a different summon chord")
        expect(CompanionHotKeyAction.matching(keyCode: cKey, modifiers: [.shift, .control, .option, .command]) == nil,
               "extra Shift does not consume a different visibility chord")
        expect(CompanionHotKeyAction.matching(keyCode: cKey, modifiers: [.command]) == nil,
               "ordinary Command C remains available for copy")
        expect(CompanionHotKeyAction.matching(keyCode: UInt16(kVK_ANSI_V), modifiers: [.control, .option, .command]) == nil,
               "visibility modifier chord on another key is not consumed")
        expect(CompanionHotKeyAction.matching(keyCode: cKey, modifiers: [.function, .option, .command]) == nil,
               "extra Function does not consume a different shortcut")

        var gate = HotKeyDeliveryGate()
        expect(gate.accepts(.summon, from: .local, at: 20), "first local summon is delivered")
        expect(!gate.accepts(.summon, from: .carbon, at: 20.01), "matching Carbon duplicate is consumed")
        expect(gate.accepts(.summon, from: .carbon, at: 20.02), "consumed pair cannot suppress the next press")
        expect(gate.accepts(.summon, from: .carbon, at: 20.03), "rapid same-source presses remain independent")

        gate = HotKeyDeliveryGate()
        expect(gate.accepts(.visibility, from: .carbon, at: 21), "first Carbon visibility toggle is delivered")
        expect(!gate.accepts(.visibility, from: .local, at: 21.01), "reverse-order local duplicate is consumed")

        gate = HotKeyDeliveryGate()
        expect(gate.accepts(.summon, from: .local, at: 22), "new summon sequence begins")
        expect(gate.accepts(.visibility, from: .carbon, at: 22.01), "different actions do not suppress each other")
        expect(!gate.accepts(.summon, from: .carbon, at: 22.02), "interleaved action preserves summon duplicate tracking")
        expect(!gate.accepts(.visibility, from: .local, at: 22.03), "interleaved action preserves visibility duplicate tracking")

        gate = HotKeyDeliveryGate()
        expect(gate.accepts(.visibility, from: .local, at: 23), "new visibility sequence begins")
        expect(gate.accepts(.visibility, from: .carbon, at: 23.2), "later opposite-source press is not treated as a duplicate")

        print("\(tests) pure state checks passed; no desktop events generated")
    }
}
