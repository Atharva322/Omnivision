import Foundation

public enum SessionState: String, Codable, Equatable, Hashable, Sendable {
    case idle
    case capturing
    case binding
    case reporting
}

public enum SessionMachineError: Error, Equatable {
    case invalidTransition(from: SessionState, to: SessionState)
}

public actor SessionMachine {
    private var state: SessionState
    private let eventLog: EventLog?

    public init(initialState: SessionState = .idle, eventLog: EventLog? = nil) {
        self.state = initialState
        self.eventLog = eventLog
    }

    public func currentState() -> SessionState {
        state
    }

    public func startCapture() async throws {
        try await transition(to: .capturing, allowedFrom: [.idle], reason: "startCapture")
    }

    public func finishCapture() async throws {
        try await transition(to: .binding, allowedFrom: [.capturing], reason: "finishCapture")
    }

    public func completeBinding() async throws {
        try await transition(to: .reporting, allowedFrom: [.binding], reason: "completeBinding")
    }

    public func finishReporting() async throws {
        try await transition(to: .idle, allowedFrom: [.reporting], reason: "finishReporting")
    }

    /// Re-open binding after the wearer rejects the reported identity.
    public func rejectReportedIdentity() async throws {
        try await transition(to: .binding, allowedFrom: [.reporting], reason: "identityCorrection")
    }

    public func pause() async throws {
        guard state != .idle else {
            return
        }
        try await transition(
            to: .idle,
            allowedFrom: [.capturing, .binding, .reporting],
            reason: "pause"
        )
    }

    private func transition(
        to newState: SessionState,
        allowedFrom: Set<SessionState>,
        reason: String
    ) async throws {
        guard allowedFrom.contains(state) else {
            throw SessionMachineError.invalidTransition(from: state, to: newState)
        }

        let previous = state
        state = newState

        if let eventLog {
            try await eventLog.logTransition(from: previous, to: newState, reason: reason)
        }
    }
}
