import Foundation

public enum SocialMemoryCoordinatorError: Error, Equatable {
    case noCaptureInProgress
    case noReportedIdentity
    case noPendingClarification
    case invalidClarification(String)
    case noPendingDeletion
    case artifactDeletionUnavailable
}

/// Apple/iOS integration implements this to delete feature prints, consented face crops, and the
/// optional pronunciation clip before the person record is removed.
public protocol IdentityArtifactDeleting: Sendable {
    func deleteArtifacts(for person: Person) async throws
}

public struct DeferredIdentityArtifactDeleter: IdentityArtifactDeleting {
    public init() {}
    public func deleteArtifacts(for person: Person) async throws {
        _ = person
        throw SocialMemoryCoordinatorError.artifactDeletionUnavailable
    }
}

/// Owns the portable Track A flow. Hardware tracks feed it final utterances and an optional face
/// cluster; Track D converts `SocialMemoryAction` values into approved speech and earcons.
public actor SocialMemoryCoordinator {
    private let sessionMachine: SessionMachine
    private let eventLog: EventLog
    private let store: PersonStore
    private let commandParser: any CommandParsing
    private let nameExtractor: any NameExtracting
    private let evidencePolicy: EvidencePolicy
    private let artifactDeleter: any IdentityArtifactDeleting

    private var utterances: [Utterance] = []
    private var candidates: [NameCandidate] = []
    private var currentCluster: UUID?
    private var lastReported: IdentityState?
    private var currentPersonID: UUID?
    private var pendingClarification: [String] = []
    private var pendingDeletionPersonID: UUID?

    public init(
        sessionMachine: SessionMachine,
        eventLog: EventLog,
        store: PersonStore,
        commandParser: any CommandParsing = LumenCommandParser(),
        nameExtractor: any NameExtracting = NameExtractor(),
        evidencePolicy: EvidencePolicy = .default,
        artifactDeleter: any IdentityArtifactDeleting = DeferredIdentityArtifactDeleter()
    ) {
        self.sessionMachine = sessionMachine
        self.eventLog = eventLog
        self.store = store
        self.commandParser = commandParser
        self.nameExtractor = nameExtractor
        self.evidencePolicy = evidencePolicy
        self.artifactDeleter = artifactDeleter
    }

    public func beginCapture(cluster: UUID? = nil) async throws -> SocialMemoryAction {
        try await sessionMachine.startCapture()
        utterances = []
        candidates = []
        currentCluster = cluster
        lastReported = nil
        currentPersonID = nil
        pendingDeletionPersonID = nil
        pendingClarification = []
        try await eventLog.append(
            category: "conversation.capture",
            message: "capture started",
            metadata: cluster.map { ["cluster": $0.uuidString] } ?? [:]
        )
        return .captureStarted
    }

    public func ingest(
        _ utterance: Utterance,
        cluster: UUID? = nil,
        summary: String? = nil
    ) async throws -> SocialMemoryAction {
        if let cluster { currentCluster = cluster }

        if let command = commandParser.parse(utterance) {
            try await log(command: command)
            switch command {
            case .rememberThis:
                return try await beginCapture(cluster: currentCluster)
            case .endCapture:
                return try await finishCapture(summary: summary)
            case .whoIsThis:
                return try await identifyCurrentCluster()
            case .bind(let name):
                return try await explicitlyBind(name: name, summary: summary)
            case .thatsWrong:
                return try await correctLastIdentity()
            case .remindMe(let text):
                return try await saveReminder(text)
            case .favorite:
                return try await saveFavorite()
            case .forgetThem:
                return try await requestForgetConfirmation()
            case .pause:
                try await sessionMachine.pause()
                resetConversation()
                return .capturePaused
            }
        }

        guard await sessionMachine.currentState() == .capturing else { return .noAction }
        utterances.append(utterance)
        let extracted = nameExtractor.candidates(in: utterance)
        candidates.append(contentsOf: extracted)
        if !extracted.isEmpty {
            try await eventLog.append(
                category: "identity.candidates",
                message: "spoken-name candidates extracted",
                metadata: [
                    "count": String(extracted.count),
                    "templates": extracted.map(\.template).joined(separator: ",")
                ]
            )
        }
        return .noAction
    }

    public func finishCapture(summary: String? = nil) async throws -> SocialMemoryAction {
        guard await sessionMachine.currentState() == .capturing else {
            throw SocialMemoryCoordinatorError.noCaptureInProgress
        }
        try await sessionMachine.finishCapture()
        return try await resolveCurrentEvidence(summary: summary)
    }

    public func confirmClarification(name: String, summary: String? = nil) async throws -> SocialMemoryAction {
        guard !pendingClarification.isEmpty else {
            throw SocialMemoryCoordinatorError.noPendingClarification
        }
        guard let selected = pendingClarification.first(where: {
            $0.accessLensIdentityKey == name.accessLensIdentityKey
        }) else {
            throw SocialMemoryCoordinatorError.invalidClarification(name)
        }
        pendingClarification = []
        return try await bindAndReport(name: selected, summary: summary)
    }

    public func correctLastIdentity() async throws -> SocialMemoryAction {
        guard await sessionMachine.currentState() == .reporting, let lastReported else {
            throw SocialMemoryCoordinatorError.noReportedIdentity
        }
        try await sessionMachine.rejectReportedIdentity()

        if let cluster = currentCluster {
            let person: Person?
            switch lastReported {
            case .known(let value), .likely(let value): person = value
            default: person = nil
            }
            if let person, await store.find(id: person.id) != nil {
                _ = try await store.rejectIdentityAssociation(
                    personID: person.id,
                    clusterID: cluster
                )
            }
            _ = try await store.recordUnnamedCluster(cluster)
        }

        try await eventLog.append(
            category: "identity.correction",
            message: "wearer rejected reported identity",
            metadata: currentCluster.map { ["cluster": $0.uuidString] } ?? [:]
        )
        self.lastReported = nil
        currentPersonID = nil
        return .correctionAccepted
    }

    public func confirmForget() async throws -> SocialMemoryAction {
        guard let personID = pendingDeletionPersonID,
              let person = await store.find(id: personID) else {
            throw SocialMemoryCoordinatorError.noPendingDeletion
        }

        // External artifacts go first. A failure leaves the authoritative person record intact.
        try await artifactDeleter.deleteArtifacts(for: person)
        _ = try await store.delete(id: personID)
        try await eventLog.append(
            category: "identity.deletion",
            message: "person and associated artifacts deleted",
            metadata: ["personID": personID.uuidString]
        )
        pendingDeletionPersonID = nil
        if currentPersonID == personID { currentPersonID = nil }
        return .personForgotten(personID: personID)
    }

    public func cancelForget() {
        pendingDeletionPersonID = nil
    }

    public func finishReporting() async throws {
        try await sessionMachine.finishReporting()
        resetConversation()
    }

    private func resolveCurrentEvidence(summary: String?) async throws -> SocialMemoryAction {
        let assessment = EvidenceAssessor.assess(candidates, policy: evidencePolicy)
        try await eventLog.logEvidence(assessment, cluster: currentCluster)
        let resolver = await makeResolver()
        let resolution = resolver.resolve(names: candidates, cluster: currentCluster)
        try await eventLog.logResolution(resolution, cluster: currentCluster)

        switch resolution {
        case .known(let resolved):
            let saved = try await persistKnown(resolved, summary: summary)
            lastReported = .known(saved)
            currentPersonID = saved.id
            try await sessionMachine.completeBinding()
            return .known(saved)
        case .likely(let person):
            lastReported = .likely(person)
            currentPersonID = await store.find(id: person.id) == nil ? nil : person.id
            try await sessionMachine.completeBinding()
            return .likely(person)
        case .ambiguous(let names):
            pendingClarification = names
            return .clarificationRequired(names)
        case .unnamedCluster(let cluster):
            _ = try await store.recordUnnamedCluster(cluster)
            lastReported = .unnamedCluster(cluster)
            try await sessionMachine.completeBinding()
            return .unknown(clusterID: cluster)
        case .nothing:
            lastReported = .nothing
            try await sessionMachine.completeBinding()
            return .unknown(clusterID: nil)
        }
    }

    private func explicitlyBind(name: String, summary: String?) async throws -> SocialMemoryAction {
        let state = await sessionMachine.currentState()
        if state == .idle {
            _ = try await beginCapture(cluster: currentCluster)
            try await sessionMachine.finishCapture()
        } else if state == .capturing {
            try await sessionMachine.finishCapture()
        } else if state == .reporting {
            _ = try await correctLastIdentity()
        }
        return try await bindAndReport(name: name, summary: summary)
    }

    private func bindAndReport(name: String, summary: String?) async throws -> SocialMemoryAction {
        let saved: Person
        if let existing = await store.find(name: name) {
            saved = try await store.registerEncounter(
                for: existing.id,
                summary: summary,
                clusterID: currentCluster
            )
        } else {
            var created = try await store.bind(name: name, clusterID: currentCluster)
            if let summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                created = try await store.updateLatestSummary(summary, for: created.id)
            }
            saved = created
        }
        let state = IdentityState.known(saved)
        try await eventLog.logResolution(state, cluster: currentCluster)
        lastReported = state
        currentPersonID = saved.id
        try await sessionMachine.completeBinding()
        return .known(saved)
    }

    private func persistKnown(_ resolved: Person, summary: String?) async throws -> Person {
        if let existing = await store.find(name: resolved.name) {
            return try await store.registerEncounter(
                for: existing.id,
                summary: summary,
                clusterID: currentCluster
            )
        }
        var saved = try await store.bind(name: resolved.name, org: resolved.org, clusterID: currentCluster)
        if let summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            saved = try await store.updateLatestSummary(summary, for: saved.id)
        }
        return saved
    }

    private func identifyCurrentCluster() async throws -> SocialMemoryAction {
        if await sessionMachine.currentState() == .idle {
            try await sessionMachine.startCapture()
            try await sessionMachine.finishCapture()
        }
        let resolver = await makeResolver()
        let state = resolver.resolve(names: [], cluster: currentCluster)
        try await eventLog.logResolution(state, cluster: currentCluster)
        switch state {
        case .likely(let person):
            lastReported = state
            currentPersonID = await store.find(id: person.id) == nil ? nil : person.id
            try await sessionMachine.completeBinding()
            return .likely(person)
        case .known(let person):
            lastReported = state
            currentPersonID = person.id
            try await sessionMachine.completeBinding()
            return .known(person)
        case .unnamedCluster(let cluster):
            _ = try await store.recordUnnamedCluster(cluster)
            lastReported = state
            try await sessionMachine.completeBinding()
            return .unknown(clusterID: cluster)
        default:
            lastReported = state
            try await sessionMachine.completeBinding()
            return .unknown(clusterID: currentCluster)
        }
    }

    private func saveReminder(_ text: String) async throws -> SocialMemoryAction {
        guard let currentPersonID else { return .noCurrentPerson }
        let person = try await store.addPendingNote(text, to: currentPersonID)
        return .reminderSaved(person)
    }

    private func saveFavorite() async throws -> SocialMemoryAction {
        guard let currentPersonID else { return .noCurrentPerson }
        let person = try await store.setManualTierOverride(.inner, for: currentPersonID)
        return .favoriteSaved(person)
    }

    private func requestForgetConfirmation() async throws -> SocialMemoryAction {
        guard let currentPersonID, let person = await store.find(id: currentPersonID) else {
            return .noCurrentPerson
        }
        pendingDeletionPersonID = currentPersonID
        return .forgetConfirmationRequired(person)
    }

    private func makeResolver() async -> IdentityResolver {
        IdentityResolver(
            people: await store.snapshot(),
            rejectedAssociations: await store.rejectedIdentityAssociations(),
            policy: evidencePolicy
        )
    }

    private func log(command: Command) async throws {
        try await eventLog.append(
            category: "command",
            message: "voice command accepted",
            metadata: ["command": command.label]
        )
    }

    private func resetConversation() {
        utterances = []
        candidates = []
        currentCluster = nil
        lastReported = nil
        pendingClarification = []
        currentPersonID = nil
        pendingDeletionPersonID = nil
    }
}
