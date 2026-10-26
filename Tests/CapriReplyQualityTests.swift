import Foundation

@main
struct CapriReplyQualityTests {
    static func main() {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            let passed = condition()
            precondition(passed, label); checks += 1; print("PASS \(label)")
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
        func spoken(_ text: String, prompt: String = "Tell me how to get that item") -> String {
            CapriReplyText.conversation(text, userMessage: prompt)
        }
        let walkthrough = "The **Militech Canto Mk.6**—the cyberdeck with **Blackwall Gateway**.\n\n**Minor mission spoilers:**\n1. In **Firestarter**, choose your route."
        expect(spoken(walkthrough) == "The Militech Canto Mk.6—the cyberdeck with Blackwall Gateway.\n\nMinor mission spoilers:\n1. In Firestarter, choose your route.", "screenshot formatting clears without losing words, steps or paragraph breaks")
        expect(spoken("## The catch\n**A** matters.") == "The catch\nA matters.", "prose headings and single-letter emphasis become speech")
        expect(spoken("2 ** 3; a**b + c**d; identifiers_with_underscores; __init__; C#; #if DEBUG") == "2 ** 3; a**b + c**d; identifiers_with_underscores; __init__; C#; #if DEBUG", "operators, identifiers and language syntax survive")
        expect(spoken("Use `**exact**` and ``a ** b``. **Done.**") == "Use `**exact**` and ``a ** b``. **Done.**", "lines with inline code remain conservatively unchanged")
        let nestedTicks = "Use ``**keep** ` nested`` then **clear**"
        expect(spoken(nestedTicks) == nestedTicks, "nested inline backtick runs remain unchanged")
        expect(spoken("2 **3 + 4** 5; a **b - c** d") == "2 **3 + 4** 5; a **b - c** d", "operator-like exponent expressions remain unchanged")
        expect(spoken("# include <stdio.h>") == "# include <stdio.h>", "preprocessor directives remain unchanged")
        expect(spoken("a **b** c", prompt: "Explain this Python code") == "a **b** c", "technical requests preserve ambiguous exponent syntax")
        let code = "**Example:**\n````python\n# header\nvalue = '**literal**'\n```\n````\n**Done.**"
        expect(spoken(code) == "Example:\n````python\n# header\nvalue = '**literal**'\n```\n````\nDone.", "fenced code including shorter interior fences is preserved")
        expect(spoken("~~~\n**literal**\n~~~\n**Done.**") == "~~~\n**literal**\n~~~\nDone.", "tilde code fences are preserved")
        expect(spoken("```swift\n**unfinished code") == "```swift\n**unfinished code", "unfinished code fence remains untouched")
        expect(spoken("    **indented code**\n\t# code") == "    **indented code**\n\t# code", "indented code remains untouched")
        let links = "[docs](https://example.com/a_b/**path**#frag) https://example.com/**path** **Read it.**"
        expect(spoken(links) == "[docs](https://example.com/a_b/**path**#frag) https://example.com/**path** Read it.", "link and URL bytes survive")
        let inlineMath = #"$a ** b$ and \(x ** y\). **Done.**"#
        expect(spoken(inlineMath) == #"$a ** b$ and \(x ** y\). Done."#, "inline math survives")
        expect(spoken("$$\na ** b\n$$\n**Done.**") == "$$\na ** b\n$$\nDone.", "multiline math survives")
        expect(spoken("* Step one\n- Step two\n**unfinished\n\\**escaped**") == "* Step one\n- Step two\n**unfinished\n\\**escaped**", "bullets, unmatched and escaped markers survive")
        for request in ["Show Markdown", "Copy this verbatim", "Keep the exact wording", "Explain this regex", "Give me the literal text", "Write LaTeX"] {
            expect(spoken("## **Keep me**", prompt: request) == "## **Keep me**", "explicit literal formatting remains intact: \(request)")
        }
        print("\(checks) reply-quality checks passed; no model calls")
    }
}
