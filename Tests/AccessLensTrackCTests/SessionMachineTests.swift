import XCTest
@testable import AccessLensTrackC

final class SessionMachineTests: XCTestCase {

    func testHappyPathTransitionsBackToIdle() async throws {
        let machine = SessionMachine()
        let state1 = await machine.currentState()
        XCTAssertEqual(state1, .idle)

        try await machine.startCapture()
        let state2 = await machine.currentState()
        XCTAssertEqual(state2, .capturing)

        try await machine.finishCapture()
        let state3 = await machine.currentState()
        XCTAssertEqual(state3, .binding)

        try await machine.completeBinding()
        let state4 = await machine.currentState()
        XCTAssertEqual(state4, .reporting)

        try await machine.finishReporting()
        let state5 = await machine.currentState()
        XCTAssertEqual(state5, .idle)
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
        let state6 = await machine.currentState()
        XCTAssertEqual(state6, .idle)
    }

    func testCorrectionReturnsReportingToBinding() async throws {
        let machine = SessionMachine()
        try await machine.startCapture()
        try await machine.finishCapture()
        try await machine.completeBinding()

        try await machine.rejectReportedIdentity()

        let stateAfterBind = await machine.currentState()
        XCTAssertEqual(stateAfterBind, .binding)
    }

    func testCorrectionOutsideReportingIsRejected() async {
        let machine = SessionMachine()

        do {
            try await machine.rejectReportedIdentity()
            XCTFail("expected invalid transition")
        } catch let error as SessionMachineError {
            XCTAssertEqual(error, .invalidTransition(from: .idle, to: .binding))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
