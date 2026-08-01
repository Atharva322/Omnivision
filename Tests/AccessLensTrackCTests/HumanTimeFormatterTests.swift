import XCTest
@testable import AccessLensTrackC

final class HumanTimeFormatterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let formatter = HumanTimeFormatter()

    func testFormatsSpeechFriendlyRelativeTime() {
        XCTAssertEqual(formatter.string(since: now.addingTimeInterval(-20), relativeTo: now), "just now")
        XCTAssertEqual(formatter.string(since: now.addingTimeInterval(-60), relativeTo: now), "a minute ago")
        XCTAssertEqual(formatter.string(since: now.addingTimeInterval(-180), relativeTo: now), "three minutes ago")
        XCTAssertEqual(formatter.string(since: now.addingTimeInterval(-3_600), relativeTo: now), "an hour ago")
        XCTAssertEqual(formatter.string(since: now.addingTimeInterval(-86_400), relativeTo: now), "yesterday")
        XCTAssertEqual(formatter.string(since: now.addingTimeInterval(-21 * 86_400), relativeTo: now), "three weeks ago")
        XCTAssertEqual(formatter.string(since: now.addingTimeInterval(-400 * 86_400), relativeTo: now), "a year ago")
    }

    func testNeverEmitsTimestampOrFutureTime() {
        let result = formatter.string(since: now.addingTimeInterval(10_000), relativeTo: now)
        XCTAssertEqual(result, "just now")
        XCTAssertFalse(result.contains(":"))
        XCTAssertFalse(result.contains("/"))
    }
}
