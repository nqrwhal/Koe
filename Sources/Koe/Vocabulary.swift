import Foundation

/// Developer and personal terms that both Qwen and Gemma are biased toward.
/// Editable as one term per line in ~/Library/Application Support/Koe/vocabulary.txt.
enum Vocabulary {
    static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Koe/vocabulary.txt")

    private static let defaults = """
        # One term per line. Koe biases transcription toward these spellings.
        Koe
        Wispr Flow
        Qwen
        API, JSON, YAML, gRPC, REST, GraphQL, tRPC, HTTP, HTTPS, CORS, OAuth, OIDC, JWT, SSO, SAML, SSH, TLS, DNS, CDN
        CI/CD, CI, PR, LLM, SDK, CLI, env, stdin, stdout, stderr, npm, pnpm, Node.js, Next.js, React, useEffect, useState
        TypeScript, JavaScript, Tailwind, Vite, webpack, Zod, Prisma, Postgres, PostgreSQL, MySQL, SQLite, Redis, MongoDB
        DynamoDB, Kafka, S3, EC2, ECR, IAM, VPC, ALB, Lambda, Terraform, Kubernetes, kubectl, Helm, Docker, Dockerfile
        nginx, GitHub, GitHub Actions, GitLab, Vercel, Cloudflare, pytest, Python, Rust, Go, Swift, Xcode, webhook
        async, await, regex, cron, localhost, repo, monorepo, rebase, idempotency key, exponential backoff
        """

    static func load() -> [String] {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? defaults.write(to: url, atomically: true, encoding: .utf8)
        }
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? defaults
        return text.split(separator: "\n")
            .filter { !$0.hasPrefix("#") }
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

    private static func letters(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// 1 − normalized edit distance.
    private static func similarity(_ a: String, _ b: String) -> Double {
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
