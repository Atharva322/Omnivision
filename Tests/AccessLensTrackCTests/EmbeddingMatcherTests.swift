import XCTest
@testable import AccessLensTrackC

final class EmbeddingMatcherTests: XCTestCase {
    func testCosineSimilarityForIdenticalAndOrthogonalVectors() {
        XCTAssertEqual(EmbeddingMatcher.cosineSimilarity([1, 0], [1, 0]), 1, accuracy: 0.0001)
        XCTAssertEqual(EmbeddingMatcher.cosineSimilarity([1, 0], [0, 1]), 0, accuracy: 0.0001)
    }

    func testNearestUsesBestSampleRatherThanAveragingPersonSamples() throws {
        let expected = UUID()
        let other = UUID()
        let matcher = EmbeddingMatcher(threshold: 0.9)
        let match = matcher.nearest(
            to: [1, 0],
            among: [
                expected: [[1, 0], [-1, 0]],
                other: [[0.8, 0.6]]
            ]
        )
        XCTAssertEqual(try XCTUnwrap(match).id, expected)
    }

    func testUncalibratedPolicyCannotReturnAMatch() {
        let match = EmbeddingMatcher.uncalibrated.nearest(
            to: [1, 0],
            among: [UUID(): [[1, 0]]]
        )
        XCTAssertNil(match)
    }
}
