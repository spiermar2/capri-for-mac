import AppKit
import Carbon
@preconcurrency import ApplicationServices

enum CompanionHotKeyAction: UInt32, CaseIterable {
    case summon = 1
    case visibility = 2

    static let signature: OSType = 0x43505249

    var carbonModifiers: UInt32 {
        switch self {
        case .summon: UInt32(cmdKey | optionKey)
        case .visibility: UInt32(controlKey | optionKey | cmdKey)
        }
    }

    static func matching(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Self? {
        guard keyCode == UInt16(kVK_ANSI_C) else { return nil }
        // Ignore toggle/device state, but never consume a different shortcut
        // merely because it contains Command and Option.
        let held = modifiers.intersection([.command, .option, .control, .shift, .function, .help])
        switch held {
        case [.command, .option]: return .summon
        case [.control, .option, .command]: return .visibility
        default: return nil
        }
    }
}

struct HotKeyDeliveryGate {
    enum Source { case local, carbon }
    private var previous: [CompanionHotKeyAction: (source: Source, time: TimeInterval)] = [:]

    mutating func accepts(_ action: CompanionHotKeyAction, from source: Source,
                         at time: TimeInterval) -> Bool {
        if let last = previous[action], last.source != source,
           time >= last.time, time - last.time < 0.12 {
            previous[action] = nil
            return false
        }
        previous[action] = (source, time)
        return true
    }
}

/// Pure state machine: a solitary right-Command press and release is a tap.
/// It stores timing and modifier state only, never key text or typed content.
struct RightCommandTapDetector {
    private var pressedAt: TimeInterval?
    private var rightWasDown = false
    private var cancelled = false
    let maximumTapDuration: TimeInterval = 0.6

    mutating func modifierChanged(keyCode: UInt16, rightDown: Bool,
                                  leftDown: Bool, hasOtherModifiers: Bool,
                                  timestamp: TimeInterval) -> Bool {
        if rightDown {
            if !rightWasDown {
                // Do not infer a press from an unrelated modifier event.
                pressedAt = keyCode == 54 ? timestamp : nil
                cancelled = keyCode != 54 || leftDown || hasOtherModifiers
            } else if leftDown || hasOtherModifiers || keyCode != 54 {
                cancelled = true
            }
            rightWasDown = true
            return false
        }

        let began = pressedAt
        let wasDown = rightWasDown
        let wasCancelled = cancelled
        reset()
        guard keyCode == 54, wasDown, let began = began,
              !wasCancelled, !leftDown, !hasOtherModifiers else { return false }
        let duration = timestamp - began
        return duration >= 0 && duration <= maximumTapDuration
    }

    /// Another key or a mouse press makes this a normal shortcut/gesture.
    mutating func cancelTap() {
        if rightWasDown { cancelled = true }
    }

    mutating func reset() {
        pressedAt = nil
        rightWasDown = false
        cancelled = false
    }
}

/// Observes an isolated right-Command tap without swallowing keyboard events.
/// Global keyboard observation is installed only after Accessibility is granted.
@MainActor
final class RightCommandShortcut {
    var onSummon: (() -> Void)?
    var onStatusChange: ((Bool) -> Void)?

    var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    private var detector = RightCommandTapDetector()
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var permissionTimer: Timer?
    private var running = false
    private var reportedTrust: Bool?

    // Device-specific masks from IOKit/hidsystem/IOLLEvent.h. The ordinary
    // NSEvent .command flag cannot distinguish the two Command keys.
    private static let deviceRightCommandMask: UInt = 0x00000010
    private static let deviceLeftCommandMask: UInt = 0x00000008
    private static let eventMask: NSEvent.EventTypeMask = [
        .flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown
    ]

    func start() {
        guard !running else {
            refreshPermission()
            return
        }
        running = true
        detector.reset()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.eventMask) { [weak self] event in
            // AppKit dispatches event monitors on the main thread.
            MainActor.assumeIsolated { self?.observe(event) }
            return event
        }
        refreshPermission()
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            // Installed on RunLoop.main; this never requests permission.
            MainActor.assumeIsolated { self?.refreshPermission() }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    func stop() {
        running = false
        permissionTimer?.invalidate()
        permissionTimer = nil
        if let monitor = localMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = globalMonitor { NSEvent.removeMonitor(monitor) }
        localMonitor = nil
        globalMonitor = nil
        detector.reset()
    }

    /// Call only in response to an explicit app permission button.
    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refreshPermission()
    }

    private func refreshPermission() {
        let trusted = isAccessibilityTrusted
        if running && trusted && globalMonitor == nil {
            detector.reset()
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.eventMask) { [weak self] event in
                MainActor.assumeIsolated { self?.observe(event) }
            }
        } else if !trusted, let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
            detector.reset()
        }
        if reportedTrust != trusted {
            reportedTrust = trusted
            onStatusChange?(trusted)
        }
    }

    private func observe(_ event: NSEvent) {
        guard running else { return }
        switch event.type {
        case .flagsChanged:
            let rawFlags = event.modifierFlags.rawValue
            let rightDown = rawFlags & Self.deviceRightCommandMask != 0
            let leftDown = rawFlags & Self.deviceLeftCommandMask != 0
            // Caps Lock and numeric-pad status are not held shortcut modifiers.
            let otherModifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .function, .help]
            let summon = detector.modifierChanged(
                keyCode: event.keyCode,
                rightDown: rightDown,
                leftDown: leftDown,
                hasOtherModifiers: !event.modifierFlags.intersection(otherModifiers).isEmpty,
                timestamp: event.timestamp
            )
            if summon { onSummon?() }
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown:
            detector.cancelTap()
        default:
            break
        }
    }

    isolated deinit {
        permissionTimer?.invalidate()
        if let monitor = localMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = globalMonitor { NSEvent.removeMonitor(monitor) }
    }
}
