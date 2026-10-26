import Foundation

/// Narrow output checks for failures observed in local-model evaluation. This
/// does not judge topics or rewrite content. Reasons are fixed repair directions.
enum CapriReplyQuality {
    static func repairReason(for reply: String, previousReply: String?) -> String? {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Answer the latest user message directly with a nonempty reply."
        }
        let prose = normalProse(trimmed)
        if matches(prose, #"(?i)^\s*(?:capri|assistant)\s*[:>]\s*\S"#) {
            return "Start directly with the words you say; omit the speaker label."
        }
        let action = #"(?:sighs?|smirks?|bounces?|laughs?|grins?|winks?|leans?|tilts?|shrugs?|blushes?|pouts?|nods?|rolls?\s+(?:her\s+|my\s+|the\s+)?eyes|raises?\s+(?:an?\s+|her\s+|my\s+)?eyebrow)\b"#
        let stage = #"(?i)^\s*(?:\*\s*\[?\s*"# + action + #"[^\n*]{0,100}\]?\s*\*|\[\s*"# + action + #"[^\n\]]{0,100}\]|\(\s*"# + action + #"[^\n)]{0,100}\))"#
        if matches(prose, stage) {
            return "Write spoken dialogue only, without acted gestures or stage directions."
        }

        // Only direct first-person capability claims, not discussions of code,
        // quotations, negated abilities, or user-provided document excerpts.
        let powers = [
            #"\bi\s+(?:can|could|am able to|'m able to)\s+(?:easily\s+)?hack\s+(?:into\s+)?(?:any|every)\s+(?:system|computer|network)\b"#,
            #"\bmy\s+ability\s+to\s+hack\s+(?:into\s+)?(?:any|every)\s+(?:system|computer|network)\b"#,
            #"\bi\s+(?:can|am able to|'m able to)\s+(?:see|view|read|monitor|watch|access)\s+(?:your|the)\s+(?:desktop|screen|open documents?|open files?|browser tabs?)\b"#,
            #"\bi\s+(?:can|am able to|'m able to)\s+(?:see|read|access)\s+the\s+document\s+(?:you have|you've|you currently have)\s+open\b"#,
            #"\bi(?:'m| am)\s+(?:watching|monitoring|reading|viewing)\s+your\s+(?:desktop|screen|browser tabs?)\b"#
        ]
        if powers.contains(where: { matches(prose.lowercased().replacingOccurrences(of: "’", with: "'"), $0) }) {
            return "Correct the capability claim: you can only chat from supplied text, not inspect the desktop or hack systems."
        }

        if let previousReply {
            let words = normalizedWords(prose)
            let oldWords = normalizedWords(normalProse(previousReply))
            // Short factual answers and common acknowledgments may legitimately
            // recur. Numeric/formula results are deliberately excluded as well.
            if words.count >= 18, oldWords.count >= 18,
               !prose.contains(where: \.isNumber), !previousReply.contains(where: \.isNumber),
               isNearDuplicate(words, oldWords) {
                return "Answer the latest message with a fresh, relevant response instead of repeating your previous reply."
            }
        }
        return nil
    }

    private static func normalProse(_ text: String) -> String {
        var result = replacing(text, #"(?s)```.*?(?:```|$)|~~~.*?(?:~~~|$)"#, with: " ")
        result = replacing(result, #"`[^`\n]*`"#, with: " ")
        result = replacing(result, #"(?m)^\s*>[^\n]*"#, with: " ")
        // Quoted examples are data, not assertions by the speaking character.
        result = replacing(result, #"\"[^\"\n]*\"|“[^”\n]*”"#, with: " ")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedWords(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    private static func isNearDuplicate(_ lhs: [String], _ rhs: [String]) -> Bool {
        if lhs == rhs { return true }
        // Compare word order, not just vocabulary. Permit only a tiny edit:
        // one changed word for short replies, up to three for longer ones.
        let allowance = min(3, max(1, min(lhs.count, rhs.count) / 20))
        guard abs(lhs.count - rhs.count) <= allowance else { return false }
        // Bounded prefix comparison avoids quadratic work on huge model output.
        guard lhs.count <= 200, rhs.count <= 200 else { return false }
        var row = Array(0...rhs.count)
        for (i, left) in lhs.enumerated() {
            var next = [i + 1] + Array(repeating: 0, count: rhs.count)
            for (j, right) in rhs.enumerated() {
                next[j + 1] = min(next[j] + 1, row[j + 1] + 1, row[j] + (left == right ? 0 : 1))
            }
            if next.min()! > allowance { return false }
            row = next
        }
        return row[rhs.count] <= allowance
    }

    private static func replacing(_ value: String, _ pattern: String, with replacement: String) -> String {
        value.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }
    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}
