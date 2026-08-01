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
        let entry = EventLogEntry(
            at: at,
            category: category,
            message: Self.sanitized(message),
            metadata: Self.sanitized(metadata)
        )
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
            metadata["conflicts"] = uniqueNames(from: assessment.conflicting).joined(separator: ",")
        }
        try append(category: "identity.evidence", message: assessment.rationale, metadata: metadata)
    }

    public func logResolution(_ state: IdentityState, cluster: UUID?) throws {
        var metadata: [String: String] = [
            "state": resolutionLabel(for: state)
        ]

        switch state {
        case .known(let person), .likely(let person):
            metadata["personID"] = person.id.uuidString
            metadata["name"] = person.name
            metadata["tier"] = person.effectiveTier.rawValue
            if let lastSummary = person.lastSummary {
                metadata["summary"] = lastSummary
            }
            if !person.pendingNotes.isEmpty {
                metadata["pendingNotes"] = person.pendingNotes.joined(separator: " | ")
            }
        case .ambiguous(let names):
            metadata["options"] = names.joined(separator: ",")
        case .unnamedCluster(let unresolvedCluster):
            metadata["cluster"] = unresolvedCluster.uuidString
        case .nothing:
            break
        }

        if let cluster {
            metadata["observedCluster"] = cluster.uuidString
        }

        try append(
            category: "identity.resolution",
            message: resolutionMessage(for: state),
            metadata: metadata
        )
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

    private static func sanitized(_ message: String) -> String {
        message
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sanitized(_ metadata: [String: String]) -> [String: String] {
        var sanitizedMetadata: [String: String] = [:]
        for (key, value) in metadata {
            sanitizedMetadata[key] = sanitized(value)
        }
        return sanitizedMetadata
    }

    private func uniqueNames(from candidates: [NameCandidate]) -> [String] {
        var seen: Set<String> = []
        var names: [String] = []

        for candidate in candidates {
            let key = candidate.name
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            if seen.insert(key).inserted {
                names.append(candidate.name)
            }
        }

        return names
    }

    private func resolutionLabel(for state: IdentityState) -> String {
        switch state {
        case .known:
            return "known"
        case .likely:
            return "likely"
        case .ambiguous:
            return "ambiguous"
        case .unnamedCluster:
            return "unnamedCluster"
        case .nothing:
            return "nothing"
        }
    }

    private func resolutionMessage(for state: IdentityState) -> String {
        switch state {
        case .known(let person):
            return "resolved known person \(person.name)"
        case .likely(let person):
            return "resolved likely person \(person.name)"
        case .ambiguous(let names):
            return "ambiguous resolution: \(names.joined(separator: ", "))"
        case .unnamedCluster:
            return "no name resolved; storing unnamed cluster"
        case .nothing:
            return "no identity evidence available"
        }
    }
}
