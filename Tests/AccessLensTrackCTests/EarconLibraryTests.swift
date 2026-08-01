import XCTest
@testable import AccessLensTrackC

final class EarconLibraryTests: XCTestCase {
    func testEveryStateHasAShortDistinctPattern() {
        let patterns = Earcon.allCases.map(EarconLibrary.pattern(for:))
        XCTAssertEqual(Set(patterns.map(\.tones)).count, Earcon.allCases.count)
        XCTAssertTrue(patterns.allSatisfy { !$0.tones.isEmpty && $0.duration < 1 })
    }

    func testCaptureDirectionsAndDisconnectUrgencyAreAudible() {
        let on = EarconLibrary.pattern(for: .captureOn).tones.map(\.frequency)
        let off = EarconLibrary.pattern(for: .captureOff).tones.map(\.frequency)
        let disconnected = EarconLibrary.pattern(for: .disconnected)

        XCTAssertLessThan(on.first!, on.last!)
        XCTAssertGreaterThan(off.first!, off.last!)
        XCTAssertEqual(disconnected.tones.count, 3)
        XCTAssertTrue(disconnected.tones.allSatisfy { $0.amplitude >= 0.5 })
    }
}
