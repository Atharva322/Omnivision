//
//  Fixture.swift
//  Track C — the fixture format used by `Fixtures/*.json`.
//
//  ⚠️ These are TEXT fixtures. They measure the parser and the extractor against transcripts, and
//  nothing else. They cannot produce a word error rate, a microphone comparison, a false-trigger
//  rate in real speech, or any statement about what the Ray-Ban Meta hardware hears. Those numbers
//  come from gate G1 and from the Hour-1 wake-word test, both of which need the glasses.
//

import Foundation

/// One transcript and what it should produce.
public struct FixtureCase: Decodable {
    public let id: String
    public let category: String?
    public let text: String
    /// "wearer" (default) or "other".
    public let channel: String?
    /// Recogniser confidence; defaults to 0.9.
    public let confidence: Float?
    public let note: String?
    public let expect: Expectation

    /// Only the keys actually present in the JSON are asserted, so a fixture can pin a command
    /// without also having to state what it expects about names, and vice versa. `null` is a real
    /// expectation ("nothing"), distinct from an absent key ("not asserted here").
    public struct Expectation: Decodable {
        public let command: String?
        public let commandAsserted: Bool
        public let argument: String?
        public let name: String?
        public let nameAsserted: Bool
        public let names: [String]?
        public let evidence: String?
        public let template: String?
        public let disposition: String?
        /// Safety invariant: whatever else happens, the assessment must not reach `.assert` or
        /// `.assertIfConfident`. Weaker than pinning a disposition, and the right shape for
        /// degraded input where hedging and rejecting are both acceptable but asserting is not.
        public let mustNotAssert: Bool?

        private enum CodingKeys: String, CodingKey {
            case command, argument, name, names, evidence, template, disposition, mustNotAssert
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            command = try container.decodeIfPresent(String.self, forKey: .command)
            commandAsserted = container.contains(.command)
            argument = try container.decodeIfPresent(String.self, forKey: .argument)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            names = try container.decodeIfPresent([String].self, forKey: .names)
            nameAsserted = container.contains(.name) || container.contains(.names)
            evidence = try container.decodeIfPresent(String.self, forKey: .evidence)
            template = try container.decodeIfPresent(String.self, forKey: .template)
            disposition = try container.decodeIfPresent(String.self, forKey: .disposition)
            mustNotAssert = try container.decodeIfPresent(Bool.self, forKey: .mustNotAssert)
        }

        /// True when this case asserts anything at all about names.
        public var checksNames: Bool { nameAsserted || mustNotAssert != nil }

        /// Expected names, in the order the extractor should rank them.
        public var expectedNames: [String] {
            if let names { return names }
            if let name { return [name] }
            return []
        }
    }

    public var resolvedChannel: Channel {
        channel?.lowercased() == "other" ? .other : .wearer
    }

    public var resolvedConfidence: Float {
        confidence ?? 0.9
    }

    public func utterance(at date: Date = Date(timeIntervalSince1970: 0)) -> Utterance {
        Utterance(
            text: text,
            channel: resolvedChannel,
            confidence: resolvedConfidence,
            at: date
        )
    }
}

/// One `Fixtures/*.json` file.
public struct FixtureSuite: Decodable {
    public let name: String
    public let description: String?
    public let cases: [FixtureCase]

    public static func load(from url: URL) throws -> FixtureSuite {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(FixtureSuite.self, from: data)
    }

    /// Load every `.json` file in `directory`, sorted by filename for a stable report.
    public static func loadAll(in directory: URL) throws -> [FixtureSuite] {
        let urls = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try urls.map(load(from:))
    }
}
