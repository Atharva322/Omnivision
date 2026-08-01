import Foundation
import XCTest
@testable import AccessLensTrackC

/// A face seen two minutes ago says nothing about who is standing in front of the wearer now.
/// Without a freshness window the last face ever seen would attach itself to every later name —
/// binding a stranger's embedding to whoever the wearer happens to greet next, which is precisely
/// the kind of silent mislabelling the evidence ladder exists to prevent.
final class FacePresenceTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testNoFaceSeenMeansNoEvidence() {
        let presence = FacePresence()
        XCTAssertNil(presence.live(at: t0))
    }

    func testAFaceJustSeenIsLiveEvidence() {
        var presence = FacePresence()
        let face = UUID()
        presence.saw(face, at: t0)

        XCTAssertEqual(presence.live(at: t0.addingTimeInterval(1)), face)
    }

    func testAFaceOlderThanTheWindowIsNotEvidence() {
        var presence = FacePresence()
        presence.saw(UUID(), at: t0)

        let stale = t0.addingTimeInterval(FacePresence.window + 1)
        XCTAssertNil(presence.live(at: stale), "a face this old must not attach to a spoken name")
    }

    func testTheWindowBoundaryItselfStillCounts() {
        var presence = FacePresence()
        let face = UUID()
        presence.saw(face, at: t0)

        XCTAssertEqual(presence.live(at: t0.addingTimeInterval(FacePresence.window)), face)
    }

    func testSeeingANewFaceReplacesThePrevious() {
        var presence = FacePresence()
        let first = UUID(), second = UUID()
        presence.saw(first, at: t0)
        presence.saw(second, at: t0.addingTimeInterval(5))

        XCTAssertEqual(presence.live(at: t0.addingTimeInterval(6)), second)
    }

    /// Seeing the same face again must extend its life, or a steady conversation would go stale
    /// mid-sentence while the person is still standing there.
    func testSeeingTheSameFaceAgainRefreshesTheWindow() {
        var presence = FacePresence()
        let face = UUID()
        presence.saw(face, at: t0)

        let late = t0.addingTimeInterval(FacePresence.window)
        presence.saw(face, at: late)

        XCTAssertEqual(presence.live(at: late.addingTimeInterval(FacePresence.window)), face)
    }

    /// The wearer said "forget them" or walked away. Evidence must be droppable on demand.
    func testClearingRemovesEvidenceImmediately() {
        var presence = FacePresence()
        presence.saw(UUID(), at: t0)
        presence.clear()

        XCTAssertNil(presence.live(at: t0))
    }
}
