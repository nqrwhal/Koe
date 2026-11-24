import Foundation

struct HistoryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let text: String
    let baseText: String
    let qwenText: String?
    let route: String
    let durationSeconds: Double
    let tailMs: Int
    let baseMs: Int
    let qwenMs: Int
    let fuseMs: Int
    let segments: Int
    let modelSummary: String
    let audioFilename: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        text: String,
        baseText: String,
        qwenText: String?,
        route: String,
        durationSeconds: Double,
        tailMs: Int,
        baseMs: Int,
        qwenMs: Int,
        fuseMs: Int,
        segments: Int,
        modelSummary: String,
        audioFilename: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.text = text
        self.baseText = baseText
        self.qwenText = qwenText
        self.route = route
        self.durationSeconds = durationSeconds
        self.tailMs = tailMs
        self.baseMs = baseMs
        self.qwenMs = qwenMs
        self.fuseMs = fuseMs
        self.segments = segments
        self.modelSummary = modelSummary
        self.audioFilename = audioFilename
    }
}

@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    static let defaultURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Koe/history.json")

    @Published private(set) var entries: [HistoryEntry] = []

    private let fileURL: URL
    private let maxEntries = 250
    private let retentionDays: TimeInterval = 7 * 24 * 3600

    init(fileURL: URL = HistoryStore.defaultURL) {
        self.fileURL = fileURL
        load()
    }

    func append(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        pruneAndSave()
    }

    func delete(id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func clearAll() {
        entries.removeAll()
        save()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            entries = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([HistoryEntry].self, from: data) {
            let cutoff = Date().addingTimeInterval(-retentionDays)
            entries = Array(decoded.filter { $0.timestamp >= cutoff }.prefix(maxEntries))
        }
    }

    private func pruneAndSave() {
        let cutoff = Date().addingTimeInterval(-retentionDays)
        entries = Array(entries.filter { $0.timestamp >= cutoff }.prefix(maxEntries))
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
