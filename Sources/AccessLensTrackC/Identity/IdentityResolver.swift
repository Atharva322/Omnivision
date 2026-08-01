import Foundation

public struct IdentityResolver: IdentityResolving {
    private let peopleByName: [String: Person]
    private let peopleByCluster: [UUID: Person]
    private let policy: EvidencePolicy

    public init(people: [Person] = [], policy: EvidencePolicy = .default) {
        self.peopleByName = Dictionary(
            uniqueKeysWithValues: people.map { ($0.name.accessLensIdentityKey, $0) }
        )

        var clusterMap: [UUID: Person] = [:]
        for person in people {
            for clusterID in person.clusterIDs {
                clusterMap[clusterID] = person
            }
        }
        self.peopleByCluster = clusterMap
        self.policy = policy
    }

    public func resolve(names: [NameCandidate], cluster: UUID?) -> IdentityState {
        let assessment = EvidenceAssessor.assess(names, policy: policy)

        switch assessment.disposition {
        case .assert, .assertIfConfident:
            guard let candidate = assessment.candidate else {
                return fallback(cluster: cluster)
            }
            return .known(resolvedPerson(named: candidate.name, cluster: cluster))

        case .hedge:
            if let candidate = assessment.candidate {
                return .likely(resolvedPerson(named: candidate.name, cluster: cluster))
            }
            return fallback(cluster: cluster)

        case .requiresDisambiguation:
            return .ambiguous(assessment.conflicting.map(\.name))

        case .insufficient:
            return fallback(cluster: cluster)
        }
    }

    private func fallback(cluster: UUID?) -> IdentityState {
        guard let cluster else {
            return .nothing
        }
        if let known = peopleByCluster[cluster] {
            return .likely(attach(cluster: cluster, to: known))
        }
        return .unnamedCluster(cluster)
    }

    private func resolvedPerson(named name: String, cluster: UUID?) -> Person {
        if let existing = peopleByName[name.accessLensIdentityKey] {
            return attach(cluster: cluster, to: existing)
        }

        var person = Person(
            name: name,
            tier: .newPerson,
            lastEncounterAt: Date(),
            encounterCount: 1,
            clusterIDs: cluster.map { [$0] } ?? []
        )
        person.tier = Person.autoTier(for: person.encounterCount)
        return person
    }

    private func attach(cluster: UUID?, to person: Person) -> Person {
        guard let cluster else {
            return person
        }

        var copy = person
        if !copy.clusterIDs.contains(cluster) {
            copy.clusterIDs.append(cluster)
        }
        return copy
    }
}

private extension String {
    var accessLensIdentityKey: String {
        trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
