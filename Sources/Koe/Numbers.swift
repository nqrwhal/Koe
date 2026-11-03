import Foundation

/// Reads spoken numbers, so "twenty thirty-two" from Bark and "2032" from Qwen count as the same
/// words rather than a disagreement for Gemma. Bark spells numbers out; Qwen writes them the way
/// you would type them ("PR 2032", "port 8080", "2.1", but "four engineers"), so its form is kept.
enum Numbers {
    /// Whether the two spans say the same thing once numbers are read as values. Only spans with
    /// digits on at least one side count, so "time-limited" against "time limited" is still Gemma's.
    static func same(_ a: [String], _ b: [String]) -> Bool {
        guard digits(a) + digits(b) > 0 else { return false }
        return !readings(a).isDisjoint(with: readings(b))
    }

    static func digits(_ words: [String]) -> Int {
        words.reduce(0) { $0 + $1.filter(\.isNumber).count }
    }

    private static let units = ["zero": 0, "oh": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
                                "six": 6, "seven": 7, "eight": 8, "nine": 9]
    private static let teens = ["ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
                                "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19]
    private static let tens = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70,
                               "eighty": 80, "ninety": 90]
    private static let scales = ["thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000]

    /// Every way to read the span, as space-separated tokens with each run of number words
    /// replaced by its digits: a span has a few runs at most, and each run one or two readings.
    private static func readings(_ words: [String]) -> Set<String> {
        var results: Set<String> = [""]
        var run: [String] = []
        func add(_ options: Set<String>) {
            results = Set(results.flatMap { prefix in options.map { prefix.isEmpty ? $0 : prefix + " " + $0 } })
        }
        func endRun() {
            if !run.isEmpty { add(numberReadings(run)); run = [] }
        }
        for word in words {
            for token in tokens(word) {
                if isNumberWord(token, inRun: !run.isEmpty) { run.append(token) } else { endRun(); add([token]) }
            }
            // "In 2021, 500 people" is two numbers, and so is Qwen's broken "30, 000": that one
            // then stays a disagreement for Gemma, which writes "30,000".
            if let last = word.last, ",;".contains(last) { endRun() }
        }
        endRun()
        return results
    }

    /// Lowercased, without punctuation; "thirty-two" splits in two, "2,032" loses its comma,
    /// "3:30" its colon, and "20%" becomes "20 percent".
    private static func tokens(_ word: String) -> [String] {
        var word = word.lowercased()
        let percent = word.hasSuffix("%")
        word = String(word.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." })
        while word.hasSuffix(".") { word.removeLast() }  // a sentence's period, not a decimal point
        var parts = word.split(separator: "-").map(String.init)
        if percent { parts.append("percent") }
        return parts.filter { !$0.isEmpty }
    }

    private static func isNumberWord(_ token: String, inRun: Bool) -> Bool {
        if token.first?.isNumber == true { return token.allSatisfy { $0.isNumber || $0 == "." } }
        if token == "oh" || token == "point" { return inRun }  // "four oh four", "two point one"
        return units[token] != nil || teens[token] != nil || tens[token] != nil || token == "hundred" || scales[token] != nil
    }

    /// "two thousand thirty two" → 2032, "twenty thirty two" → 2032, "three forty seven" → 347,
    /// "two point one" → 2.1, "145 million" → 145000000.
    private static func numberReadings(_ run: [String]) -> Set<String> {
        if let point = run.firstIndex(of: "point") {
            guard let whole = cardinal(Array(run[..<point])) ?? digitGroups(Array(run[..<point])),
                  let fraction = digitGroups(Array(run[(point + 1)...])) else { return [run.joined(separator: " ")] }
            return ["\(whole).\(fraction)"]
        }
        let options = Set([cardinal(run), digitGroups(run)].compactMap { $0 })
        return options.isEmpty ? [run.joined(separator: " ")] : options
    }

    /// The usual reading, with digits allowed in place of words ("145 million").
    private static func cardinal(_ run: [String]) -> String? {
        var total = 0, current = 0
        var group = 0  // what was said since the last "hundred": tens and units must come in order
        for token in run {
            if let value = Int(token) {
                guard current == 0 else { return nil }
                current = value
            } else if let value = units[token], token != "oh" {
                guard group % 10 == 0, group < 100, current % 100 == group else { return nil }
                current += value; group += value
                if value == 0 && current != 0 { return nil }
            } else if let value = teens[token] {
                guard group == 0 else { return nil }
                current += value; group = 100
            } else if let value = tens[token] {
                guard group == 0 else { return nil }
                current += value; group = value
            } else if token == "hundred" {
                guard current > 0, current < 100 else { return nil }
                current *= 100; group = 0
            } else if let scale = scales[token] {
                guard current > 0 else { return nil }
                total += current * scale; current = 0; group = 0
            } else {
                return nil
            }
        }
        return spelled(total + current, from: run)
    }

    /// Digits read group by group, as in years, ports and issue numbers: "twenty thirty two",
    /// "eighty eighty", "four oh four", "nineteen hundred". Needs at least two groups.
    private static func digitGroups(_ run: [String]) -> String? {
        var groups: [String] = []
        var index = 0
        while index < run.count {
            let token = run[index]
            if let unit = units[token] {
                groups.append(String(unit))
            } else if let teen = teens[token] {
                groups.append(String(teen))
            } else if let ten = tens[token] {
                if index + 1 < run.count, let unit = units[run[index + 1]], unit > 0 {
                    groups.append(String(ten + unit)); index += 1
                } else {
                    groups.append(String(ten))
                }
            } else if token == "hundred", let last = groups.last, last.count <= 2 {
                groups[groups.count - 1] = last + "00"
            } else if token.allSatisfy(\.isNumber) {
                groups.append(token)
            } else {
                return nil
            }
            index += 1
        }
        return groups.count >= 2 ? groups.joined() : (run.count == 1 ? groups.first : nil)
    }

    /// A run that is one digit token keeps its own spelling ("007" stays "007").
    private static func spelled(_ value: Int, from run: [String]) -> String {
        run.count == 1 && Int(run[0]) != nil ? run[0] : String(value)
    }
}
