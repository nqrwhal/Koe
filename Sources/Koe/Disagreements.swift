import Foundation

/// Lines up Qwen's transcript (B: verbatim, strong formatting/numbers) against the base ANE
/// transcript (A: Parakeet Unified or Bark 3.0 Clean) word by word. Fillers and repeats only B has
/// are dropped, numbers spelled differently ("twenty thirty-two", "2032") count as agreeing, and
/// punctuation/casing glitches on agreed words are reconciled rather than blindly taking B.
/// Remaining differences, plus spans where B nearly spells a vocabulary term, go to the Fuser LLM
/// sentence by sentence, and ``merge(_:into:)`` restricts the LLM's edits strictly to those spans.
struct Disagreements {
    struct Sentence {
        let a: String  // with the alternative reading at each choice
        let b: String  // base-cleaned reading
        let disputed: Bool
        /// Both readings of every disputed span, for picking relevant vocabulary.
        let disputedText: String
        fileprivate let slots: [Slot]
    }

    /// One of the aligned words, marked by whether the recognizers disagreed there. A disputed slot
    /// with no text marks a place where only A heard something.
    fileprivate struct Slot {
        let text: String
        let disputed: Bool
        var alternative = ""  // A's reading of the disputed span this slot belongs to
    }

    /// Keeps Fuser's answer only where the recognizers disagreed. Words both of them heard come
    /// back as aligned, and nothing is added between them or dropped.
    static func merge(_ fused: String, into group: some Sequence<Sentence>) -> String {
        let cleanedFused = TextCleaner.repairMidWordPunctuation(TextCleaner.stripReasoningArtifacts(fused))
        let slots = group.flatMap(\.slots)
        let words = cleanedFused.split(whereSeparator: \.isWhitespace).map(String.init)
        let pairs = match(slots.map { key($0.text) }, words.map(key))
        var out: [String] = []
        var s = 0, w = 0
        for (ms, mw) in pairs + [(slots.count, words.count)] {
            // Between two matches: slots s..<ms that Fuser didn't keep, and words w..<mw it wrote instead.
            let gap = slots[s..<ms]
            let answer = Array(words[w..<mw])
            let qwen = gap.filter(\.disputed).map(\.text).filter { !$0.isEmpty }
            var altSpans: [String] = []
            for slot in gap where slot.disputed && altSpans.last != slot.alternative { altSpans.append(slot.alternative) }
            let alt = altSpans.joined(separator: " ").split(whereSeparator: \.isWhitespace)
            // An answer much longer than both readings is hallucinated/looping: fall back to B.
            let plausible = answer.count <= max(qwen.count, alt.count) + 2
            var answered = false
            for slot in gap {
                if !slot.disputed {
                    out.append(slot.text)
                } else if !answered {
                    out += plausible ? answer : qwen
                    answered = true
                }
            }
            let besideDispute = (s > 0 && slots[s - 1].disputed) || (ms < slots.count && slots[ms].disputed)
            if !answered && besideDispute && answer.count <= 2 { out += answer }
            if ms < slots.count { out.append(slots[ms].disputed ? words[mw] : slots[ms].text) }
            s = ms + 1
            w = mw + 1
        }
        return out.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private enum Piece {
        case word(String)
        /// `alternative`: A's words, or the vocabulary term for a near miss. `fallback`: B's words.
        case choice(alternative: String, fallback: String, trailing: String)
    }

    private(set) var choiceCount = 0
    private var pieces: [Piece] = []

    /// Standalone hesitation fillers A drops that B sometimes preserves.
    private static let fillers: Set<String> = ["um", "uh", "uhm", "er", "erm", "hmm", "mm", "mhm"]

    /// Function words after which ASR models frequently insert spurious pause commas.
    private static let commaProneFunctionWords: Set<String> = [
        "on", "in", "at", "to", "for", "with", "from", "by", "of", "about", "into", "onto", "upon",
        "through", "during", "between", "among", "against", "without", "within", "some", "any",
        "every", "no", "the", "a", "an", "this", "that", "these", "those", "my", "your", "our",
        "their", "his", "her", "its", "and", "or", "but", "nor", "yet", "is", "are", "was", "were",
        "be", "been", "being", "have", "has", "had", "do", "does", "did", "can", "could", "will",
        "would", "should", "may", "might", "must", "like", "very", "really", "just", "quite",
    ]

    init(a: String, b: String, terms: [String], baseHasNativePunctuation: Bool = true) {
        let cleanA = TextCleaner.repairMidWordPunctuation(a)
        let cleanB = TextCleaner.repairMidWordPunctuation(b)
        let aWords = cleanA.split(whereSeparator: \.isWhitespace).map(String.init)
        let bWords = cleanB.split(whereSeparator: \.isWhitespace).map(String.init)
        let pairs = Self.match(aWords.map(Self.key), bWords.map(Self.key))

        var i = 0, j = 0
        var lastEmittedWord: String?

        for (mi, mj) in pairs + [(aWords.count, bWords.count)] {
            var gapB: [String] = []
            for k in j..<mj {
                let key = Self.key(bWords[k])
                let previous = gapB.last.map(Self.key) ?? (k > 0 ? Self.key(bWords[k - 1]) : nil)
                if key.isEmpty || Self.fillers.contains(key) || key == previous { continue }
                gapB.append(bWords[k])
            }
            let gapA = aWords[i..<mi].filter { !Self.key($0).isEmpty }
            if !gapA.isEmpty && !gapB.isEmpty && Numbers.same(gapA, gapB) {
                // "twenty thirty-two" and "2032" agree: keep the form with digits.
                let chosen = Numbers.digits(gapA) > Numbers.digits(gapB) ? Array(gapA) : gapB
                pieces += chosen.map(Piece.word)
                lastEmittedWord = chosen.last
            } else if !gapA.isEmpty && !gapB.isEmpty && Self.sameJoinedLetters(gapA, gapB) {
                // Hyphenated / split-compound agreement ("on-device" vs "on device,", "built-in" vs "built in"):
                // avoid an unnecessary LLM call and prefer the hyphenated compound without spurious mid-phrase comma.
                let aJoined = gapA.joined(separator: " ")
                let bJoined = gapB.joined(separator: " ")
                let preferA = (gapA.count == 1 && aJoined.contains("-"))
                    || (baseHasNativePunctuation && Self.trailingPunct(bJoined) == "," && Self.trailingPunct(aJoined).isEmpty)
                let chosen: [String]
                if preferA {
                    var arr = Array(gapA)
                    let trailB = Self.trailingPunct(bJoined)
                    if (trailB == "." || trailB == "?" || trailB == "!"),
                       let last = arr.last, Self.trailingPunct(last).isEmpty
                    {
                        arr[arr.count - 1] = last + trailB
                    }
                    chosen = arr
                } else {
                    chosen = gapB
                }
                pieces += chosen.map(Piece.word)
                lastEmittedWord = chosen.last
            } else if !gapA.isEmpty || !gapB.isEmpty {
                addChoice(a: gapA.joined(separator: " "), b: gapB)
                lastEmittedWord = gapB.last ?? gapA.last
            }
            if mj < bWords.count {
                let nextIsLowerA = (mi + 1 < aWords.count) && (aWords[mi + 1].first?.isLowercase ?? false)
                let word = Self.chooseAgreedWord(
                    a: aWords[mi],
                    b: bWords[mj],
                    prevWord: lastEmittedWord,
                    nextIsLowerA: nextIsLowerA,
                    isNearEnd: mj >= bWords.count - 2,
                    isMidClip: mj < bWords.count - 1,
                    baseHasNativePunctuation: baseHasNativePunctuation
                )
                pieces.append(.word(word))
                lastEmittedWord = word
            }
            i = mi + 1
            j = mj + 1
        }
        markNearMisses(terms: terms)
    }

    /// Reconciles casing and punctuation when both recognizers heard the exact same word.
    private static func chooseAgreedWord(
        a: String,
        b: String,
        prevWord: String?,
        nextIsLowerA: Bool,
        isNearEnd: Bool,
        isMidClip: Bool,
        baseHasNativePunctuation: Bool
    ) -> String {
        // Guard against any residual intra-word punctuation.
        let safeB = hasMidWordPunctuation(b) ? TextCleaner.repairMidWordPunctuation(b) : b
        let safeA = hasMidWordPunctuation(a) ? TextCleaner.repairMidWordPunctuation(a) : a

        // 1. Choose base word spelling/casing.
        var chosenCore = stripOuterPunct(safeB)
        let coreA = stripOuterPunct(safeA)
        let coreB = chosenCore

        let aHasDistinctiveCase = coreA != coreA.lowercased() && coreA != coreA.capitalized
        let bHasDistinctiveCase = coreB != coreB.lowercased() && coreB != coreB.capitalized
        let afterSentenceEnd = prevWord?.last.map { ".?!".contains($0) } ?? true

        if aHasDistinctiveCase && !bHasDistinctiveCase {
            chosenCore = coreA
        } else if !afterSentenceEnd && !bHasDistinctiveCase && coreB.first?.isUppercase == true && coreA.first?.isLowercase == true {
            // Qwen randomly capitalized a mid-sentence word ("And Finally," or after a suppressed rogue ".") that A kept lowercase.
            chosenCore = coreA
        } else if afterSentenceEnd && coreB.first?.isLowercase == true && coreA.first?.isUppercase == true && !aHasDistinctiveCase {
            chosenCore = coreA
        }

        // Preserve hyphenated compounds when A has a hyphen ("on-device") and B split or kept it unhyphenated.
        if coreA.contains("-") && !coreB.contains("-") && key(coreA) == key(coreB) {
            chosenCore = coreA
        }

        // 2. Choose leading/trailing punctuation.
        let leadB = String(safeB.prefix(while: { !$0.isLetter && !$0.isNumber }))
        let trailA = trailingPunct(safeA)
        var trailB = trailingPunct(safeB)

        // Mid-clip period truncation guard: if B ended with "." mid-clip while A did not end a sentence
        // and A continues lowercase (or the word is a dangling function word like "to." / "we."), drop B's period.
        if isMidClip && trailB == "." && !".?!".contains(trailA) {
            let lowerCore = coreB.lowercased()
            if trailA == "," {
                trailB = ","
            } else if baseHasNativePunctuation && (nextIsLowerA || commaProneFunctionWords.contains(lowerCore)) {
                trailB = ""
            }
        }

        // Spurious comma filter: B put "," where A had none.
        if trailB == "," && trailA.isEmpty {
            let lowerCore = coreB.lowercased()
            if commaProneFunctionWords.contains(lowerCore) {
                trailB = ""
            } else if baseHasNativePunctuation && (isNearEnd || prevWord == nil) {
                // Parakeet Unified rarely misses real pauses near start/end; Qwen often inserts hesitation commas ("on device, dictation").
                trailB = ""
            }
        }

        return leadB + chosenCore + trailB
    }

    private static func sameJoinedLetters(_ a: [String], _ b: [String]) -> Bool {
        let ja = a.map(key).joined()
        let jb = b.map(key).joined()
        return !ja.isEmpty && ja == jb
    }

    private static func hasMidWordPunctuation(_ word: String) -> Bool {
        TextCleaner.hasMidWordPunctuation(word)
    }

    private static func stripOuterPunct(_ word: String) -> String {
        var s = word
        while let first = s.first, !first.isLetter && !first.isNumber && first != "." {
            s.removeFirst()
        }
        while let last = s.last, ".,?!;:\"'()".contains(last) {
            s.removeLast()
        }
        return s.isEmpty ? word : s
    }

    private static func trailingPunct(_ word: String) -> String {
        String(word.reversed().prefix(while: { ".,?!;:\"'()".contains($0) }).reversed())
    }

    func sentences() -> [Sentence] {
        var result: [Sentence] = []
        var a: [String] = [], b: [String] = [], slots: [Slot] = [], disputedText: [String] = []
        var disputed = false
        func flush() {
            if !b.isEmpty || !a.isEmpty {
                result.append(Sentence(a: a.joined(separator: " "), b: b.joined(separator: " "), disputed: disputed,
                                       disputedText: disputedText.joined(separator: " "), slots: slots))
            }
            a = []; b = []; slots = []; disputedText = []; disputed = false
        }
        for piece in pieces {
            switch piece {
            case .word(let w):
                a.append(w); b.append(w)
                slots.append(Slot(text: w, disputed: false))
            case .choice(let alternative, let fallback, let trailing):
                disputed = true
                let alternative = Self.ending(alternative, with: trailing), fallback = Self.ending(fallback, with: trailing)
                if !alternative.isEmpty { a.append(alternative) }
                if !fallback.isEmpty { b.append(fallback) }
                slots += fallback.isEmpty
                    ? [Slot(text: "", disputed: true, alternative: alternative)]
                    : fallback.split(whereSeparator: \.isWhitespace).map { Slot(text: String($0), disputed: true, alternative: alternative) }
                disputedText += [alternative, fallback]
            }
            if let last = b.last?.last, ".?!".contains(last) { flush() }
        }
        flush()
        return result
    }

    /// Joins sentences into the final text, capitalizing the first letter.
    static func join(_ sentences: [String]) -> String {
        let joined = sentences.filter { !$0.isEmpty }.joined(separator: " ")
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }

    private static func ending(_ text: String, with trailing: String) -> String {
        guard !trailing.isEmpty, let last = text.last, !".,?!;:".contains(last) else { return text }
        return text + trailing
    }

    private mutating func addChoice(a: String, b: [String]) {
        let trailing = b.last.flatMap { $0.last }.map { ".,?!;:".contains($0) ? String($0) : "" } ?? ""
        choiceCount += 1
        pieces.append(.choice(alternative: a, fallback: b.joined(separator: " "), trailing: trailing))
    }

    /// Agreed words that nearly spell a vocabulary term ("whisper flow" for "Wispr Flow") become choices too.
    private mutating func markNearMisses(terms: [String]) {
        var index = 0
        while index < pieces.count {
            var run: [String] = []
            var end = index
            while end < pieces.count, case .word(let w) = pieces[end] { run.append(w); end += 1 }
            if let (range, term) = Vocabulary.nearMiss(in: run, terms: terms) {
                let span = run[range].joined(separator: " ")
                let trailing = span.last.map { ".,?!;:".contains($0) ? String($0) : "" } ?? ""
                choiceCount += 1
                pieces.replaceSubrange((index + range.lowerBound)..<(index + range.upperBound),
                                       with: [.choice(alternative: term, fallback: span, trailing: trailing)])
                continue  // rescan this run
            }
            index = end + 1
        }
    }

    private static func key(_ word: String) -> String {
        String(word.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// Longest common subsequence of the two key lists, as index pairs.
    private static func match(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = !a[i].isEmpty && a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < a.count && j < b.count {
            if !a[i].isEmpty && a[i] == b[j] { pairs.append((i, j)); i += 1; j += 1 }
            else if table[i + 1][j] >= table[i][j + 1] { i += 1 }
            else { j += 1 }
        }
        return pairs
    }
}
