//
//  NameDenylistTests.swift
//  Track C — the denylist must never fail open.
//

import XCTest
@testable import AccessLensTrackC

final class NameDenylistTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("trackc-denylist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func write(_ contents: String, named name: String) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - The shipped resource

    func testBundledDenylistLoadsFromTheResource() {
        let denylist = NameDenylist.bundled()
        XCTAssertFalse(denylist.isDegraded, "shipped resource should load: \(denylist.source)")
        XCTAssertFalse(denylist.hardDenied.isEmpty)
        XCTAssertFalse(denylist.ambiguous.isEmpty)
    }

    func testTheDocumentedFalsePositivesAreCovered() {
        let denylist = NameDenylist.bundled()
        for term in ["today", "everyone", "there", "again", "later", "friend", "team", "all", "great", "good", "nice"] {
            XCTAssertEqual(
                denylist.verdict(for: term, strength: .strong), .deniedHard,
                "\(term) must be denied in every template"
            )
        }
    }

    func testAmbiguousTermsDependOnTemplateStrength() {
        let denylist = NameDenylist.bundled()
        XCTAssertEqual(denylist.verdict(for: "Mark", strength: .strong), .allowed)
        XCTAssertEqual(denylist.verdict(for: "Mark", strength: .medium), .deniedAmbiguous)
        XCTAssertEqual(denylist.verdict(for: "Mark", strength: .weak), .deniedAmbiguous)
    }

    func testLegitimateNamesAreNotDenied() {
        // The trade-off is documented in docs/TRACK_C.md: the denylist may cost recall on weak
        // templates, but it must never make a common given name unbindable everywhere.
        let denylist = NameDenylist.bundled()
        for name in ["Priya", "Marcus", "Daniel", "Grace", "Faith", "Joy", "Jack", "Rosa", "Yuki", "Kwame"] {
            XCTAssertEqual(
                denylist.verdict(for: name, strength: .weak), .allowed,
                "\(name) is a real given name and must remain bindable from any template"
            )
        }
    }

    func testMatchingIgnoresCaseAndPunctuation() {
        let denylist = NameDenylist.bundled()
        XCTAssertEqual(denylist.verdict(for: "TODAY", strength: .strong), .deniedHard)
        XCTAssertEqual(denylist.verdict(for: "Today", strength: .strong), .deniedHard)
        XCTAssertEqual(denylist.verdict(for: "y'all", strength: .strong), .deniedHard)
    }

    // MARK: - Failure modes

    func testMissingFileFallsBackToTheEmbeddedListRatherThanDenyingNothing() {
        let denylist = NameDenylist.load(from: scratch.appendingPathComponent("does-not-exist.json"))
        XCTAssertTrue(denylist.isDegraded)
        XCTAssertEqual(denylist.verdict(for: "today", strength: .strong), .deniedHard)
    }

    func testNilURLFallsBackToTheEmbeddedList() {
        let denylist = NameDenylist.load(from: nil)
        XCTAssertTrue(denylist.isDegraded)
        XCTAssertEqual(denylist.verdict(for: "everyone", strength: .strong), .deniedHard)
    }

    func testMalformedJSONFallsBackToTheEmbeddedList() throws {
        let url = try write("{ this is not json ", named: "name_denylist.json")
        let denylist = NameDenylist.load(from: url)
        XCTAssertTrue(denylist.isDegraded)
        XCTAssertEqual(denylist.verdict(for: "today", strength: .strong), .deniedHard)
    }

    func testWrongShapeJSONFallsBackToTheEmbeddedList() throws {
        let url = try write("[1, 2, 3]", named: "name_denylist.json")
        let denylist = NameDenylist.load(from: url)
        XCTAssertTrue(denylist.isDegraded)
        XCTAssertEqual(denylist.verdict(for: "great", strength: .strong), .deniedHard)
    }

    func testEmptyHardDenyIsTreatedAsAFailureNotAsPermission() throws {
        let url = try write(#"{"version": 1, "hard_deny": [], "ambiguous": []}"#, named: "name_denylist.json")
        let denylist = NameDenylist.load(from: url)
        XCTAssertTrue(
            denylist.isDegraded,
            "an empty denylist is indistinguishable from a truncated write and must not be trusted"
        )
        XCTAssertEqual(denylist.verdict(for: "today", strength: .strong), .deniedHard)
    }

    func testOnDiskEditsMayOnlyAddDenials() throws {
        // A file that omits "today" cannot un-deny it. Removing a term is a code change.
        let url = try write(
            #"{"version": 1, "hard_deny": [{"term": "zzzplaceholder"}], "ambiguous": []}"#,
            named: "name_denylist.json"
        )
        let denylist = NameDenylist.load(from: url)
        XCTAssertFalse(denylist.isDegraded)
        XCTAssertEqual(denylist.verdict(for: "zzzplaceholder", strength: .strong), .deniedHard)
        XCTAssertEqual(denylist.verdict(for: "today", strength: .strong), .deniedHard)
    }

    // MARK: - End-to-end safety

    func testDenylistFailureCannotProduceAnUnsafePositiveIdentification() {
        let degraded = NameDenylist.load(from: URL(fileURLWithPath: "/nonexistent/name_denylist.json"))
        XCTAssertTrue(degraded.isDegraded)

        let extractor = NameExtractor(denylist: degraded, validator: PortableNameValidator())
        for text in ["Nice to meet you today", "This is great", "Thanks everyone", "Hi there"] {
            assertNoName(
                extractor.candidates(in: wearer(text)),
                "a denylist load failure must not open the door to a false name: \(text)"
            )
        }
    }
}
