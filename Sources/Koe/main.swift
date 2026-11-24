import AppKit
import AVFoundation
import Dispatch
import FluidAudio

private func runCLI(_ body: @escaping @Sendable () async throws -> Int32) -> Never {
    Task {
        do {
            let code = try await body()
            exit(code)
        } catch {
            FileHandle.standardError.write("Error: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }
    dispatchMain()
}

let args = Array(CommandLine.arguments.dropFirst())

// koe --self-test : run fast deterministic unit checks on TextCleaner, Disagreements, Vocabulary, Numbers.
if args.contains("--self-test") {
    runCLI {
        @Sendable func check(_ cond: Bool, _ msg: String) {
            if !cond {
                FileHandle.standardError.write("FAIL: \(msg)\n".data(using: .utf8)!)
                exit(1)
            }
        }
        let opts = TuningOptions()
        let personal = ["Koe", "Wispr Flow", "Qwen"]
        let speller = Speller(terms: personal + Vocabulary.builtIn, personal: personal)
        let repls = ReplacementStore.defaultsTemplate

        // 1. Intra-word punctuation repair: "tuning,s"
        let fixed1 = TextCleaner.clean(
            "Some things are maybe slightly better UI and UX, better settings, tuning,s maybe like lower overall memory usage.",
            options: opts, lowercasePreservingTerms: Vocabulary.builtIn, replacements: repls
        )
        check(!fixed1.contains("tuning,s"), "tuning,s should be repaired, got: \(fixed1)")
        check(fixed1.contains("tunings,"), "tuning,s should become tunings,, got: \(fixed1)")

        // 2. Personal vocabulary deterministic match: "Whisper Flow" -> "Wispr Flow"
        let norm2 = speller.normalize("Basically, I want to be closer to other voice keyboards like Whisper Flow.")
        check(norm2.contains("Wispr Flow"), "Whisper Flow should normalize to Wispr Flow, got: \(norm2)")

        // 3. Disagreements alignment: Qwen rogue comma & mid-sentence cap & "tuning,s"
        let dis = Disagreements(
            a: "While maintaining on-device dictation.",
            b: "While maintaining on device, dictation.",
            terms: personal,
            baseHasNativePunctuation: true
        )
        let disJoined = Disagreements.join(dis.sentences().map(\.b))
        check(!disJoined.contains("device,"), "Spurious comma after device should be dropped, got: \(disJoined)")

        let dis2 = Disagreements(
            a: "While maintaining on device dictation.",
            b: "While maintaining on device, dictation.",
            terms: personal,
            baseHasNativePunctuation: true
        )
        let dis2Joined = Disagreements.join(dis2.sentences().map(\.b))
        check(!dis2Joined.contains("device,"), "Spurious comma after unhyphenated device should be dropped, got: \(dis2Joined)")

        let disCap = Disagreements(
            a: "And finally, the last one.",
            b: "And Finally, the last one.",
            terms: personal,
            baseHasNativePunctuation: true
        )
        let disCapJoined = Disagreements.join(disCap.sentences().map(\.b))
        check(disCapJoined == "And finally, the last one.", "Mid-sentence cap should be fixed, got: \(disCapJoined)")

        let disRoguePeriod = Disagreements(
            a: "Basically I want to be closer to other voice keyboards.",
            b: "Basically, um, I want to. Be closer to other voice keyboards.",
            terms: personal,
            baseHasNativePunctuation: true
        )
        let disRogueJoined = Disagreements.join(disRoguePeriod.sentences().map(\.b))
        check(!disRogueJoined.contains("to. Be"), "Rogue mid-clip period after 'to' should be dropped, got: \(disRogueJoined)")

        // 4. Lowercase after period + filler/stutter cleanup
        let fixed4 = TextCleaner.clean(
            "Um, we need the the logging. if it fails, uh, dot env is ready.",
            options: opts, lowercasePreservingTerms: Vocabulary.builtIn, replacements: repls
        )
        check(fixed4 == "We need the logging. If it fails, .env is ready.", "Cleanup mismatch, got: \(fixed4)")

        // 5. Preserve numbers, dotted technical terms, and sentence-start dotfiles
        let fixed5 = TextCleaner.clean(
            "Use Next.js and 30,000 rows on port 8080.",
            options: opts, lowercasePreservingTerms: Vocabulary.builtIn, replacements: repls
        )
        check(fixed5 == "Use Next.js and 30,000 rows on port 8080.", "Preservation mismatch, got: \(fixed5)")

        let fixed6 = TextCleaner.clean(
            "dot env is ready.",
            options: opts, lowercasePreservingTerms: Vocabulary.builtIn, replacements: repls
        )
        check(fixed6 == ".env is ready.", "Sentence-start dotfile mismatch, got: \(fixed6)")

        // 6. KeyBinding JSON round-trip and display names
        let chord = KeyBinding.defaultPasteLast
        let encodedChord = try JSONEncoder().encode(chord)
        let decodedChord = try JSONDecoder().decode(KeyBinding.self, from: encodedChord)
        check(decodedChord == chord && decodedChord.displayName == "⌥⇧V", "KeyBinding round-trip failed: \(decodedChord.displayName)")
        check(KeyBinding.defaultDictation.displayName == "Right ⌘", "Default dictation display mismatch")

        // 7. Paster spacing preparation
        check(Paster.prepareText("  Hello world.  ", spacing: .none) == "Hello world.", "Spacing .none failed")
        check(Paster.prepareText("Hello world.", spacing: .trailingSpace) == "Hello world. ", "Spacing .trailingSpace failed")

        // 8. HistoryStore persistence round-trip in temp directory
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("koe-selftest-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        await MainActor.run {
            let store = HistoryStore(fileURL: tempURL)
            store.append(HistoryEntry(
                text: "Test transcript",
                baseText: "test transcript",
                qwenText: nil,
                route: "ane-solo",
                durationSeconds: 1.5,
                tailMs: 28,
                baseMs: 28,
                qwenMs: 0,
                fuseMs: 0,
                segments: 1,
                modelSummary: "Parakeet Unified"
            ))
            let reloaded = HistoryStore(fileURL: tempURL)
            check(reloaded.entries.count == 1 && reloaded.entries.first?.text == "Test transcript", "HistoryStore round-trip failed")
        }

        print("ALL SELF-TESTS PASSED")
        return 0
    }
}

// koe --install-models : download every model up front (used by install.sh).
if args.contains("--install-models") {
    var fuser: FuserModel = .qwen3_1_7b
    var includeGPU = true
    var i = 0
    while i < args.count {
        if args[i] == "--fuser", i + 1 < args.count, let parsed = FuserModel(rawValue: args[i + 1]) {
            fuser = parsed
            i += 1
        } else if args[i] == "--ane-only" {
            includeGPU = false
        }
        i += 1
    }
    let selectedFuser = fuser
    let withGPU = includeGPU
    runCLI {
        await ModelInstaller.run(fuser: selectedFuser, includeGPU: withGPU)
    }
}

// koe --eval [--mode ane-solo|hybrid] [--base unified-stream|unified-batch|bark]
//            [--fuser qwen3-0.6b|qwen3.5-0.8b|qwen3-1.7b|gemma4-e2b|gemma4-e4b]
//            [--no-ctc] [--whole] [--no-clean] file.wav...
if let evalIdx = args.firstIndex(of: "--eval") {
    var opts = TuningOptions()
    var files: [String] = []
    var i = evalIdx + 1
    while i < args.count {
        switch args[i] {
        case "--mode":
            if i + 1 < args.count, let v = EngineMode(rawValue: args[i + 1]) { opts.engineMode = v; i += 1 }
        case "--base":
            if i + 1 < args.count, let v = BaseModel(rawValue: args[i + 1]) { opts.baseModel = v; i += 1 }
        case "--fuser":
            if i + 1 < args.count, let v = FuserModel(rawValue: args[i + 1]) { opts.fuserModel = v; i += 1 }
        case "--no-ctc":
            opts.ctcVocabBoosting = false
        case "--whole":
            opts.wholeDictationOnly = true
        case "--no-clean":
            opts.smartPunctuationCleanup = false
            opts.removeFillers = false
            opts.collapseStutters = false
        case "--min-seg":
            if i + 1 < args.count, let v = Double(args[i + 1]) { opts.minSegmentSeconds = v; i += 1 }
        case "--pause":
            if i + 1 < args.count, let v = Double(args[i + 1]) { opts.pauseThresholdSeconds = v; i += 1 }
        default:
            files.append(args[i])
        }
        i += 1
    }
    if files.isEmpty {
        FileHandle.standardError.write("No wav files given to --eval\n".data(using: .utf8)!)
        exit(2)
    }
    let evalOpts = opts
    let evalFiles = files
    runCLI {
        let pipeline = await MainActor.run { Pipeline(options: evalOpts) }
        try await pipeline.loadInitial(options: evalOpts) { _ in }
        await pipeline.loadRest(options: evalOpts) { msg in
            FileHandle.standardError.write("\(msg)\n".data(using: .utf8)!)
        }

        let audioConverter = AudioConverter()
        for path in evalFiles {
            let samples = try audioConverter.resampleAudioFile(URL(fileURLWithPath: path))
            let audioSeconds = Double(samples.count) / 16_000.0

            let outcome: LiveTranscription.Outcome
            if evalOpts.wholeDictationOnly && samples.count <= 30 * 16_000 {
                let start = Date()
                let r = try await pipeline.transcribe(samples, options: evalOpts)
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                outcome = LiveTranscription.Outcome(text: r.text, segments: [r], tailMs: ms)
            } else {
                let live = await pipeline.startLive(options: evalOpts)!
                for start in stride(from: 0, to: samples.count, by: 160) {
                    live.append(Array(samples[start..<min(start + 160, samples.count)]))
                }
                await live.stop()
                await live.settle()
                outcome = try await live.finish(samples)
            }

            let last = outcome.segments.last
            let mem = MemoryMonitor.current()
            let row: [String: Any] = [
                "file": URL(fileURLWithPath: path).lastPathComponent,
                "audio_s": (audioSeconds * 100).rounded() / 100,
                "text": outcome.text,
                "base_text": outcome.segments.map(\.baseText).joined(separator: " "),
                "qwen_text": outcome.segments.compactMap(\.qwenText).joined(separator: " "),
                "segments": outcome.segments.count,
                "ms": outcome.tailMs,
                "route": last?.route ?? "none",
                "base_ms": outcome.segments.map(\.baseMs).reduce(0, +),
                "qwen_ms": outcome.segments.map(\.qwenMs).reduce(0, +),
                "fuse_ms": outcome.segments.map(\.fuseMs).reduce(0, +),
                "footprint_mb": mem.footprintMB,
                "mlx_active_mb": mem.mlxActiveMB,
                "mlx_cache_mb": mem.mlxCacheMB,
            ]
            print(String(data: try JSONSerialization.data(withJSONObject: row), encoding: .utf8)!)
        }
        return 0
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
