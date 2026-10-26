import Foundation

/// Schedules local visual cues using a monotonic clock, such as systemUptime.
/// The caller controls eligibility and cancels any visible cue when activity starts.
/// This policy neither creates timers nor performs AI or voice requests.
struct IdleAnimationDirector: Sendable {
    enum Cue: CaseIterable, Sendable {
        case glance, grin, gesture
    }

    private var nextCueAt: TimeInterval?
    private var quietUntil: TimeInterval = -.infinity
    private var lastCue: Cue?

    mutating func noteActivity(at now: TimeInterval) {
        nextCueAt = nil
        quietUntil = now + 4
    }

    mutating func cancel(at now: TimeInterval) {
        noteActivity(at: now)
    }

    /// The optional random source makes timing and cue selection reproducible in tests.
    /// A fresh eligible period waits 6–9 seconds; subsequent cues wait 7–14 seconds.
    mutating func update(at now: TimeInterval, eligible: Bool,
                         randomUnit: () -> Double = { Double.random(in: 0...1) }) -> Cue? {
        guard eligible else {
            cancel(at: now)
            return nil
        }
        guard let deadline = nextCueAt else {
            nextCueAt = max(quietUntil, now + 6 + 3 * unit(randomUnit))
            return nil
        }
        guard now >= deadline, now >= quietUntil else { return nil }

        let choices = Cue.allCases.filter { $0 != lastCue }
        let index = min(choices.count - 1, Int(unit(randomUnit) * Double(choices.count)))
        let cue = choices[index]
        lastCue = cue
        // Schedule from now, never the overdue deadline: a sleeping Mac cannot
        // accumulate a burst of missed animations.
        nextCueAt = now + 7 + 7 * unit(randomUnit)
        return cue
    }

    private func unit(_ randomUnit: () -> Double) -> Double {
        let value = randomUnit()
        return value.isFinite ? min(1, max(0, value)) : 0.5
    }
}
