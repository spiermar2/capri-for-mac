import Foundation

@main
struct IdleAnimationTests {
    @MainActor
    static func main() {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) {
            precondition(condition, label)
            checks += 1
            print("PASS \(label)")
        }

        var earliest = IdleAnimationDirector()
        expect(earliest.update(at: 0, eligible: true, randomUnit: { 0 }) == nil,
               "opening never immediately plays a cue")
        expect(earliest.update(at: 5.999, eligible: true, randomUnit: { 0 }) == nil,
               "first cue waits at least six seconds")
        expect(earliest.update(at: 6, eligible: true, randomUnit: { 0 }) != nil,
               "first cue can start at the lower delay bound")
        expect(earliest.update(at: 12.999, eligible: true, randomUnit: { 0 }) == nil,
               "successive cues stay at least seven seconds apart")
        expect(earliest.update(at: 13, eligible: true, randomUnit: { 0 }) != nil,
               "successive cue can start at the lower delay bound")

        var latest = IdleAnimationDirector()
        _ = latest.update(at: 0, eligible: true, randomUnit: { 1 })
        expect(latest.update(at: 8.999, eligible: true, randomUnit: { 1 }) == nil,
               "first random delay can reach nine seconds")
        expect(latest.update(at: 9, eligible: true, randomUnit: { 1 }) != nil,
               "upper-bound random value selects a valid cue")
        expect(latest.update(at: 22.999, eligible: true, randomUnit: { 1 }) == nil,
               "subsequent random delay can reach fourteen seconds")
        expect(latest.update(at: 23, eligible: true, randomUnit: { 1 }) != nil,
               "successive cue arrives by its upper delay bound")

        for random in [0.0, 0.25, 0.5, 0.75, 1.0] {
            var director = IdleAnimationDirector()
            _ = director.update(at: 0, eligible: true, randomUnit: { random })
            var previous: IdleAnimationDirector.Cue?
            var count = 0
            for second in 1...700 {
                if let cue = director.update(at: Double(second), eligible: true, randomUnit: { random }) {
                    precondition(cue != previous, "consecutive cues must differ")
                    previous = cue
                    count += 1
                }
            }
            expect(count >= 40, "cue selection never repeats consecutively at random \(random)")
        }

        var activity = IdleAnimationDirector()
        _ = activity.update(at: 0, eligible: true, randomUnit: { 0 })
        activity.noteActivity(at: 5)
        expect(activity.update(at: 6, eligible: true, randomUnit: { 0 }) == nil,
               "typing cancels a previously scheduled cue")
        expect(activity.update(at: 8.999, eligible: true, randomUnit: { 0 }) == nil,
               "activity guarantees at least four seconds of quiet")
        expect(activity.update(at: 12, eligible: true, randomUnit: { 0 }) != nil,
               "cues resume after a fresh quiet interval")

        var sustained = IdleAnimationDirector()
        var interruptedCues = 0
        for second in 0...120 {
            sustained.noteActivity(at: Double(second))
            if sustained.update(at: Double(second), eligible: true, randomUnit: { 0 }) != nil {
                interruptedCues += 1
            }
        }
        expect(interruptedCues == 0, "sustained interaction never starts idle cues")
        expect(sustained.update(at: 125.999, eligible: true, randomUnit: { 0 }) == nil,
               "sustained interaction leaves a fresh delay after its last event")
        expect(sustained.update(at: 126, eligible: true, randomUnit: { 0 }) != nil,
               "ending sustained interaction allows idle cues again")

        // The UI combines hidden, listening, busy, speaking, dragging and Reduce
        // Motion into this one eligibility input. Every blocked state gets the
        // same pause semantics without importing AppKit into the policy.
        var paused = IdleAnimationDirector()
        _ = paused.update(at: 0, eligible: true, randomUnit: { 0 })
        let beforePause = paused.update(at: 6, eligible: true, randomUnit: { 0 })
        expect(paused.update(at: 7, eligible: false, randomUnit: { 0 }) == nil,
               "ineligible state cancels pending cues")
        expect(paused.update(at: 500, eligible: false, randomUnit: { 0 }) == nil,
               "a long ineligible interval never emits a cue")
        expect(paused.update(at: 501, eligible: true, randomUnit: { 0 }) == nil,
               "resuming waits instead of playing an overdue cue")
        expect(paused.update(at: 506.999, eligible: true, randomUnit: { 0 }) == nil,
               "resuming observes a fresh initial delay")
        let afterPause = paused.update(at: 507, eligible: true, randomUnit: { 0 })
        expect(afterPause != nil && afterPause != beforePause,
               "resuming retains nonrepeat history")

        paused.cancel(at: 508)
        expect(paused.update(at: 520, eligible: true, randomUnit: { 0 }) == nil,
               "explicit cancellation also discards the old deadline")
        expect(paused.update(at: 526, eligible: true, randomUnit: { 0 }) != nil,
               "explicit cancellation permits a later fresh cue")

        var sleeping = IdleAnimationDirector()
        _ = sleeping.update(at: 0, eligible: true, randomUnit: { 0 })
        expect(sleeping.update(at: 10_000, eligible: true, randomUnit: { 0 }) != nil,
               "a delayed timer may emit one cue")
        var burst = 0
        for _ in 0..<100 {
            if sleeping.update(at: 10_000, eligible: true, randomUnit: { 0 }) != nil { burst += 1 }
        }
        expect(burst == 0, "delayed timers never replay missed cues in a burst")
        expect(sleeping.update(at: 10_006.999, eligible: true, randomUnit: { 0 }) == nil,
               "delayed timers schedule from current time")
        expect(sleeping.update(at: 10_007, eligible: true, randomUnit: { 0 }) != nil,
               "normal spacing continues after a delayed timer")

        print("\(checks) idle-animation checks passed; no network or UI access")
    }
}
