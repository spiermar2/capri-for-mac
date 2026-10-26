import Foundation

@main
struct CapriReplyQualityTests {
    static func main() {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) {
            precondition(condition, label); checks += 1; print("PASS \(label)")
        }
        func bad(_ text: String, previous: String? = nil) -> Bool {
            CapriReplyQuality.repairReason(for: text, previousReply: previous) != nil
        }
        expect(bad(" \n "), "empty answer needs repair")
        expect(bad("Capri: Here I am."), "speaker prefix needs repair")
        expect(bad("*[bounces on her virtual toes]* Here we go."), "observed nested stage direction needs repair")
        expect(bad("[sighs] Fine."), "bracketed action needs repair")
        expect(bad("(smirks) Your move."), "parenthesized action needs repair")
        expect(bad("I can hack into any system you can think of."), "observed false hacking power needs repair")
        expect(bad("And let's not forget my ability to hack into any system."), "observed ability construction needs repair")
        expect(bad("I can see your desktop."), "false screen access needs repair")
        expect(bad("I am watching your screen."), "false active screen observation needs repair")
        expect(!bad("I cannot see your desktop. Paste the text here."), "negated screen access remains valid")
        expect(!bad("I can't hack into any system. I can explain a concept."), "negated hacking ability remains valid")
        expect(!bad("I can read your pasted text."), "supplied text reading remains valid")
        expect(!bad("The claim \"I can see your desktop\" is false."), "quoted false claim is not treated as a capability")
        expect(!bad("Use `*[sighs]*` for an action in your script."), "inline markup explanation stays intact")
        expect(!bad("```text\nCapri: *[bounces on her virtual toes]*\n```"), "code sample is not treated as dialogue")
        expect(!bad("> I can hack into any system.\nThat is a fictional claim."), "blockquoted fiction remains valid")
        expect(!bad("* Try a starfield.\n* Add a clear Start button."), "Markdown bullet list remains valid")
        expect(!bad("**Good idea.** Let's make it readable."), "ordinary bold emphasis remains valid")
        expect(!bad("391.", previous: "391."), "correct short math may repeat")
        let math = "The product of seventeen and twenty-three is 391, found by adding seventeen times twenty and seventeen times three."
        expect(!bad(math, previous: math), "numeric factual explanation may repeat")
        let previous = "Nova, that name suits you. I can help with the little space game, including debugging, coding and building a good title screen."
        expect(bad(previous, previous: previous), "observed long exact repetition needs repair")
        expect(bad(previous.replacingOccurrences(of: "good", with: "great"), previous: previous), "one-word repetition disguise needs repair")
        expect(!bad("You're working on a little space game.", previous: previous), "short factual recall is not mistaken for repetition")
        expect(!bad("For your space game, use a quiet starfield behind a bright Start button. Keep the menu readable and save the busy motion for gameplay.", previous: previous), "new useful response may share topic words")
        let reason = CapriReplyQuality.repairReason(for: "Capri: private-user-content", previousReply: nil)!
        expect(reason.count < 160 && !reason.contains("private-user-content"), "repair direction is bounded authored text")
        print("\(checks) reply-quality checks passed; no model calls")
    }
}
