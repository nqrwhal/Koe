#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Terms Koe should spell right, from two lists:
/// - **yours**, in ~/Library/Application Support/Koe/vocabulary.txt. Koe checks for these even when
///   both recognizers agree on something close ("whisper flow" → "Wispr Flow").
/// - **built-in** developer and AI tooling. Used for exact spellings (see ``Speller``) and to settle
///   words the recognizers disagree on, never to change words they both heard, so a plain sentence
///   about a "studio" can't turn into one about "LM Studio".
enum Vocabulary {
    static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Koe/vocabulary.txt")

    private static let personalTemplate = """
        # Your own words and names, one per line (or comma-separated).
        # Koe spells these your way even when both recognizers agree on something close,
        # e.g. "whisper flow" becomes "Wispr Flow". Developer and AI tooling is built in.
        Koe
        Wispr Flow
        Qwen
        """

    static let builtIn = parse("""
        Claude, Claude Code, Anthropic, OpenAI, ChatGPT, GPT, Codex, Gemini, Copilot, GitHub Copilot, Cursor, Windsurf
        Ollama, LM Studio, llama.cpp, MLX, Hugging Face, Transformers, LangChain, LlamaIndex, vLLM, PyTorch, TensorFlow, JAX
        CUDA, Core ML, Metal, Whisper, Parakeet, Qwen, Gemma, Llama, Mistral, DeepSeek, Grok, Perplexity, Midjourney, ComfyUI
        LLM, MCP, MCP server, RAG, embeddings, vector database, pgvector, Pinecone, LoRA, fine-tune, quantization, tokenizer
        subagent, prompt caching, Stable Diffusion
        Python, TypeScript, JavaScript, Rust, Go, Swift, SwiftUI, Kotlin, Node.js, Bun, Deno, React, React Native, Next.js, Vite
        Svelte, SvelteKit, Vue, Nuxt, Astro, Remix, Expo, Flutter, Tauri, Electron, Tailwind, shadcn, Radix, Zod, tRPC, Prisma
        Drizzle, webpack
        Homebrew, npm, pnpm, Yarn, uv, pip, Poetry, conda, Cargo, Xcode, Swift Package Manager, Jupyter, tmux, zsh, Neovim, Vim
        Ghostty, iTerm, Warp, Raycast, VS Code, Zed, Linear, Jira, Notion, Figma, Slack, Discord, Postman, curl, jq, ripgrep, fzf
        GitHub, GitHub Actions, GitLab, rebase, monorepo, repo, PR, CI/CD, CI, lint, ESLint, Prettier, pytest, Jest, Vitest
        Playwright
        Docker, Dockerfile, Docker Compose, Kubernetes, kubectl, k8s, Helm, Terraform, Pulumi, AWS, GCP, Azure, S3, EC2, ECR
        IAM, VPC, ALB, Lambda, Cloudflare, Cloudflare Workers, Wrangler, Vercel, Netlify, Fly.io, Railway, Render, Supabase
        Firebase, Neon, nginx, Postgres, PostgreSQL, MySQL, SQLite, DuckDB, ClickHouse, Redis, MongoDB, DynamoDB, Kafka
        RabbitMQ, Elasticsearch, Sentry, Datadog, Grafana, Prometheus, OpenTelemetry
        API, REST, GraphQL, gRPC, WebSocket, JSON, YAML, TOML, HTTP, HTTPS, CORS, OAuth, OIDC, JWT, SSO, SAML, SSH, TLS, DNS
        ASCII, Unicode, UTF-8
        CDN, SDK, CLI, env, stdin, stdout, stderr, localhost, regex, cron, async, await, webhook, useEffect, useState
        idempotency key, exponential backoff
        """)

    /// Your list, created with a few examples the first time.
    static func loadPersonal() -> [String] {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? personalTemplate.write(to: url, atomically: true, encoding: .utf8)
        }
        return parse((try? String(contentsOf: url, encoding: .utf8)) ?? personalTemplate)
    }

    static func savePersonal(_ terms: [String]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let cleaned = terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let body = """
            # Your own words and names, one per line (or comma-separated).
            # Koe spells these your way even when both recognizers agree on something close,
            # e.g. "whisper flow" becomes "Wispr Flow". Developer and AI tooling is built in.
            """ + "\n" + cleaned.joined(separator: "\n") + "\n"
        try? body.write(to: url, atomically: true, encoding: .utf8)
    }

    static func parse(_ text: String) -> [String] {
        text.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// A span of words that almost spells a term but not exactly, e.g. "whisper flow" for "Wispr Flow".
    /// Both recognizers can agree on such a mistake, so it still needs Gemma's judgment.
    static func nearMiss(in words: [String], terms: [String]) -> (Range<Int>, String)? {
        for term in terms {
            let target = letters(term)
            guard target.count >= 4 else { continue }
            // Casing alone only matters for terms like "GitHub" or "JSON", not "Swift" or "react".
            let distinctiveCase = term != term.lowercased() && term != term.capitalized
            let n = term.split(separator: " ").count
            for size in max(1, n - 1)...(n + 1) where size <= words.count {
                for start in 0...(words.count - size) {
                    let window = words[start..<start + size].joined(separator: " ")
                    let core = window.trimmingCharacters(in: .punctuationCharacters)
                    let candidate = letters(window)
                    // Fuzzy matches only for longer terms: one edit turns "just" into "Rust".
                    let fuzzy = target.count >= 6 && similarity(candidate, target) >= 0.75
                    if candidate == target ? distinctiveCase && core != term : fuzzy {
                        return (start..<start + size, term)
                    }
                }
            }
        }
        return nil
    }

    /// The few terms that could be what the speaker said, judged by spelling against the words in
    /// `texts`. Gemma only sees these, so a long vocabulary costs nothing and can't tempt it into
    /// swapping in an unrelated term. Built-in terms need a closer match than the user's own:
    /// "congee" (heard for "kanji", 50% similar) must not bring in "conda", while "ngingle" (57%)
    /// should still bring in "nginx".
    static func relevant(to texts: [String], personal: [String], builtIn: [String], limit: Int = 15) -> [String] {
        var windows: Set<String> = []
        for text in texts {
            let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { letters(String($0)) }
            for size in 1...3 where size <= words.count {
                for start in 0...(words.count - size) { windows.insert(words[start..<start + size].joined()) }
            }
        }
        var scored: [(term: String, score: Double)] = []
        for (terms, threshold) in [(personal, 0.5), (builtIn, 0.55)] {
            for term in terms {
                let target = letters(term)
                if windows.contains(target) {
                    scored.append((term, 1))  // same letters, maybe different spacing or casing ("j w t", "github")
                } else if target.count >= 4,
                          let best = windows.lazy.filter({ abs($0.count - target.count) <= 3 }).map({ similarity($0, target) }).max(),
                          best >= threshold {
                    scored.append((term, best))
                }
            }
        }
        return scored.sorted { $0.score > $1.score }.prefix(limit).map(\.term)
    }

    static func letters(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// 1 − normalized edit distance.
    static func similarity(_ a: String, _ b: String) -> Double {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var prev = row[0]
            row[0] = i
            for j in 1...max(b.count, 1) where !b.isEmpty {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = current
            }
        }
        return 1 - Double(row[b.count]) / Double(max(a.count, b.count, 1))
    }
}

/// Free spelling fixes applied to both transcripts before they're compared. Common jargon then
/// needs no LLM, and the recognizers agree more often, which keeps dictations on the fast path:
/// - spelled-out letters become an acronym: "J W T" → "JWT", "m. c. p." → "MCP";
/// - words whose letters exactly match a term with its own casing take that spelling:
///   "github" → "GitHub", "grpc" → "gRPC", "next js" → "Next.js";
/// - high-confidence matches against the user's personal vocabulary ("whisper flow" → "Wispr Flow")
///   are fixed deterministically even in ANE-only mode.
struct Speller {
    private var spellings: [String: (term: String, words: Set<Int>)] = [:]  // keyed by letters
    private let personalRules: [(term: String, letters: String, wordCount: Int, allowSingleEnglish: Bool)]

    /// Call on the main thread (it consults the system spell checker).
    init(terms: [String], personal: [String] = []) {
        #if os(macOS)
        let checker = NSSpellChecker.shared
        #else
        let checker = UITextChecker()
        #endif
        func isEnglishWord(_ word: String) -> Bool {
            #if os(macOS)
            return checker.checkSpelling(of: word, startingAt: 0, language: "en", wrap: false,
                                         inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
            #else
            return checker.rangeOfMisspelledWord(
                in: word, range: NSRange(location: 0, length: word.utf16.count),
                startingAt: 0, wrap: false, language: "en").location == NSNotFound
            #endif
        }

        for term in terms {
            let letters = Vocabulary.letters(term)
            guard letters.count >= 3, term != term.lowercased(), term != term.capitalized,
                  spellings[letters] == nil else { continue }
            guard !isEnglishWord(letters) else { continue }
            let count = term.split(separator: " ").count
            // "Next.js" and "CI/CD" are spoken as two words ("next js", "ci cd").
            spellings[letters] = (term, term.contains(where: { $0 == "." || $0 == "/" }) ? [count, count + 1] : [count])
        }

        var rules: [(term: String, letters: String, wordCount: Int, allowSingleEnglish: Bool)] = []
        for term in personal {
            let letters = Vocabulary.letters(term)
            guard letters.count >= 2 else { continue }
            let wordCount = max(1, term.split(separator: " ").count)
            let allowSingleEnglish = !isEnglishWord(letters) || term != term.lowercased() && term != term.capitalized
            rules.append((term: term, letters: letters, wordCount: wordCount, allowSingleEnglish: allowSingleEnglish))
        }
        self.personalRules = rules
    }

    func normalize(_ text: String) -> String {
        var words = Self.joiningSpelledLetters(text.split(whereSeparator: \.isWhitespace).map(String.init))
        var out: [String] = []
        var i = 0
        next: while i < words.count {
            for size in stride(from: 3, through: 1, by: -1) where i + size <= words.count {
                let window = words[i..<i + size]
                // Never join words across punctuation ("next. JS").
                if window.dropLast().contains(where: { $0.last.map(Self.isPunctuation) ?? false }) { continue }
                guard let entry = spellings[Vocabulary.letters(window.joined())], entry.words.contains(size) else { continue }
                let leading = String(window.first!.prefix(while: Self.isPunctuation))
                let trailing = String(window.last!.reversed().prefix(while: Self.isPunctuation).reversed())
                out.append(leading + entry.term + trailing)
                i += size
                continue next
            }
            out.append(words[i])
            i += 1
        }
        words = out

        // Apply personal vocabulary deterministic fixes (exact or >= 0.80 similarity for >= 6-char terms).
        guard !personalRules.isEmpty else { return words.joined(separator: " ") }
        var pOut: [String] = []
        var j = 0
        nextPersonal: while j < words.count {
            for rule in personalRules {
                let sizes = Array(Set([rule.wordCount, max(1, rule.wordCount - 1), rule.wordCount + 1])).sorted(by: >)
                for size in sizes where j + size <= words.count {
                    let window = words[j..<j + size]
                    if window.dropLast().contains(where: { $0.last.map(Self.isPunctuation) ?? false }) { continue }
                    let candidate = Vocabulary.letters(window.joined())
                    guard !candidate.isEmpty else { continue }
                    let exact = (candidate == rule.letters) && (size > 1 || rule.allowSingleEnglish || window.joined().lowercased().filter(\.isLetter) == rule.letters)
                    let fuzzy = rule.letters.count >= 6 && abs(candidate.count - rule.letters.count) <= 3
                        && Vocabulary.similarity(candidate, rule.letters) >= 0.80
                        && (size > 1 || rule.allowSingleEnglish)
                    if exact || fuzzy {
                        let leading = String(window.first!.prefix(while: Self.isPunctuation))
                        let trailing = String(window.last!.reversed().prefix(while: Self.isPunctuation).reversed())
                        pOut.append(leading + rule.term + trailing)
                        j += size
                        continue nextPersonal
                    }
                }
            }
            pOut.append(words[j])
            j += 1
        }
        return pOut.joined(separator: " ")
    }

    /// Runs of two or more single letters ("J W T", "o. a. u. t. h.") are spelled-out acronyms.
    private static func joiningSpelledLetters(_ words: [String]) -> [String] {
        var out: [String] = []
        var run: [String] = []
        func flush(keepFinalDot: Bool) {
            defer { run = [] }
            guard run.count >= 2 else { out += run; return }
            var trailing = String(run.last!.reversed().prefix(while: isPunctuation).reversed())
            // "t. d." mid-sentence: the dots belong to the letters, not to the sentence.
            if trailing == "." && !keepFinalDot { trailing = "" }
            out.append(run.compactMap { $0.first(where: \.isLetter) }.map(String.init).joined().uppercased() + trailing)
        }
        for word in words {
            let core = word.filter { $0.isLetter || $0.isNumber }
            let punctuation = word.filter(isPunctuation)
            guard core.count == 1, core.first!.isLetter, word.first!.isLetter, punctuation.count <= 1 else {
                flush(keepFinalDot: word.first?.isUppercase ?? true)
                out.append(word)
                continue
            }
            run.append(word)
            if let mark = punctuation.first, mark != "." { flush(keepFinalDot: true) }  // "T," ends the run
        }
        flush(keepFinalDot: true)
        return out
    }

    private static func isPunctuation(_ c: Character) -> Bool { !c.isLetter && !c.isNumber }
}
