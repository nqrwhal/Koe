import FluidAudio
import Foundation
import MLX

/// Orchestrates on-device speech recognition across ANE-Solo and Hybrid modes:
/// - **ANE Solo**: Parakeet Unified 0.6B (Neural Engine) + optional CTC Vocabulary Boosting + Speller + TextCleaner.
/// - **Hybrid**: Base ANE recognizer ∥ Qwen3-ASR 0.6B (GPU), reconciled on disputed sentences by a small MLX Fuser LLM.
///
/// Tracks idle time and automatically unloads GPU models (Qwen3-ASR + Fuser) after inactivity to keep RAM low.
final class Pipeline {
    struct ModelSyncEvent: Sendable {
        enum Phase: Sendable {
            case loading
            case ready
            case error
        }

        let phase: Phase
        let message: String
        let progress: Double?
        let baseReady: Bool
    }

    struct Result: Sendable {
        let text: String
        let baseText: String
        let qwenText: String?
        let route: String  // "ane-solo", "base-only", "agree", "fuse", "qwen-fallback"
        let choices: Int
        let baseMs: Int
        let qwenMs: Int
        let fuseMs: Int
        let modelSummary: String
    }

    private let base = Transcriber()
    private let qwen = QwenTranscriber()
    private let fuser = Fuser()
    private var vad: VadManager?

    private var options: TuningOptions
    private var personal: [String]
    private var terms: [String]
    private var speller: Speller
    private var replacements: [WordReplacement]
    private var vocabModDate: Date?
    private var replacementsModDate: Date?

    private let stateLock = NSLock()
    private var lastActivity = Date()
    private var idleWatcher: Task<Void, Never>?
    private var gpuReloadTask: Task<Void, Never>?

    /// Create on the main thread (``Speller`` consults `NSSpellChecker`).
    init(options: TuningOptions = TuningOptions()) {
        self.options = options
        let personal = Vocabulary.loadPersonal()
        var seen = Set<String>()
        let terms = (personal + Vocabulary.builtIn).filter { seen.insert($0.lowercased()).inserted }
        self.personal = personal
        self.terms = terms
        self.speller = Speller(terms: terms, personal: personal)
        self.replacements = ReplacementStore.load()
        self.vocabModDate = Self.modDate(for: Vocabulary.url)
        self.replacementsModDate = Self.modDate(for: ReplacementStore.url)
    }

    var currentOptions: TuningOptions {
        stateLock.withLock { options }
    }

    func updateOptions(_ newOptions: TuningOptions) {
        stateLock.withLock { options = newOptions }
    }

    /// Reloads personal vocabulary and replacements if modified on disk.
    @MainActor
    func reloadVocabularyIfNeeded(force: Bool = false) async {
        let vDate = Self.modDate(for: Vocabulary.url)
        let rDate = Self.modDate(for: ReplacementStore.url)
        let vocabChanged = force || vDate != vocabModDate
        let replChanged = force || rDate != replacementsModDate
        guard vocabChanged || replChanged else { return }

        if vocabChanged {
            let newPersonal = Vocabulary.loadPersonal()
            var seen = Set<String>()
            let newTerms = (newPersonal + Vocabulary.builtIn).filter { seen.insert($0.lowercased()).inserted }
            let newSpeller = Speller(terms: newTerms, personal: newPersonal)
            stateLock.withLock {
                self.personal = newPersonal
                self.terms = newTerms
                self.speller = newSpeller
                self.vocabModDate = vDate
            }
            let opts = currentOptions
            if opts.ctcVocabBoosting && opts.engineMode == .aneSolo {
                await base.configureVocabularyBoosting(terms: newPersonal)
            }
        }
        if replChanged {
            let newRepl = ReplacementStore.load()
            stateLock.withLock {
                self.replacements = newRepl
                self.replacementsModDate = rDate
            }
        }
    }

    private static func modDate(for url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    var isBaseLoaded: Bool {
        get async { await base.isLoaded }
    }

    func syncIdleTimer() {
        startIdleWatcher()
    }

    func loadInitial(options: TuningOptions? = nil, progress: @escaping @Sendable (Double) -> Void) async throws {
        if let options { updateOptions(options) }
        let opts = currentOptions
        let backend = Transcriber.Backend(rawValue: opts.baseModel.rawValue) ?? .parakeetUnifiedStreaming
        let currentPersonal = stateLock.withLock { personal }
        let ctcTerms: [String]? = (opts.engineMode == .aneSolo && opts.ctcVocabBoosting) ? currentPersonal : nil
        try await base.load(backend: backend, ctcTerms: ctcTerms, progress: progress)
        if vad == nil {
            vad = try? await VadManager()
        }
    }

    /// Backwards-compatible alias for CLI callers.
    func loadBark(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await loadInitial(progress: progress)
    }

    /// Loads secondary GPU models when in Hybrid mode, or unloads them in ANE Solo mode.
    func loadRest(options: TuningOptions? = nil, status: @escaping @Sendable (String) -> Void) async {
        if let options { updateOptions(options) }
        let opts = currentOptions
        guard opts.engineMode == .hybrid else {
            await unloadGPU()
            status("Ready (ANE Solo)")
            return
        }

        MLX.Memory.cacheLimit = Fuser.defaultCacheLimitBytes
        do {
            status("Loading Qwen3-ASR…")
            try await qwen.load()
            status("Loading \(opts.fuserModel.displayName)…")
            try await fuser.load(opts.fuserModel)
            touchActivity()
            startIdleWatcher()
            status("Ready")
        } catch {
            log.error("GPU model load failed: \(error, privacy: .public)")
            status("Some GPU models failed to load")
        }
    }

    /// Reconciles loaded ANE and GPU models with `newOptions` and reports throttled progress/state events.
    func syncModels(_ newOptions: TuningOptions, onEvent: @escaping @Sendable (ModelSyncEvent) -> Void) async {
        updateOptions(newOptions)
        let targetBackend = Transcriber.Backend(rawValue: newOptions.baseModel.rawValue) ?? .parakeetUnifiedStreaming
        let currentPersonal = stateLock.withLock { personal }
        let hasValidPersonal = currentPersonal.contains {
            let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.count >= 4 && !trimmed.contains("/")
        }
        let supportsCTC = targetBackend == .parakeetUnifiedStreaming || targetBackend == .parakeetUnifiedBatch
        let wantsCTC = newOptions.engineMode == .aneSolo && newOptions.ctcVocabBoosting && supportsCTC && hasValidPersonal

        log.info(
            "Model sync starting: mode=\(newOptions.engineMode.rawValue, privacy: .public) base=\(newOptions.baseModel.rawValue, privacy: .public) fuser=\(newOptions.fuserModel.rawValue, privacy: .public) ctc=\(wantsCTC, privacy: .public)"
        )

        let baseLoadedBackend = await base.loadedBackend
        let baseHasCTC = await base.hasVocabularyBoosting
        let needBaseReload = baseLoadedBackend != targetBackend || wantsCTC != baseHasCTC

        if needBaseReload {
            let wasBaseReady = await base.isLoaded
            onEvent(ModelSyncEvent(
                phase: .loading,
                message: "Loading \(newOptions.baseModel.shortName)…",
                progress: nil,
                baseReady: wasBaseReady
            ))
            let baseProgress = Self.makeThrottledProgress(
                label: newOptions.baseModel.shortName,
                baseReady: wasBaseReady,
                onEvent: onEvent
            )
            do {
                try await loadInitial(options: newOptions, progress: baseProgress)
            } catch {
                log.error("Base model load failed (\(newOptions.baseModel.rawValue, privacy: .public)): \(error, privacy: .public)")
                onEvent(ModelSyncEvent(
                    phase: .error,
                    message: "Failed to load \(newOptions.baseModel.shortName): \(error.localizedDescription)",
                    progress: nil,
                    baseReady: await base.isLoaded
                ))
                return
            }
        } else if vad == nil {
            vad = try? await VadManager()
        }

        guard newOptions.engineMode == .hybrid else {
            await unloadGPU()
            log.info("Model sync ready: ANE Solo (\(newOptions.baseModel.rawValue, privacy: .public))")
            onEvent(ModelSyncEvent(
                phase: .ready,
                message: "Ready (ANE Solo)",
                progress: nil,
                baseReady: true
            ))
            return
        }

        MLX.Memory.cacheLimit = Fuser.defaultCacheLimitBytes
        do {
            if !(await qwen.isLoaded) {
                onEvent(ModelSyncEvent(
                    phase: .loading,
                    message: "Loading Qwen3-ASR…",
                    progress: nil,
                    baseReady: true
                ))
                let qwenProgress = Self.makeThrottledProgress(
                    label: "Qwen3-ASR",
                    baseReady: true,
                    onEvent: onEvent
                )
                try await qwen.load(progress: qwenProgress)
            }

            if await fuser.currentModel != newOptions.fuserModel {
                let label = newOptions.fuserModel.displayName
                onEvent(ModelSyncEvent(
                    phase: .loading,
                    message: "Loading \(label)…",
                    progress: nil,
                    baseReady: true
                ))
                let fuserProgress = Self.makeThrottledProgress(
                    label: label,
                    baseReady: true,
                    onEvent: onEvent
                )
                try await fuser.load(newOptions.fuserModel, progress: fuserProgress)
            }

            touchActivity()
            startIdleWatcher()
            log.info("Model sync ready: Hybrid (\(newOptions.baseModel.rawValue, privacy: .public) + \(newOptions.fuserModel.rawValue, privacy: .public))")
            onEvent(ModelSyncEvent(
                phase: .ready,
                message: "Ready",
                progress: nil,
                baseReady: true
            ))
        } catch {
            log.error("GPU model load failed: \(error, privacy: .public)")
            onEvent(ModelSyncEvent(
                phase: .error,
                message: "GPU model load failed (\(error.localizedDescription)) — using ANE fallback",
                progress: nil,
                baseReady: true
            ))
        }
    }

    /// Hot-applies updated model settings from the UI without restarting Koe.
    func applyModelChanges(_ newOptions: TuningOptions, status: @escaping @Sendable (String) -> Void) async {
        await syncModels(newOptions) { event in
            status(event.message)
        }
    }

    private final class ProgressGate: @unchecked Sendable {
        private let lock = NSLock()
        private var lastPercent = -1

        func shouldEmit(_ percent: Int) -> Bool {
            lock.withLock {
                guard percent != lastPercent else { return false }
                lastPercent = percent
                return true
            }
        }
    }

    private static func makeThrottledProgress(
        label: String,
        baseReady: Bool,
        onEvent: @escaping @Sendable (ModelSyncEvent) -> Void
    ) -> @Sendable (Double) -> Void {
        let gate = ProgressGate()
        return { fraction in
            guard fraction.isFinite, fraction >= 0.005, fraction < 0.995 else { return }
            let pct = Int(fraction * 100)
            guard gate.shouldEmit(pct) else { return }
            onEvent(ModelSyncEvent(
                phase: .loading,
                message: "Downloading \(label)… \(pct)%",
                progress: fraction,
                baseReady: baseReady
            ))
        }
    }

    /// Starts a live transcription session using either continuous ANE streaming or conservative pause cuts.
    func startLive(options overrideOptions: TuningOptions? = nil) async -> LiveTranscription? {
        let opts = overrideOptions ?? currentOptions
        let baseStreaming = await base.supportsStreamingSession
        if opts.engineMode == .aneSolo && opts.baseModel.supportsNativeStreaming && baseStreaming {
            return LiveTranscription(pipeline: self, vad: vad, options: opts, nativeStreaming: true)
        }
        guard let vad else { return nil }
        return LiveTranscription(pipeline: self, vad: vad, options: opts, nativeStreaming: false)
    }

    func warmUp() async {
        let opts = currentOptions
        _ = try? await base.transcribe([Float](repeating: 0, count: 16_000), sampleRate: 16_000)
        if opts.engineMode == .hybrid {
            if await qwen.isLoaded {
                _ = await qwen.transcribe([Float](repeating: 0, count: 16_000))
            }
            if await fuser.isLoaded {
                _ = await fuser.fuse("ok", "ok", draft: "ok", context: nil, vocabulary: [])
            }
        }
        MLX.Memory.clearCache()
    }

    /// Called on key press: wakes GPU or triggers reload if GPU models were auto-unloaded while idle.
    func wakeGPU() {
        let opts = currentOptions
        touchActivity()
        guard opts.engineMode == .hybrid else { return }
        Task {
            let qwenLoaded = await qwen.isLoaded
            let fuserModel = await fuser.currentModel
            if qwenLoaded && fuserModel == opts.fuserModel {
                _ = await qwen.transcribe([Float](repeating: 0, count: 8_000))
            } else {
                await ensureHybridLoaded(opts)
            }
        }
    }

    func unloadGPU() async {
        idleWatcher?.cancel()
        idleWatcher = nil
        await qwen.unload()
        await fuser.unload()
    }

    private func ensureHybridLoaded(_ opts: TuningOptions) async {
        if let existing = gpuReloadTask {
            await existing.value
            return
        }
        let task = Task {
            try? await qwen.load()
            try? await fuser.load(opts.fuserModel)
            touchActivity()
            startIdleWatcher()
        }
        gpuReloadTask = task
        await task.value
        gpuReloadTask = nil
    }

    private func touchActivity() {
        stateLock.withLock { lastActivity = Date() }
    }

    private func startIdleWatcher() {
        idleWatcher?.cancel()
        let minutes = currentOptions.idleUnloadMinutes
        guard minutes > 0, currentOptions.engineMode == .hybrid else {
            idleWatcher = nil
            return
        }
        idleWatcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled else { return }
                let opts = self.currentOptions
                guard opts.idleUnloadMinutes > 0, opts.engineMode == .hybrid else { return }
                let elapsed = self.stateLock.withLock { Date().timeIntervalSince(self.lastActivity) }
                if elapsed >= TimeInterval(opts.idleUnloadMinutes * 60) {
                    let qwenLoaded = await self.qwen.isLoaded
                    let fuserLoaded = await self.fuser.isLoaded
                    if qwenLoaded || fuserLoaded {
                        log.info("Idle for \(opts.idleUnloadMinutes, privacy: .public)m — unloading GPU models to save RAM")
                        await self.unloadGPU()
                    }
                    return
                }
            }
        }
    }

    // MARK: - Streaming Base Delegation

    func beginBaseStream() async throws { try await base.beginStream() }
    func appendBaseStream(_ samples: [Float]) async throws { try await base.appendStreamSamples(samples, sampleRate: 16_000) }
    func processBaseStream() async throws { try await base.processStream() }
    func partialBaseStreamText() async -> String { await base.partialStreamText() }
    func finishBaseStream() async throws -> String { try await base.finishStream() }
    func cancelBaseStream() async { await base.cancelStream() }

    func finishNativeStreamResult(rawBase: String, baseMs: Int, options: TuningOptions) async -> Result {
        await reloadVocabularyIfNeeded()
        touchActivity()
        let (spellerSnap, termsSnap, replSnap) = stateLock.withLock { (speller, terms, replacements) }
        let normalized = spellerSnap.normalize(rawBase)
        let cleaned = TextCleaner.clean(
            normalized,
            options: options,
            lowercasePreservingTerms: termsSnap,
            replacements: replSnap
        )
        return Result(
            text: cleaned,
            baseText: rawBase,
            qwenText: nil,
            route: "ane-solo",
            choices: 0,
            baseMs: baseMs,
            qwenMs: 0,
            fuseMs: 0,
            modelSummary: "\(options.baseModel.shortName)\(options.ctcVocabBoosting ? " + CTC" : "")"
        )
    }

    func cleanFinalText(_ text: String, options: TuningOptions) -> String {
        let (termsSnap, replSnap) = stateLock.withLock { (terms, replacements) }
        return TextCleaner.clean(text, options: options, lowercasePreservingTerms: termsSnap, replacements: replSnap)
    }

    func continues(_ previous: String, _ next: String, relaxed: Bool = false) async -> Bool {
        await fuser.continues(previous, next, relaxed: relaxed) ?? false
    }

    /// Expects 16 kHz mono samples. `context` is the final text preceding this piece, if any.
    func transcribe(_ samples: [Float], context preceding: String? = nil, options overrideOptions: TuningOptions? = nil) async throws -> Result {
        await reloadVocabularyIfNeeded()
        touchActivity()
        let opts = overrideOptions ?? currentOptions
        let (personalSnap, termsSnap, spellerSnap, replSnap) = stateLock.withLock {
            (personal, terms, speller, replacements)
        }

        if opts.engineMode == .aneSolo {
            let (rawBase, baseMs) = try await timed { try await self.base.transcribe(samples, sampleRate: 16_000) }
            let normalized = spellerSnap.normalize(rawBase)
            let cleaned = TextCleaner.clean(
                normalized,
                options: opts,
                lowercasePreservingTerms: termsSnap,
                replacements: replSnap
            )
            return Result(
                text: cleaned,
                baseText: rawBase,
                qwenText: nil,
                route: "ane-solo",
                choices: 0,
                baseMs: baseMs,
                qwenMs: 0,
                fuseMs: 0,
                modelSummary: "\(opts.baseModel.shortName)\(opts.ctcVocabBoosting ? " + CTC" : "")"
            )
        }

        // Hybrid mode: ensure GPU models are loaded if they were auto-unloaded while idle.
        let qwenLoaded = await qwen.isLoaded
        let fuserModel = await fuser.currentModel
        if !qwenLoaded || fuserModel != opts.fuserModel {
            await ensureHybridLoaded(opts)
        }

        async let baseRun = timed { try await self.base.transcribe(samples, sampleRate: 16_000) }
        async let qwenRun = timed { await self.qwen.transcribe(samples) }
        let (rawA, baseMs) = try await baseRun
        let (rawB, qwenMs) = await qwenRun
        let a = spellerSnap.normalize(rawA)

        guard let rawB, !rawB.isEmpty else {
            let cleaned = TextCleaner.clean(a, options: opts, lowercasePreservingTerms: termsSnap, replacements: replSnap)
            return Result(
                text: cleaned,
                baseText: rawA,
                qwenText: nil,
                route: "base-only",
                choices: 0,
                baseMs: baseMs,
                qwenMs: qwenMs,
                fuseMs: 0,
                modelSummary: opts.baseModel.shortName
            )
        }

        let b = spellerSnap.normalize(rawB)
        let disagreements = Disagreements(
            a: a,
            b: b,
            terms: personalSnap,
            baseHasNativePunctuation: opts.baseModel.hasNativePunctuation
        )
        let count = disagreements.choiceCount
        let sentences = disagreements.sentences()
        let modelSummary = "\(opts.baseModel.shortName) ∥ Qwen3-ASR → \(opts.fuserModel.displayName)"

        if count == 0 {
            let joined = Disagreements.join(sentences.map(\.b))
            let cleaned = TextCleaner.clean(joined, options: opts, lowercasePreservingTerms: termsSnap, replacements: replSnap)
            return Result(
                text: cleaned,
                baseText: rawA,
                qwenText: rawB,
                route: "agree",
                choices: 0,
                baseMs: baseMs,
                qwenMs: qwenMs,
                fuseMs: 0,
                modelSummary: modelSummary
            )
        }

        var parts: [String] = []
        var fuseMs = 0
        var fellBack = false
        var index = 0
        while index < sentences.count {
            guard sentences[index].disputed else {
                parts.append(sentences[index].b)
                index += 1
                continue
            }
            var end = index
            while end < sentences.count && sentences[end].disputed { end += 1 }
            let group = sentences[index..<end]
            let groupA = group.map(\.a).joined(separator: " ")
            let groupB = group.map(\.b).joined(separator: " ")
            let previous = parts.last ?? preceding
            let vocabulary = Vocabulary.relevant(
                to: group.map(\.disputedText),
                personal: personalSnap,
                builtIn: Vocabulary.builtIn
            )
            let (fused, ms) = await timed {
                await self.fuser.fuse(groupA, groupB, draft: groupB, context: previous, vocabulary: vocabulary)
            }
            fuseMs += ms
            if let fused, !fused.isEmpty {
                parts.append(Disagreements.merge(fused, into: group))
            } else {
                parts.append(groupB)
                fellBack = true
            }
            index = end
        }
        let joined = Disagreements.join(parts)
        let cleaned = TextCleaner.clean(joined, options: opts, lowercasePreservingTerms: termsSnap, replacements: replSnap)
        return Result(
            text: cleaned,
            baseText: rawA,
            qwenText: rawB,
            route: fellBack ? "qwen-fallback" : "fuse",
            choices: count,
            baseMs: baseMs,
            qwenMs: qwenMs,
            fuseMs: fuseMs,
            modelSummary: modelSummary
        )
    }

    private func timed<T>(_ body: () async throws -> T) async rethrows -> (T, Int) {
        let start = Date()
        let value = try await body()
        return (value, Int(Date().timeIntervalSince(start) * 1000))
    }
}
