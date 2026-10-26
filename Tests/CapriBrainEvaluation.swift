import Foundation

/// Explicit, synthetic on-device dialogue evaluation. Does not read saved
/// chats, request permissions, speak, contact ElevenLabs or operate the desktop.
@main
struct CapriBrainEvaluation {
    @MainActor static func main() async {
        let brain = CompanionBrain()
        // Defaults to the local engine unless an explicit --chatgpt evaluation is requested.
        brain.backend = CommandLine.arguments.contains("--chatgpt") ? .chatGPT : .apple
        let prompts = [
            "hey",
            "your lore?",
            "you're just a boring chatbot",
            "Call me Nova. I'm working on a little space game.",
            "what am I working on?",
            "roast me a little",
            "I actually had a rough day and don't feel like jokes.",
            "Can you see the document I have open?",
            "What's 17 times 23?",
            "Help me make a title screen for that game. Give me three ideas."
        ]
        for prompt in prompts {
            let start = Date()
            do {
                let response = try await brain.reply(to: prompt)
                let result: [String: Any] = ["user": prompt, "capri": response,
                    "words": response.split(whereSeparator: \.isWhitespace).count,
                    "seconds": Date().timeIntervalSince(start)]
                let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
                print(String(decoding: data, as: UTF8.self))
            } catch {
                print("FAILED \(prompt): \(error.localizedDescription)")
            }
        }
    }
}
