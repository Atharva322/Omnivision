import Foundation

public struct EventLogEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let at: Date
    public let category: String
    public let message: String
    public let metadata: [String: String]

    public init(
        id: UUID = UUID(),
        at: Date = Date(),
        category: String,
        message: String,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.at = at
        self.category = category
        self.message = message
        self.metadata = metadata
    }
}

public actor EventLog {
    public let url: URL
    private var entries: [EventLogEntry]

    public init(url: URL? = nil) throws {
        let resolvedURL = url ?? Self.defaultURL()
        self.url = resolvedURL
        self.entries = try Self.loadEntries(from: resolvedURL)
    }

    public func append(
        category: String,
        message: String,
        metadata: [String: String] = [:],
        at: Date = Date()
    ) throws {
        let entry = EventLogEntry(at: at, category: category, message: message, metadata: metadata)
        entries.append(entry)
        try persist(entry)
    }

    public func logTransition(from: SessionState, to: SessionState, reason: String? = nil) throws {
        var metadata = [
            "from": from.rawValue,
            "to": to.rawValue
        ]
        if let reason {
            metadata["reason"] = reason
        }
        try append(
            category: "session.transition",
            message: "\(from.rawValue) -> \(to.rawValue)",
            metadata: metadata
        )
    }

    public func logEvidence(_ assessment: EvidenceAssessment, cluster: UUID?) throws {
        var metadata: [String: String] = [
            "disposition": String(describing: assessment.disposition)
        ]
        if let level = assessment.level {
            metadata["level"] = level.label
        }
        if let candidate = assessment.candidate {
            metadata["name"] = candidate.name
            metadata["template"] = candidate.template
            metadata["confidence"] = String(format: "%.3f", candidate.confidence)
        }
        if let cluster {
            metadata["cluster"] = cluster.uuidString
        }
        if !assessment.conflicting.isEmpty {
            metadata["conflicts"] = assessment.conflicting.map(\.name).joined(separator: ",")
        }
        try append(category: "identity.evidence", message: assessment.rationale, metadata: metadata)
    }

    public func snapshot() -> [EventLogEntry] {
        entries
    }

    private func persist(_ entry: EventLogEntry) throws {
        try Self.ensureParentDirectory(for: url)
        let data = try Self.encoder.encode(entry)

        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("\n".utf8))
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url, options: [.atomic])
        }
    }

    private static func loadEntries(from url: URL) throws -> [EventLogEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }

        let data = try Data(contentsOf: url)
        guard !data.isEmpty else {
            return []
        }

        return try String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { try decoder.decode(EventLogEntry.self, from: Data($0.utf8)) }
    }

    private static func ensureParentDirectory(for url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func defaultURL() -> URL {
        defaultDirectory().appendingPathComponent("event-log.jsonl")
    }

    private static func defaultDirectory() -> URL {
        #if os(Linux)
        return FileManager.default.temporaryDirectory.appendingPathComponent("AccessLensTrackC", isDirectory: true)
        #else
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("AccessLens", isDirectory: true)
        #endif
    }
}
