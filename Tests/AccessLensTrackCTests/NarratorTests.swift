import Foundation
import XCTest
@testable import AccessLensTrackC

final class NarratorTests: XCTestCase {
    func testNormalSpeechWaitsUntilOtherPersonIsSilent() async {
        let output = RecordingNarrationOutput()
        let activity = ManualSpeechActivityMonitor(isSilent: false)
        let narrator = Narrator(output: output, activityMonitor: activity)

        await narrator.submit(NarrationPlan(cues: [
            .speech("Priya.", priority: .normal)
        ]))
        try? await Task.sleep(nanoseconds: 30_000_000)
        let beforeSilence = await output.snapshot()
        XCTAssertEqual(beforeSilence, [])

        await activity.release()
        await narrator.flush()
        let afterSilence = await output.snapshot()
        XCTAssertEqual(afterSilence, [.speech("Priya.", .normal)])
    }

    func testCriticalFailureBreaksThroughSilenceHold() async {
        let output = RecordingNarrationOutput()
        let activity = ManualSpeechActivityMonitor(isSilent: false)
        let narrator = Narrator(output: output, activityMonitor: activity)

        await narrator.submit(NarrationPlan(cues: [
            .speech("A normal update.", priority: .normal)
        ]))
        try? await Task.sleep(nanoseconds: 30_000_000)
        await narrator.submit(NarrationCopy.glassesDisconnected)
        await narrator.flush()

        let events = await output.snapshot()
        XCTAssertTrue(events.contains(.earcon(.disconnected)))
        XCTAssertTrue(events.contains(.speech("Glasses disconnected.", .critical)))
        XCTAssertFalse(events.contains(.speech("A normal update.", .normal)))
    }

    func testPriorityQueueIsCriticalThenNormalThenDiscreet() async {
        let output = RecordingNarrationOutput()
        let activity = ManualSpeechActivityMonitor(isSilent: true)
        let narrator = Narrator(output: output, activityMonitor: activity)

        await narrator.submit(NarrationPlan(cues: [
            .speech("Discreet.", priority: .discreet),
            .speech("Critical.", priority: .critical),
            .speech("Normal.", priority: .normal)
        ]))
        await narrator.flush()

        let events = await output.snapshot()
        XCTAssertEqual(events, [
            .speech("Critical.", .critical),
            .speech("Normal.", .normal),
            .speech("Discreet.", .discreet)
        ])
    }

    func testRepeatLastRepeatsLastCompletedSpeech() async {
        let output = RecordingNarrationOutput()
        let narrator = Narrator(
            output: output,
            activityMonitor: ManualSpeechActivityMonitor(isSilent: true)
        )

        await narrator.submit(NarrationPlan(cues: [
            .speech("I didn't catch a name.", priority: .normal)
        ]))
        await narrator.flush()
        await narrator.submitRepeatLast()
        await narrator.flush()

        let events = await output.snapshot()
        XCTAssertEqual(events, [
            .speech("I didn't catch a name.", .normal),
            .speech("I didn't catch a name.", .normal)
        ])
    }

    func testUsesPronunciationClipAndFallsBackWhenMissing() async {
        let output = RecordingNarrationOutput(pronunciationSucceeds: true)
        let narrator = Narrator(
            output: output,
            activityMonitor: ManualSpeechActivityMonitor(isSilent: true)
        )
        await narrator.submit(NarrationPlan(cues: [
            .pronunciation(path: "/tmp/priya.caf", fallback: "Priya", priority: .normal)
        ]))
        await narrator.flush()
        let clipEvents = await output.snapshot()
        XCTAssertEqual(clipEvents, [.pronunciation("/tmp/priya.caf", .normal)])

        let fallbackOutput = RecordingNarrationOutput(pronunciationSucceeds: false)
        let fallbackNarrator = Narrator(
            output: fallbackOutput,
            activityMonitor: ManualSpeechActivityMonitor(isSilent: true)
        )
        await fallbackNarrator.submit(NarrationPlan(cues: [
            .pronunciation(path: "/tmp/missing.caf", fallback: "Priya", priority: .normal)
        ]))
        await fallbackNarrator.flush()
        let fallbackEvents = await fallbackOutput.snapshot()
        XCTAssertEqual(fallbackEvents, [
            .pronunciation("/tmp/missing.caf", .normal),
            .speech("Priya", .normal)
        ])
    }
}

private enum RecordedNarrationEvent: Equatable, Sendable {
    case speech(String, Priority)
    case earcon(Earcon)
    case pronunciation(String, Priority)
    case stopped
}

private actor RecordingNarrationOutput: NarrationOutput {
    private var events: [RecordedNarrationEvent] = []
    private let pronunciationSucceeds: Bool

    init(pronunciationSucceeds: Bool = true) {
        self.pronunciationSucceeds = pronunciationSucceeds
    }

    func speak(_ text: String, priority: Priority) {
        events.append(.speech(text, priority))
    }

    func play(_ earcon: Earcon) {
        events.append(.earcon(earcon))
    }

    func playPronunciation(at url: URL, priority: Priority) -> Bool {
        events.append(.pronunciation(url.path, priority))
        return pronunciationSucceeds
    }

    func stop() {
        events.append(.stopped)
    }

    func snapshot() -> [RecordedNarrationEvent] {
        events.filter { $0 != .stopped }
    }
}

private actor ManualSpeechActivityMonitor: SpeechActivityMonitoring {
    private var isSilent: Bool

    init(isSilent: Bool) {
        self.isSilent = isSilent
    }

    func observe(_ utterance: Utterance) {}
    func noteOtherSpeech(at date: Date) {}

    func holdUntilSilence() async {
        while !isSilent && !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 5_000_000)
            } catch {
                return
            }
        }
    }

    func release() {
        isSilent = true
    }
}
