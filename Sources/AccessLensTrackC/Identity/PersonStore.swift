import Foundation

public enum PersonStoreError: Error, Equatable {
    case personNotFound(UUID)
    case invalidName
    case invalidPendingNote
}

public actor PersonStore {
    public let url: URL
    private var peopleByID: [UUID: Person]

    public init(url: URL? = nil) throws {
        let resolvedURL = url ?? Self.defaultURL()
        self.url = resolvedURL
        self.peopleByID = try Self.loadPeople(from: resolvedURL)
    }

    public func allPersons() -> [Person] {
        peopleByID.values.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    public func snapshot() -> [Person] {
        allPersons()
    }

    public func find(id: UUID) -> Person? {
        peopleByID[id]
    }

    public func find(name: String) -> Person? {
        guard let key = Self.normalizedIdentityKey(from: name) else {
            return nil
        }
        return peopleByID.values.first { $0.name.accessLensIdentityKey == key }
    }

    public func find(clusterID: UUID) -> Person? {
        peopleByID.values.first { $0.clusterIDs.contains(clusterID) }
    }

    @discardableResult
    public func upsert(_ person: Person) throws -> Person {
        var updated = person
        updated.name = Self.normalizedDisplayText(updated.name) ?? updated.name
        updated.org = Self.normalizedDisplayText(updated.org)
        updated.pendingNotes = updated.pendingNotes.compactMap(Self.normalizedDisplayText)
        updated.clusterIDs = Array(Set(updated.clusterIDs))
        applyDerivedTier(to: &updated)
        peopleByID[updated.id] = updated
        try save()
        return updated
    }

    @discardableResult
    public func bind(
        name: String,
        org: String? = nil,
        clusterID: UUID? = nil,
        at: Date = Date()
    ) throws -> Person {
        guard let normalizedName = Self.normalizedDisplayText(name) else {
            throw PersonStoreError.invalidName
        }
        let normalizedOrg = Self.normalizedDisplayText(org)

        if var existing = find(name: normalizedName) {
            existing.name = normalizedName
            if let normalizedOrg, (existing.org?.isEmpty ?? true) {
                existing.org = normalizedOrg
            }
            if let clusterID, !existing.clusterIDs.contains(clusterID) {
                existing.clusterIDs.append(clusterID)
            }
            existing.lastEncounterAt = at
            if existing.encounterCount == 0 {
                existing.encounterCount = 1
            }
            return try upsert(existing)
        }

        var person = Person(
            name: normalizedName,
            org: normalizedOrg,
            tier: .newPerson,
            lastEncounterAt: at,
            encounterCount: 1,
            clusterIDs: clusterID.map { [$0] } ?? []
        )
        applyDerivedTier(to: &person)
        peopleByID[person.id] = person
        try save()
        return person
    }

    @discardableResult
    public func registerEncounter(
        for personID: UUID,
        at: Date = Date(),
        summary: String? = nil,
        clusterID: UUID? = nil
    ) throws -> Person {
        guard var person = peopleByID[personID] else {
            throw PersonStoreError.personNotFound(personID)
        }

        person.encounterCount += 1
        person.lastEncounterAt = at
        if let normalizedSummary = Self.normalizedDisplayText(summary) {
            person.lastSummary = normalizedSummary
        }
        if let clusterID, !person.clusterIDs.contains(clusterID) {
            person.clusterIDs.append(clusterID)
        }

        applyDerivedTier(to: &person)
        peopleByID[person.id] = person
        try save()
        return person
    }

    @discardableResult
    public func addPendingNote(_ note: String, to personID: UUID) throws -> Person {
        guard let normalizedNote = Self.normalizedDisplayText(note) else {
            throw PersonStoreError.invalidPendingNote
        }
        guard var person = peopleByID[personID] else {
            throw PersonStoreError.personNotFound(personID)
        }
        person.pendingNotes.append(normalizedNote)
        peopleByID[person.id] = person
        try save()
        return person
    }

    @discardableResult
    public func setManualTierOverride(_ tier: Tier?, for personID: UUID) throws -> Person {
        guard var person = peopleByID[personID] else {
            throw PersonStoreError.personNotFound(personID)
        }
        person.manualTierOverride = tier
        applyDerivedTier(to: &person)
        peopleByID[person.id] = person
        try save()
        return person
    }

    public func delete(id: UUID) throws {
        peopleByID.removeValue(forKey: id)
        try save()
    }

    private func applyDerivedTier(to person: inout Person) {
        if let override = person.manualTierOverride {
            person.tier = override
            return
        }
        person.tier = Person.autoTier(for: person.encounterCount)
    }

    private func save() throws {
        try Self.ensureParentDirectory(for: url)
        let payload = PersistedPeople(people: allPersons())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        try data.write(to: url, options: [.atomic])
    }

    private static func loadPeople(from url: URL) throws -> [UUID: Person] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return [:]
        }

        let data = try Data(contentsOf: url)
        guard !data.isEmpty else {
            return [:]
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(PersistedPeople.self, from: data)
        return Dictionary(uniqueKeysWithValues: payload.people.map { ($0.id, $0) })
    }

    private static func ensureParentDirectory(for url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    private static func defaultURL() -> URL {
        defaultDirectory().appendingPathComponent("people.json")
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

    private static func normalizedDisplayText(_ value: String?) -> String? {
        guard let value else { return nil }
        let collapsed = value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
    }

    private static func normalizedIdentityKey(from value: String) -> String? {
        normalizedDisplayText(value)?.accessLensIdentityKey
    }
}

private struct PersistedPeople: Codable {
    let people: [Person]
}

private extension String {
    var accessLensIdentityKey: String {
        trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
