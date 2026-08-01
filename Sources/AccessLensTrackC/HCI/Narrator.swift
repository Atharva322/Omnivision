import Foundation

/// Pluggable audio boundary. Tests use a recorder; Apple builds use `AVNarrationOutput`.
public protocol NarrationOutput: Sendable {
    func speak(_ text: String, priority: Priority) async
    func play(_ earcon: Earcon) async
    func playPronunciation(at url: URL, priority: Priority) async -> Bool
    func stop() async
}

/// Track B feeds final utterances here. Normal and discreet speech wait through the configured
/// tailoff; critical failures deliberately bypass the wait.
public protocol SpeechActivityMonitoring: Sendable {
    func observe(_ utterance: Utterance) async
    func noteOtherSpeech(at date: Date) async
    func holdUntilSilence() async
}

public actor SpeechActivityMonitor: SpeechActivityMonitoring {
    public let quietPeriod: TimeInterval
    private var lastOtherSpeechAt: Date?

    public init(quietPeriod: TimeInterval = 1.25) {
        self.quietPeriod = max(0, quietPeriod)
    }

    public func observe(_ utterance: Utterance) {
        guard utterance.channel == .other else { return }
        noteOtherSpeech(at: utterance.at)
    }

    /// Track B should call this on every VAD-positive buffer from the other-person channel. Final
    /// utterances are a fallback; live VAD pulses are what prevent speech from starting mid-turn.
    public func noteOtherSpeech(at date: Date = Date()) {
        if let lastOtherSpeechAt {
            self.lastOtherSpeechAt = max(lastOtherSpeechAt, date)
        } else {
            lastOtherSpeechAt = date
        }
    }

    /// Waits for one complete quiet period after the latest other-person speech. New observations
    /// extend the wait, so a pause inside a sentence is not mistaken for the end of a turn.
    public func holdUntilSilence() async {
        while !Task.isCancelled {
            guard let lastOtherSpeechAt else { return }
            let remaining = quietPeriod - Date().timeIntervalSince(lastOtherSpeechAt)
            if remaining <= 0 { return }

            let slice = min(remaining, 0.1)
            do {
                try await Task.sleep(nanoseconds: UInt64(slice * 1_000_000_000))
            } catch {
                return
            }
        }
    }
}

public struct SilentNarrationOutput: NarrationOutput {
    public init() {}
    public func speak(_ text: String, priority: Priority) async {}
    public func play(_ earcon: Earcon) async {}
    public func playPronunciation(at url: URL, priority: Priority) async -> Bool { false }
    public func stop() async {}
}

/// Priority-queued, silence-aware Track D narrator.
///
/// The frozen `Narrating` methods remain synchronous for Tracks A/B. Async `submit` and `flush`
/// methods are also exposed for deterministic integration tests and orderly app shutdown.
public final class Narrator: Narrating, @unchecked Sendable {
    private let core: NarratorCore
    private let activityMonitor: any SpeechActivityMonitoring

    public init(
        output: any NarrationOutput,
        activityMonitor: any SpeechActivityMonitoring = SpeechActivityMonitor()
    ) {
        self.activityMonitor = activityMonitor
        self.core = NarratorCore(output: output, activityMonitor: activityMonitor)
    }

    #if canImport(AVFoundation)
    public convenience init(
        activityMonitor: any SpeechActivityMonitoring = SpeechActivityMonitor()
    ) {
        self.init(output: AVNarrationOutput(), activityMonitor: activityMonitor)
    }
    #else
    public convenience init(
        activityMonitor: any SpeechActivityMonitoring = SpeechActivityMonitor()
    ) {
        self.init(output: SilentNarrationOutput(), activityMonitor: activityMonitor)
    }
    #endif

    public func say(_ text: String, priority: Priority) {
        let cue = NarrationCue.speech(
            NarrationCopy.limited(text),
            priority: priority
        )
        Task { await core.enqueue([cue]) }
    }

    public func play(_ earcon: Earcon) {
        Task { await core.enqueue([.earcon(earcon)]) }
    }

    public func repeatLast() {
        Task { await core.repeatLast() }
    }

    public static func line(for person: Person) -> String {
        NarrationCopy.line(for: person)
    }

    public func observe(_ utterance: Utterance) {
        Task { await activityMonitor.observe(utterance) }
    }

    public func noteOtherSpeech(at date: Date = Date()) {
        Task { await activityMonitor.noteOtherSpeech(at: date) }
    }

    public func holdUntilSilence() async {
        await activityMonitor.holdUntilSilence()
    }

    public func perform(_ action: SocialMemoryAction, now: Date = Date()) {
        perform(NarrationCopy.plan(for: action, now: now))
    }

    public func perform(_ plan: NarrationPlan) {
        Task { await core.enqueue(plan.cues) }
    }

    public func submit(_ plan: NarrationPlan) async {
        await core.enqueue(plan.cues)
    }

    public func submit(_ action: SocialMemoryAction, now: Date = Date()) async {
        await submit(NarrationCopy.plan(for: action, now: now))
    }

    public func submitRepeatLast() async {
        await core.repeatLast()
    }

    public func flush() async {
        await core.flush()
    }
}

private actor NarratorCore {
    private struct Request: Sendable {
        let sequence: UInt64
        let cue: NarrationCue

        var priority: Priority {
            switch cue {
            case .speech(_, let priority), .pronunciation(_, _, let priority):
                return priority
            case .earcon(let earcon):
                return earcon == .disconnected ? .critical : .normal
            }
        }
    }

    private let output: any NarrationOutput
    private let activityMonitor: any SpeechActivityMonitoring
    private var queue: [Request] = []
    private var nextSequence: UInt64 = 0
    private var isDraining = false
    private var current: Request?
    private var currentTask: Task<Void, Never>?
    private var lastCompleted: NarrationCue?
    private var flushWaiters: [CheckedContinuation<Void, Never>] = []

    init(output: any NarrationOutput, activityMonitor: any SpeechActivityMonitoring) {
        self.output = output
        self.activityMonitor = activityMonitor
    }

    func enqueue(_ cues: [NarrationCue]) async {
        let accepted = cues.compactMap(normalized)
        guard !accepted.isEmpty else { return }

        for cue in accepted {
            queue.append(Request(sequence: nextSequence, cue: cue))
            nextSequence &+= 1
        }
        sortQueue()

        if accepted.contains(where: { priority(of: $0) == .critical }),
           let current, current.priority != .critical {
            currentTask?.cancel()
            await output.stop()
        }

        guard !isDraining else { return }
        isDraining = true
        Task { await self.drain() }
    }

    func repeatLast() async {
        guard let lastCompleted else { return }
        await enqueue([lastCompleted])
    }

    func flush() async {
        if !isDraining && queue.isEmpty { return }
        await withCheckedContinuation { continuation in
            flushWaiters.append(continuation)
        }
    }

    private func drain() async {
        while !queue.isEmpty {
            let request = queue.removeFirst()
            current = request

            let task = Task { [output, activityMonitor] in
                switch request.cue {
                case .speech(let text, let priority):
                    if priority != .critical {
                        await activityMonitor.holdUntilSilence()
                        guard !Task.isCancelled else { return }
                    }
                    await output.speak(text, priority: priority)
                case .earcon(let earcon):
                    await output.play(earcon)
                case .pronunciation(let path, let fallback, let priority):
                    if priority != .critical {
                        await activityMonitor.holdUntilSilence()
                        guard !Task.isCancelled else { return }
                    }
                    let played = await output.playPronunciation(
                        at: URL(fileURLWithPath: path),
                        priority: priority
                    )
                    if !played, !Task.isCancelled {
                        await output.speak(fallback, priority: priority)
                    }
                }
            }
            currentTask = task
            await task.value

            if !task.isCancelled {
                switch request.cue {
                case .speech, .pronunciation:
                    lastCompleted = request.cue
                case .earcon:
                    break
                }
            }
            currentTask = nil
            current = nil
        }

        isDraining = false
        let waiters = flushWaiters
        flushWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func normalized(_ cue: NarrationCue) -> NarrationCue? {
        switch cue {
        case .speech(let text, let priority):
            let limited = NarrationCopy.limited(text)
            return limited.isEmpty ? nil : .speech(limited, priority: priority)
        case .earcon:
            return cue
        case .pronunciation(let path, let fallback, let priority):
            let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
            let safeFallback = NarrationCopy.safeName(fallback)
            guard !trimmedPath.isEmpty else {
                return .speech(safeFallback, priority: priority)
            }
            return .pronunciation(
                path: trimmedPath,
                fallback: safeFallback,
                priority: priority
            )
        }
    }

    private func sortQueue() {
        queue.sort { lhs, rhs in
            let leftRank = rank(lhs.priority)
            let rightRank = rank(rhs.priority)
            return leftRank == rightRank ? lhs.sequence < rhs.sequence : leftRank < rightRank
        }
    }

    private func priority(of cue: NarrationCue) -> Priority {
        switch cue {
        case .speech(_, let priority), .pronunciation(_, _, let priority):
            return priority
        case .earcon(let earcon):
            return earcon == .disconnected ? .critical : .normal
        }
    }

    private func rank(_ priority: Priority) -> Int {
        switch priority {
        case .critical: return 0
        case .normal: return 1
        case .discreet: return 2
        }
    }
}
