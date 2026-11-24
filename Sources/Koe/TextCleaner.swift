import Foundation

struct WordReplacement: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var spoken: String
    var written: String
    var enabled: Bool

    init(id: UUID = UUID(), spoken: String, written: String, enabled: Bool = true) {
        self.id = id
        self.spoken = spoken
        self.written = written
        self.enabled = enabled
    }
}

enum ReplacementStore {
    static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Koe/replacements.json")

    static let defaultsTemplate: [WordReplacement] = [
        WordReplacement(spoken: "dot env", written: ".env"),
        WordReplacement(spoken: "whisper flow", written: "Wispr Flow"),
    ]

    static func load() -> [WordReplacement] {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            save(defaultsTemplate)
            return defaultsTemplate
        }
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([WordReplacement].self, from: data)
        else {
            return defaultsTemplate
        }
        return decoded
    }

    static func save(_ items: [WordReplacement]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(items) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

enum TextCleaner {
    private static let fillers: Set<String> = ["um", "uh", "uhm", "er", "erm", "hmm", "mm", "mhm"]
    private static let inflections: Set<String> = ["s", "es", "d", "ed", "ing", "er", "ers", "ly", "n", "re", "ve", "ll", "t", "m"]
    private static let abbreviations: Set<String> = ["mr.", "mrs.", "ms.", "dr.", "prof.", "sr.", "jr.", "vs.", "etc.", "e.g.", "i.e.", "fig.", "no."]

    /// Repairs intra-word ASR punctuation glitches like `"tuning,s"` → `"tunings,"`
    /// while preserving numbers (`30,000`, `3:30`, `2.1`) and dotted identifiers (`Next.js`, `.env`).
    static func repairMidWordPunctuation(_ text: String) -> String {
        let rawTokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !rawTokens.isEmpty else { return "" }

        var repaired: [String] = []
        repaired.reserveCapacity(rawTokens.count)

        for (index, token) in rawTokens.enumerated() {
            let isLast = index == rawTokens.count - 1
            repaired.append(repairToken(token, isLast: isLast))
        }
        return repaired.joined(separator: " ")
    }

    static func hasMidWordPunctuation(_ token: String) -> Bool {
        if token.contains(where: \.isNumber) { return false }
        let chars = Array(token)
        for i in 1..<max(1, chars.count - 1) {
            let c = chars[i]
            if (c == "," || c == ";" || c == ":") && chars[i - 1].isLetter && chars[i + 1].isLetter {
                return true
            }
        }
        return false
    }

    private static func repairToken(_ token: String, isLast: Bool) -> String {
        if token.contains(where: \.isNumber) || token.contains("://") || token.contains("@") || token.contains("/") {
            return token
        }

        // Handle quote-adjacent inflection glitches like `"tuning"s` → `"tunings"`
        let chars = Array(token)
        if let firstQuote = chars.first, (firstQuote == "\"" || firstQuote == "'"),
           let closeIdx = chars.dropFirst().firstIndex(of: firstQuote),
           closeIdx + 1 < chars.count
        {
            let suffix = String(chars[(closeIdx + 1)...]).trimmingCharacters(in: CharacterSet(charactersIn: ".,?!;:"))
            if inflections.contains(suffix.lowercased()) {
                let inner = String(chars[1..<closeIdx])
                let afterSuffix = String(chars[(closeIdx + 1)...].dropFirst(suffix.count))
                return "\(firstQuote)\(inner)\(suffix)\(firstQuote)\(afterSuffix)"
            }
        }

        for i in 1..<max(1, chars.count - 1) {
            let c = chars[i]
            guard (c == "," || c == ";" || c == ":") && chars[i - 1].isLetter && chars[i + 1].isLetter else {
                continue
            }
            let left = String(chars[..<i])
            let rightRaw = String(chars[(i + 1)...])
            let rightCore = rightRaw.prefix(while: \.isLetter)
            let rightTrailing = String(rightRaw.dropFirst(rightCore.count))
            let rightLower = rightCore.lowercased()

            if inflections.contains(rightLower) {
                // "tuning,s" → "tunings," mid-sentence, or "tunings" at end if no trailing period
                let mark = (!rightTrailing.isEmpty || isLast) ? "" : String(c)
                return left + String(rightCore) + mark + rightTrailing
            } else {
                // Separate accidentally glued words like "hello,world" → "hello, world"
                return "\(left)\(c) \(rightRaw)"
            }
        }
        return token
    }

    /// Full cleanup pipeline applied after ASR/Fuser output.
    static func clean(
        _ text: String,
        options: TuningOptions,
        lowercasePreservingTerms: [String] = [],
        replacements: [WordReplacement] = []
    ) -> String {
        var working = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !working.isEmpty else { return "" }

        // Strip any leaked model reasoning tags if an LLM ever slipped.
        working = stripReasoningArtifacts(working)

        if options.smartPunctuationCleanup {
            working = repairMidWordPunctuation(working)
            // Fix space before punctuation: "word ," → "word," and "word ." → "word."
            working = collapseSpaceBeforePunctuation(working)
        }

        if !replacements.isEmpty {
            working = applyReplacements(working, replacements: replacements)
        }

        var tokens = working.split(whereSeparator: \.isWhitespace).map(String.init)

        if options.removeFillers {
            tokens = stripFillers(tokens)
        }

        if options.collapseStutters {
            tokens = stripStutters(tokens)
        }

        if options.smartPunctuationCleanup {
            tokens = fixSentenceCapitalization(tokens, preservedTerms: lowercasePreservingTerms)
        }

        var result = tokens.joined(separator: " ")
        if options.smartPunctuationCleanup {
            result = collapseSpaceBeforePunctuation(result)
            // Drop trailing standalone comma at the very end of an utterance.
            if result.hasSuffix(",") {
                result.removeLast()
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func stripReasoningArtifacts(_ text: String) -> String {
        var out = text
        let patterns = [
            #"(?s)<think>.*?</think>"#,
            #"(?s)<\|channel>thought.*?<channel\|>"#,
            #"<channel\|>"#,
            #"<turn\|>"#,
            #"<\|im_end\|>"#,
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(out.startIndex..<out.endIndex, in: out)
                out = regex.stringByReplacingMatches(in: out, range: range, withTemplate: "")
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func collapseSpaceBeforePunctuation(_ text: String) -> String {
        var out = text
        // Only remove spaces before punctuation when followed by whitespace, end-of-string,
        // or another punctuation/closing char — never before letters/digits like ".env".
        out = regexReplace(out, pattern: #"\s+([.,?!;:])(?=\s|$|[.,?!;:\"'\)\]])"#, with: "$1")
        out = regexReplace(out, pattern: #",,+"#, with: ",")
        out = regexReplace(out, pattern: #",\.(?![A-Za-z0-9_])"#, with: ".")
        out = regexReplace(out, pattern: #"\.,(?![A-Za-z0-9_])"#, with: ".")
        return out
    }

    private static func regexReplace(_ text: String, pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    private static func stripFillers(_ tokens: [String]) -> [String] {
        var out: [String] = []
        var capitalizeNext = false

        for token in tokens {
            let core = String(token.lowercased().filter { $0.isLetter || $0.isNumber })
            let leading = String(token.prefix(while: { !$0.isLetter && !$0.isNumber }))
            let trailing = String(token.reversed().prefix(while: { !$0.isLetter && !$0.isNumber }).reversed())

            if fillers.contains(core) && leading.isEmpty && trailing.allSatisfy({ ".,?!;:".contains($0) }) {
                if out.isEmpty || (out.last?.last.map { ".?!".contains($0) } ?? false) {
                    capitalizeNext = true
                }
                // Preserve terminal sentence punctuation if the filler ended the sentence.
                if let terminal = trailing.first(where: { ".?!".contains($0) }),
                   let prev = out.last,
                   !(prev.last.map { ".?!".contains($0) } ?? false)
                {
                    out[out.count - 1] = prev.trimmingCharacters(in: CharacterSet(charactersIn: ",;:")) + String(terminal)
                    capitalizeNext = true
                }
                continue
            }

            var adjusted = token
            if capitalizeNext {
                adjusted = capitalizeFirstLetter(adjusted)
                capitalizeNext = false
            }
            out.append(adjusted)
        }
        return out
    }

    private static func stripStutters(_ tokens: [String]) -> [String] {
        var out: [String] = []
        for token in tokens {
            if let prev = out.last {
                let prevTail = prev.last
                let prevHasPunct = prevTail.map { ".,?!;:".contains($0) } ?? false
                let prevKey = String(prev.lowercased().filter { $0.isLetter || $0.isNumber })
                let currKey = String(token.lowercased().filter { $0.isLetter || $0.isNumber })
                if !prevHasPunct && !prevKey.isEmpty && prevKey == currKey {
                    // Replace the previous bare token with the current one (preserving any trailing punct on current).
                    out[out.count - 1] = prev.first?.isUppercase == true ? capitalizeFirstLetter(token) : token
                    continue
                }
            }
            out.append(token)
        }
        return out
    }

    private static func fixSentenceCapitalization(_ tokens: [String], preservedTerms: [String]) -> [String] {
        guard !tokens.isEmpty else { return tokens }
        let lowercaseTerms = Set(preservedTerms.filter { term in
            guard let first = term.first else { return false }
            return first.isLowercase || first == "."
        }.map { $0.lowercased() })

        var out = tokens
        var expectCap = true

        for i in out.indices {
            let token = out[i]
            let bareLower = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,?!;:\"'()")).lowercased()
            let startsPathOrDotfile = token.hasPrefix(".") || token.hasPrefix("/") || token.hasPrefix("~")
            if expectCap && !startsPathOrDotfile && !lowercaseTerms.contains(bareLower) {
                out[i] = capitalizeFirstLetter(token)
            }
            let lower = token.lowercased()
            if abbreviations.contains(lower) {
                expectCap = false
            } else if let last = token.last, ".?!".contains(last) {
                // Only treat as end of sentence if not a decimal/dotted domain/version like 2.1 or Next.js
                let core = String(token.dropLast())
                let isDottedToken = core.contains(".") || token.contains(where: \.isNumber) && last != "."
                expectCap = !isDottedToken
            } else {
                expectCap = false
            }
        }
        return out
    }

    private static func applyReplacements(_ text: String, replacements: [WordReplacement]) -> String {
        let active = replacements
            .filter { $0.enabled && !$0.spoken.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.spoken.count > $1.spoken.count }
        guard !active.isEmpty else { return text }

        var tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        for rule in active {
            let spokenWords = rule.spoken.split(whereSeparator: \.isWhitespace).map {
                String($0.lowercased().filter { $0.isLetter || $0.isNumber })
            }.filter { !$0.isEmpty }
            guard !spokenWords.isEmpty else { continue }

            var i = 0
            while i + spokenWords.count <= tokens.count {
                let window = Array(tokens[i..<i + spokenWords.count])
                let windowKeys = window.map { String($0.lowercased().filter { $0.isLetter || $0.isNumber }) }
                // Don't cross sentence punctuation inside a multi-word spoken phrase.
                let internalPunct = window.dropLast().contains { tok in
                    tok.last.map { ".?!,;".contains($0) } ?? false
                }
                if !internalPunct && windowKeys == spokenWords {
                    let leading = String(window.first!.prefix(while: { !$0.isLetter && !$0.isNumber && $0 != "." }))
                    let trailing = String(window.last!.reversed().prefix(while: { !$0.isLetter && !$0.isNumber }).reversed())
                    let replacement = leading + rule.written + trailing
                    tokens.replaceSubrange(i..<i + spokenWords.count, with: [replacement])
                }
                i += 1
            }
        }
        return tokens.joined(separator: " ")
    }

    private static func capitalizeFirstLetter(_ s: String) -> String {
        guard let idx = s.firstIndex(where: { $0.isLetter || $0.isNumber }) else { return s }
        var chars = Array(s)
        let pos = s.distance(from: s.startIndex, to: idx)
        if chars[pos].isLetter && chars[pos].isLowercase {
            chars[pos] = Character(chars[pos].uppercased())
        }
        return String(chars)
    }
}
