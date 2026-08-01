import XCTest
@testable import AccessLensTrackC

final class SessionMachineTests: XCTestCase {

    func testHappyPathTransitionsBackToIdle() async throws {
        let machine = SessionMachine()
        XCTAssertEqual(await machine.currentState(), .idle)

        try await machine.startCapture()
        XCTAssertEqual(await machine.currentState(), .capturing)

        try await machine.finishCapture()
        XCTAssertEqual(await machine.currentState(), .binding)

        try await machine.completeBinding()
        XCTAssertEqual(await machine.currentState(), .reporting)

        try await machine.finishReporting()
        XCTAssertEqual(await machine.currentState(), .idle)
    }

    func testInvalidTransitionThrows() async {
        let machine = SessionMachine()

        do {
            try await machine.finishCapture()
            XCTFail("expected invalid transition")
        } catch let error as SessionMachineError {
            XCTAssertEqual(error, .invalidTransition(from: .idle, to: .binding))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testPauseReturnsIdleFromActiveState() async throws {
        let machine = SessionMachine()
        try await machine.startCapture()
        try await machine.pause()
        XCTAssertEqual(await machine.currentState(), .idle)
    }
}
