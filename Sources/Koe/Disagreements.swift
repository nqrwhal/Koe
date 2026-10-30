import Foundation

/// Lines up Qwen's transcript (B: verbatim, good casing) against Bark's (A: drops fillers and
/// repeats) word by word. Fillers and repeats only B has are dropped; the remaining differences,
/// plus spans where B nearly spells a vocabulary term, are the choices Gemma needs to settle.
/// Results come sentence by sentence, so Gemma only sees the sentences that contain a choice,
/// and ``merge(_:into:)`` keeps its answer to exactly those choices.
struct Disagreements {
    struct Sentence {
        let a: String  // with the alternative reading at each choice
        let b: String  // Qwen's cleaned reading
        let disputed: Bool
        /// Both readings of every disputed span, for picking relevant vocabulary.
        let disputedText: String
        fileprivate let slots: [Slot]
    }

    /// One of Qwen's words, marked by whether the recognizers disagreed there. A disputed slot
    /// with no text marks a place where only Bark heard something.
    fileprivate struct Slot {
        let text: String
        let disputed: Bool
    }

    /// Keeps Gemma's answer only where the recognizers disagreed. Words both of them heard come
    /// back exactly as Qwen wrote them, and nothing is added between them or dropped, so a fusion
    /// can fix "cubectile" but can't turn "my studio" into "my LM Studio" or lose "computer use".
    static func merge(_ fused: String, into group: some Sequence<Sentence>) -> String {
        let slots = group.flatMap(\.slots)
        let words = fused.split(separator: " ").map(String.init)
        let pairs = match(slots.map { key($0.text) }, words.map(key))
        var out: [String] = []
        var s = 0, w = 0
        for (ms, mw) in pairs + [(slots.count, words.count)] {
            // Between two matches: Qwen's slots s..<ms that Gemma didn't keep, and words w..<mw it wrote instead.
            let gap = slots[s..<ms]
            var answered = false
            for slot in gap {
                if !slot.disputed {
                    out.append(slot.text)  // a word both recognizers heard: always restored
                } else if !answered {
                    out += words[w..<mw]
                    answered = true
                }
            }
            let besideDispute = (s > 0 && slots[s - 1].disputed) || (ms < slots.count && slots[ms].disputed)
            if !answered && besideDispute { out += words[w..<mw] }
            if ms < slots.count { out.append(slots[ms].disputed ? words[mw] : slots[ms].text) }
            s = ms + 1
            w = mw + 1
        }
        return out.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private enum Piece {
        case word(String)
        /// `alternative`: Bark's words, or the vocabulary term for a near miss. `fallback`: Qwen's words.
        case choice(alternative: String, fallback: String, trailing: String)
    }

    private(set) var choiceCount = 0
    private var pieces: [Piece] = []

    /// Words Bark drops; when B has one that A lacks, it is removed without asking Gemma.
    private static let fillers: Set<String> = ["um", "uh", "uhm", "ah", "er", "erm", "hmm", "mm", "mhm", "like", "oh"]

    init(a: String, b: String, terms: [String]) {
        let aWords = a.split(separator: " ").map(String.init)
        let bWords = b.split(separator: " ").map(String.init)
        let pairs = Self.match(aWords.map(Self.key), bWords.map(Self.key))

        var i = 0, j = 0
        for (mi, mj) in pairs + [(aWords.count, bWords.count)] {
            var gapB: [String] = []
            for k in j..<mj {
                let key = Self.key(bWords[k])
                let previous = gapB.last.map(Self.key) ?? (k > 0 ? Self.key(bWords[k - 1]) : nil)
                if key.isEmpty || Self.fillers.contains(key) || key == previous { continue }
                gapB.append(bWords[k])
            }
            let gapA = aWords[i..<mi].filter { !Self.key($0).isEmpty }
            if !gapA.isEmpty || !gapB.isEmpty {
                addChoice(a: gapA.joined(separator: " "), b: gapB)
            }
            if mj < bWords.count { pieces.append(.word(bWords[mj])) }
            i = mi + 1
            j = mj + 1
        }
        markNearMisses(terms: terms)
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
                    ? [Slot(text: "", disputed: true)]
                    : fallback.split(separator: " ").map { Slot(text: String($0), disputed: true) }
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
