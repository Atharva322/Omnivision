import Foundation

public enum Tier: String, Codable, CaseIterable, Sendable {
    case inner
    case familiar
    case acquaintance
    case newPerson
}

public enum IdentityState: Equatable, Sendable {
    case known(Person)
    case likely(Person)
    case ambiguous([String])
    case unnamedCluster(UUID)
    case nothing
}

public struct Person: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var org: String?
    public var tier: Tier
    public var manualTierOverride: Tier?
    public var lastSummary: String?
    public var lastEncounterAt: Date?
    public var encounterCount: Int
    public var pendingNotes: [String]
    public var clusterIDs: [UUID]
    public var namePronunciationPath: String?

    public init(
        id: UUID = UUID(),
        name: String,
        org: String? = nil,
        tier: Tier = .newPerson,
        manualTierOverride: Tier? = nil,
        lastSummary: String? = nil,
        lastEncounterAt: Date? = nil,
        encounterCount: Int = 0,
        pendingNotes: [String] = [],
        clusterIDs: [UUID] = [],
        namePronunciationPath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.org = org
        self.tier = tier
        self.manualTierOverride = manualTierOverride
        self.lastSummary = lastSummary
        self.lastEncounterAt = lastEncounterAt
        self.encounterCount = encounterCount
        self.pendingNotes = pendingNotes
        self.clusterIDs = clusterIDs
        self.namePronunciationPath = namePronunciationPath
    }

    public var effectiveTier: Tier {
        manualTierOverride ?? tier
    }

    public static func autoTier(for encounterCount: Int) -> Tier {
        switch encounterCount {
        case ..<2:
            return .newPerson
        case 2...4:
            return .acquaintance
        default:
            return .familiar
        }
    }
}

public struct Encounter: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var personID: UUID
    public var at: Date
    public var summary: String?
    public var transcript: String?
    public var clusterID: UUID?

    public init(
        id: UUID = UUID(),
        personID: UUID,
        at: Date = Date(),
        summary: String? = nil,
        transcript: String? = nil,
        clusterID: UUID? = nil
    ) {
        self.id = id
        self.personID = personID
        self.at = at
        self.summary = summary
        self.transcript = transcript
        self.clusterID = clusterID
    }
}

public enum Channel: String, Codable, Sendable {
    case wearer
    case other
}

public struct Utterance: Equatable, Sendable {
    public let text: String
    public let channel: Channel
    public let confidence: Float
    public let at: Date

    public init(text: String, channel: Channel, confidence: Float, at: Date) {
        self.text = text
        self.channel = channel
        self.confidence = confidence
        self.at = at
    }
}

public struct NameCandidate: Equatable, Sendable {
    public let name: String
    public let channel: Channel
    public let template: String
    public let confidence: Float

    public init(name: String, channel: Channel, template: String, confidence: Float) {
        self.name = name
        self.channel = channel
        self.template = template
        self.confidence = confidence
    }
}
