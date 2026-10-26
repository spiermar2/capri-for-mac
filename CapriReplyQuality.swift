import Foundation

/// Presentation cleanup only; never generates, shortens, or changes the facts
/// in a reply. The same result is displayed, spoken, and kept in chat context.
enum CapriReplyText {
    static func conversation(_ reply: String, userMessage: String) -> String {
        // Literal-format requests must remain literal, even in the speech bubble.
        if userMessage.range(of: #"(?i)\b(markdown|verbatim|literal|regex|regular expression|latex|exact text|exact wording|exactly as|unchanged|code|coding|script|programming|syntax|python|swift|javascript|typescript|html|css|sql|shell|terminal|math|calculate|evaluate|equation|formula|algebra|exponent)\b"#, options: .regularExpression) != nil {
            return reply
        }
        var fence: (Character, Int)?
        var mathBlock: String?
        return reply.components(separatedBy: "\n").map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let active = fence {
                let run = trimmed.prefix(while: { $0 == active.0 })
                if run.count >= active.1, trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespaces).isEmpty { fence = nil }
                return line
            }
            if let active = mathBlock {
                if trimmed.contains(active) { mathBlock = nil }
                return line
            }
            if let first = trimmed.first, first == "`" || first == "~" {
                let count = trimmed.prefix(while: { $0 == first }).count
                if count >= 3 { fence = (first, count); return line }
            }
            if trimmed.hasPrefix("$$") {
                if !trimmed.dropFirst(2).contains("$$") { mathBlock = "$$" }
                return line
            }
            if trimmed.hasPrefix(#"\["#) {
                if !trimmed.dropFirst(2).contains(#"\]"#) { mathBlock = #"\]"# }
                return line
            }
            // Prefer leaving decoration visible over changing possible source
            // code, including nested backtick runs and preprocessor directives.
            if line.hasPrefix("    ") || line.hasPrefix("\t") || line.contains("`") { return line }
            if trimmed.range(of: #"^#[ \t]*(include|define|undef|if|ifdef|ifndef|elif|else|endif|pragma|error|warning)\b"#, options: .regularExpression) != nil { return line }
            return proseLine(line)
        }.joined(separator: "\n")
    }

    private static func proseLine(_ line: String) -> String {
        // Preserve inline code, link destinations, URLs and math byte-for-byte.
        let protected = #"(`+)[^`]*?\1|!?\[[^\]\n]*\]\([^\n]*?\)|https?://[^\s<>]+|\$[^$\n]+\$|\\\([^\n]*?\\\)"#
        guard let regex = try? NSRegularExpression(pattern: protected) else { return line }
        var result = ""
        var start = line.startIndex
        for match in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
            guard let range = Range(match.range, in: line) else { continue }
            result += prose(String(line[start..<range.lowerBound]), allowHeading: start == line.startIndex)
            result += line[range]
            start = range.upperBound
        }
        result += prose(String(line[start...]), allowHeading: start == line.startIndex)
        return result
    }

    private static func prose(_ text: String, allowHeading: Bool) -> String {
        var result = text
        if allowHeading {
            result = result.replacingOccurrences(of: #"^ {0,3}#{1,6}[ \t]+(?=\S)"#, with: "", options: .regularExpression)
        }
        // Intentionally narrow: don't globally delete stars or underscores.
        // Operators, identifiers, bullet markers and unmatched syntax survive.
        let pattern = #"(?<![\p{L}\p{N}_*\\])\*\*(?=\S)([^*\n]+?)(?<=\S)\*\*(?![\p{L}\p{N}_*])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            guard let whole = Range(match.range, in: result), let inner = Range(match.range(at: 1), in: result) else { continue }
            let value = String(result[inner])
            // These may be exponent expressions rather than prose emphasis.
            guard value.contains(where: \.isLetter),
                  value.range(of: #"[+=/^<>]|\s-\s|\b(and|or|not|if|else|is|in)\b"#, options: .regularExpression) == nil else { continue }
            result.replaceSubrange(whole, with: value)
        }
        return result
    }
}

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
