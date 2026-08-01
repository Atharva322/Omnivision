//
//  NameExtractor.swift
//  Track C — wearer-echo templates → validated personal name → `NameCandidate`.
//
//  This is the primary identity channel of the product (Decision D1). It only ever *proposes*:
//  binding, hedging and asking are Track A's `IdentityResolver`. Nothing here reads a face, a
//  cluster, an organisation or a topic — a `NameCandidate` can be produced by exactly one thing,
//  a name that was spoken aloud.
//

import Foundation

/// One rejected slot, kept for the evaluation report and the event log.
public struct NameSlotRejectionRecord: Equatable {
    public let templateID: String
    public let rejection: NameSlotRejection

    public init(templateID: String, rejection: NameSlotRejection) {
        self.templateID = templateID
        self.rejection = rejection
    }
}

/// Detailed extraction output. `candidates(in:)` returns just the accepted half of this.
public struct NameExtractionResult {
    public let candidates: [NameCandidate]
    public let rejections: [NameSlotRejectionRecord]
    /// True when the utterance was a `Lumen …` command, so wearer-echo templates were skipped.
    public let handledAsCommand: Bool

    public init(
        candidates: [NameCandidate],
        rejections: [NameSlotRejectionRecord],
        handledAsCommand: Bool
    ) {
        self.candidates = candidates
        self.rejections = rejections
        self.handledAsCommand = handledAsCommand
    }
}

/// Implements Track A's frozen `NameExtracting`.
public struct NameExtractor: NameExtracting {

    public let policy: NameExtractionPolicy
    public let denylist: NameDenylist
    private let leadResolver: NameSlotResolver
    private let trailingResolver: NameSlotResolver
    private let commandParser: LumenCommandParser
    /// Same grammar, channel check disabled. Used only to answer "was this utterance addressed to
    /// the system?" — never to authorise a command.
    private let wakeWordDetector: LumenCommandParser
    private let templates: [NameTemplate]

    /// - Parameters:
    ///   - denylist: defaults to the JSON shipped with this module, degrading safely if it cannot
    ///     be read.
    ///   - validator: `PortableNameValidator` on Linux; inject `NLTaggerNameValidator` on iOS.
    public init(
        denylist: NameDenylist = .bundled(),
        validator: PersonalNameValidating = PortableNameValidator(),
        policy: NameExtractionPolicy = .default,
        commandPolicy: CommandPolicy = .default,
        templates: [NameTemplate] = NameTemplate.all
    ) {
        self.policy = policy
        self.denylist = denylist
        self.templates = templates
        self.leadResolver = NameSlotResolver(denylist: denylist, validator: validator, policy: policy)

        // The trailing template's name sits *before* the trigger word, so a multi-token name would
        // grow forwards into it. One token only.
        var trailingPolicy = policy
        trailingPolicy.maxNameTokens = 1
        self.trailingResolver = NameSlotResolver(
            denylist: denylist, validator: validator, policy: trailingPolicy
        )

        let bindResolver = NameSlotResolver(denylist: denylist, validator: validator, policy: policy)
        self.commandParser = LumenCommandParser(policy: commandPolicy, slotResolver: bindResolver)

        var detectorPolicy = commandPolicy
        detectorPolicy.requiresWearerChannel = false
        self.wakeWordDetector = LumenCommandParser(policy: detectorPolicy, slotResolver: bindResolver)
    }

    // MARK: - NameExtracting

    public func candidates(in u: Utterance) -> [NameCandidate] {
        extract(in: u).candidates
    }

    // MARK: - Detailed extraction

    public func extract(in u: Utterance) -> NameExtractionResult {
        // Anything addressed to the system is not conversational speech, and conversational
        // templates must not be run over it. Two reasons:
        //
        //   • it keeps E0 distinguishable from E1 — "Lumen, this is Priya" contains the literal E1
        //     `this is` template and would otherwise be reported as a wearer echo;
        //   • it holds on the other channel too. A bystander saying "Lumen, this is Priya" is
        //     addressing the system, and the `this is` self-introduction template must not turn
        //     that into E2 evidence behind the command parser's channel check.
        //
        // The detector ignores the channel on purpose: it answers "was this aimed at the system?",
        // not "may this issue commands?" — only `commandParser` decides the latter.
        if case .rejected(.noWakeWord) = wakeWordDetector.outcome(for: u) {
            return extractFromTemplates(u)
        }

        switch commandParser.outcome(for: u) {
        case .matched(let parsed):
            if case .bind(let name) = parsed.command {
                // E0 binds unconditionally (Decision D5): the wearer stated the name deliberately,
                // on the clearest channel, having invoked the system by name. Recogniser
                // confidence does not discount it — the name slot already passed validation and
                // the denylist, and this path is the escape hatch that must always work.
                let candidate = NameCandidate(
                    name: name,
                    channel: u.channel,
                    template: NameTemplateID.explicitBind,
                    confidence: 1.0
                )
                return NameExtractionResult(
                    candidates: [candidate],
                    rejections: [],
                    handledAsCommand: true
                )
            }
            return NameExtractionResult(candidates: [], rejections: [], handledAsCommand: true)

        case .rejected(let rejection):
            if case .invalidNameSlot(let heard) = rejection {
                return NameExtractionResult(
                    candidates: [],
                    rejections: [NameSlotRejectionRecord(
                        templateID: NameTemplateID.explicitBind,
                        rejection: .validatorRejected(token: heard, reason: "explicit bind slot is not a name")
                    )],
                    handledAsCommand: true
                )
            }
            // The wake word was heard. Whether the grammar matched, the channel was wrong, or the
            // name slot was rubbish, the wearer was addressing the system rather than greeting a
            // person — there is nothing here to mine.
            return NameExtractionResult(candidates: [], rejections: [], handledAsCommand: true)
        }
    }

    // MARK: - Templates

    private func extractFromTemplates(_ u: Utterance) -> NameExtractionResult {
        var rejections: [NameSlotRejectionRecord] = []

        let asrConfidence = u.confidence
        if asrConfidence > 0 && asrConfidence < policy.minimumASRConfidence {
            // Recogniser itself says it is guessing. A name bound from a guess poisons the store.
            return NameExtractionResult(candidates: [], rejections: [], handledAsCommand: false)
        }

        let tokens = SpeechTokenizer.tokenize(u.text)
        guard !tokens.isEmpty else {
            return NameExtractionResult(candidates: [], rejections: [], handledAsCommand: false)
        }

        let active = templates.filter { $0.channel == u.channel }
        var accepted: [NameCandidate] = []

        // 1. Lead-phrase templates, longest phrase first so "nice to see you" wins over "see you".
        let leadPairs: [(phrase: [String], template: NameTemplate)] = active
            .filter { $0.shape == .nameFollowsLead }
            .flatMap { template in template.phrases.map { (phrase: $0, template: template) } }
            .sorted { $0.phrase.count > $1.phrase.count }

        var index = 0
        while index < tokens.count {
            var advanced = false
            for pair in leadPairs where pair.phrase.count <= tokens.count - index {
                guard matches(pair.phrase, in: tokens, at: index) else { continue }
                let slotStart = index + pair.phrase.count
                switch leadResolver.resolve(
                    tokens: tokens,
                    start: slotStart,
                    utteranceText: u.text,
                    templateID: pair.template.id,
                    strength: pair.template.strength
                ) {
                case .success(let slot):
                    accepted.append(candidate(from: slot, template: pair.template, utterance: u))
                    index = slotStart + slot.tokenCount
                case .failure(let rejection):
                    rejections.append(NameSlotRejectionRecord(
                        templateID: pair.template.id, rejection: rejection
                    ))
                    index = slotStart
                }
                advanced = true
                break
            }
            if !advanced { index += 1 }
        }

        // 2. Trailing template: {NAME}, (good|nice|great|how)
        for template in active where template.shape == .namePrecedesTrigger {
            let triggers = Set(template.phrases.compactMap(\.first))
            for token in tokens where token.index >= 1 && triggers.contains(token.normalized) {
                switch trailingResolver.resolve(
                    tokens: tokens,
                    start: token.index - 1,
                    utteranceText: u.text,
                    templateID: template.id,
                    strength: template.strength
                ) {
                case .success(let slot):
                    accepted.append(candidate(from: slot, template: template, utterance: u))
                case .failure(let rejection):
                    rejections.append(NameSlotRejectionRecord(
                        templateID: template.id, rejection: rejection
                    ))
                }
            }
        }

        return NameExtractionResult(
            candidates: deduplicate(accepted),
            rejections: rejections,
            handledAsCommand: false
        )
    }

    private func matches(_ phrase: [String], in tokens: [SpeechToken], at index: Int) -> Bool {
        for (offset, expected) in phrase.enumerated() where tokens[index + offset].normalized != expected {
            return false
        }
        return true
    }

    /// `confidence = template prior × validation confidence × recogniser confidence`.
    ///
    /// A product, so every stage can only lower it: a weak template cannot rescue a doubtful name,
    /// and a confident name cannot rescue a weak template.
    private func candidate(
        from slot: NameSlotResolution,
        template: NameTemplate,
        utterance u: Utterance
    ) -> NameCandidate {
        let confidence = template.prior * slot.validationConfidence * policy.asrFactor(for: u.confidence)
        return NameCandidate(
            name: slot.name,
            channel: u.channel,
            template: template.id,
            confidence: min(max(confidence, 0), 1)
        )
    }

    /// One candidate per distinct name, keeping the strongest evidence and highest confidence.
    /// Distinct names are *not* merged — a transcript naming two people must surface both so that
    /// Track A can ask rather than pick.
    private func deduplicate(_ candidates: [NameCandidate]) -> [NameCandidate] {
        var best: [String: NameCandidate] = [:]
        for candidate in candidates {
            let key = candidate.name.lowercased()
            guard let existing = best[key] else {
                best[key] = candidate
                continue
            }
            let existingLevel = existing.evidenceLevel ?? .e3
            let newLevel = candidate.evidenceLevel ?? .e3
            if newLevel < existingLevel
                || (newLevel == existingLevel && candidate.confidence > existing.confidence) {
                best[key] = candidate
            }
        }
        return best.values.sorted {
            let leftLevel = $0.evidenceLevel ?? .e3
            let rightLevel = $1.evidenceLevel ?? .e3
            if leftLevel != rightLevel { return leftLevel < rightLevel }
            if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
            return $0.name < $1.name
        }
    }
}
