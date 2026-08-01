import Foundation

public enum PersonStoreError: Error, Equatable {
    case personNotFound(UUID)
    case invalidName
    case invalidPendingNote
    case invalidSummary
    case invalidPronunciationPath
    case unsupportedSchemaVersion(Int)
}

public actor PersonStore {
    public static let currentSchemaVersion = 2
    public let url: URL
    private var peopleByID: [UUID: Person]
    private var rejectedAssociations: Set<RejectedIdentityAssociation>
    private var encountersByID: [UUID: Encounter]
    private var unnamedClustersByID: [UUID: UnnamedClusterRecord]

    public init(url: URL? = nil) throws {
        let resolvedURL = url ?? Self.defaultURL()
        self.url = resolvedURL
        let persisted = try Self.load(from: resolvedURL)
        self.peopleByID = Dictionary(uniqueKeysWithValues: persisted.people.map { ($0.id, $0) })
        self.rejectedAssociations = Set(persisted.rejectedAssociations)
        self.encountersByID = Dictionary(uniqueKeysWithValues: persisted.encounters.map { ($0.id, $0) })
        self.unnamedClustersByID = Dictionary(
            uniqueKeysWithValues: persisted.unnamedClusters.map { ($0.clusterID, $0) }
        )
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

    public func isRejected(personID: UUID, clusterID: UUID) -> Bool {
        rejectedAssociations.contains {
            $0.personID == personID && $0.clusterID == clusterID
        }
    }

    public func rejectedIdentityAssociations() -> [RejectedIdentityAssociation] {
        rejectedAssociations.sorted { $0.rejectedAt < $1.rejectedAt }
    }

    public func encounters(for personID: UUID) -> [Encounter] {
        encountersByID.values
            .filter { $0.personID == personID }
            .sorted { $0.at < $1.at }
    }

    public func unnamedClusters() -> [UnnamedClusterRecord] {
        unnamedClustersByID.values.sorted { $0.firstSeenAt < $1.firstSeenAt }
    }

    @discardableResult
    public func recordUnnamedCluster(_ clusterID: UUID, at: Date = Date()) throws -> UnnamedClusterRecord {
        var record = unnamedClustersByID[clusterID]
            ?? UnnamedClusterRecord(clusterID: clusterID, firstSeenAt: at, lastSeenAt: at)
        record.lastSeenAt = at
        unnamedClustersByID[clusterID] = record
        try save()
        return record
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
            if let clusterID {
                unnamedClustersByID.removeValue(forKey: clusterID)
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
        if let clusterID {
            unnamedClustersByID.removeValue(forKey: clusterID)
        }
        let encounter = Encounter(
            personID: person.id,
            at: at,
            clusterID: clusterID
        )
        encountersByID[encounter.id] = encounter
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
        let encounter = Encounter(
            personID: person.id,
            at: at,
            summary: person.lastSummary,
            clusterID: clusterID
        )
        encountersByID[encounter.id] = encounter
        if let clusterID {
            unnamedClustersByID.removeValue(forKey: clusterID)
        }
        try save()
        return person
    }

    @discardableResult
    public func updateLatestSummary(_ summary: String, for personID: UUID) throws -> Person {
        guard let normalizedSummary = Self.normalizedDisplayText(summary) else {
            throw PersonStoreError.invalidSummary
        }
        guard var person = peopleByID[personID] else {
            throw PersonStoreError.personNotFound(personID)
        }
        person.lastSummary = normalizedSummary
        peopleByID[personID] = person
        if let latestID = encountersByID.values
            .filter({ $0.personID == personID })
            .max(by: { $0.at < $1.at })?.id,
           var encounter = encountersByID[latestID] {
            encounter.summary = normalizedSummary
            encountersByID[latestID] = encounter
        }
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

    /// Attaches the consented one-second name clip owned by Track D.
    ///
    /// The recorder is responsible for creating a file inside Omnivision's Application Support
    /// directory. The store persists only its path so the Narrator can replay it and the deletion
    /// flow can remove the artifact. Passing `nil` deliberately detaches a deleted clip.
    @discardableResult
    public func setNamePronunciationPath(_ path: String?, for personID: UUID) throws -> Person {
        guard var person = peopleByID[personID] else {
            throw PersonStoreError.personNotFound(personID)
        }

        if let path {
            let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else {
                throw PersonStoreError.invalidPronunciationPath
            }
            person.namePronunciationPath = normalized
        } else {
            person.namePronunciationPath = nil
        }

        peopleByID[personID] = person
        try save()
        return person
    }

    /// Records "that's wrong" and detaches the rejected cluster from the person.
    @discardableResult
    public func rejectIdentityAssociation(
        personID: UUID,
        clusterID: UUID,
        at: Date = Date()
    ) throws -> Person {
        guard var person = peopleByID[personID] else {
            throw PersonStoreError.personNotFound(personID)
        }
        person.clusterIDs.removeAll { $0 == clusterID }
        peopleByID[personID] = person
        rejectedAssociations = Set(rejectedAssociations.filter {
            $0.personID != personID || $0.clusterID != clusterID
        })
        rejectedAssociations.insert(
            RejectedIdentityAssociation(personID: personID, clusterID: clusterID, rejectedAt: at)
        )
        try save()
        return person
    }

    /// Deletes the persisted person and returns the removed record so the iOS coordinator can
    /// delete its pronunciation clip and face-print artifacts too.
    @discardableResult
    public func delete(id: UUID) throws -> Person {
        guard let removed = peopleByID.removeValue(forKey: id) else {
            throw PersonStoreError.personNotFound(id)
        }
        rejectedAssociations = Set(rejectedAssociations.filter { $0.personID != id })
        encountersByID = Dictionary(uniqueKeysWithValues: encountersByID.filter {
            $0.value.personID != id
        })
        try save()
        return removed
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
        let payload = PersistedPeople(
            schemaVersion: Self.currentSchemaVersion,
            people: allPersons(),
            rejectedAssociations: rejectedIdentityAssociations(),
            encounters: encountersByID.values.sorted { $0.at < $1.at },
            unnamedClusters: unnamedClusters()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        try data.write(to: url, options: [.atomic])
    }

    private static func load(from url: URL) throws -> PersistedPeople {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return PersistedPeople(
                schemaVersion: currentSchemaVersion,
                people: [],
                rejectedAssociations: [],
                encounters: [],
                unnamedClusters: []
            )
        }

        let data = try Data(contentsOf: url)
        guard !data.isEmpty else {
            return PersistedPeople(
                schemaVersion: currentSchemaVersion,
                people: [],
                rejectedAssociations: [],
                encounters: [],
                unnamedClusters: []
            )
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let payload = try decoder.decode(PersistedPeople.self, from: data)
            guard payload.schemaVersion <= currentSchemaVersion else {
                throw PersonStoreError.unsupportedSchemaVersion(payload.schemaVersion)
            }
            return payload
        } catch let error as PersonStoreError {
            throw error
        } catch {
            // Preserve evidence for diagnosis. Never overwrite a corrupted identity store.
            let backup = url.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: url, to: backup)
            throw error
        }
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
    let schemaVersion: Int
    let people: [Person]
    let rejectedAssociations: [RejectedIdentityAssociation]
    let encounters: [Encounter]
    let unnamedClusters: [UnnamedClusterRecord]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case people
        case rejectedAssociations
        case encounters
        case unnamedClusters
    }

    init(
        schemaVersion: Int,
        people: [Person],
        rejectedAssociations: [RejectedIdentityAssociation],
        encounters: [Encounter],
        unnamedClusters: [UnnamedClusterRecord]
    ) {
        self.schemaVersion = schemaVersion
        self.people = people
        self.rejectedAssociations = rejectedAssociations
        self.encounters = encounters
        self.unnamedClusters = unnamedClusters
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Files written before schema versioning contained only { "people": [...] }.
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        people = try container.decode([Person].self, forKey: .people)
        rejectedAssociations = try container.decodeIfPresent(
            [RejectedIdentityAssociation].self,
            forKey: .rejectedAssociations
        ) ?? []
        encounters = try container.decodeIfPresent([Encounter].self, forKey: .encounters) ?? []
        unnamedClusters = try container.decodeIfPresent(
            [UnnamedClusterRecord].self,
            forKey: .unnamedClusters
        ) ?? []
    }
}
