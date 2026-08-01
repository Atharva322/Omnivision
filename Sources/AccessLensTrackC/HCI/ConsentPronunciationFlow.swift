#if canImport(AVFoundation)
import AVFoundation
import Foundation

public enum ConsentPronunciationOutcome: Equatable, Sendable {
    case granted(pronunciationPath: String)
    case declined
    case unclear
}

/// Audio-only consent gate for new-person capture. The caller must not start
/// `SocialMemoryCoordinator.beginCapture` until this returns `.granted`.
public actor ConsentPronunciationFlow {
    private let narrator: Narrator
    private let recorder: PronunciationClipRecorder
    private let parser: ConsentDecisionParser

    public init(
        narrator: Narrator,
        recorder: PronunciationClipRecorder = PronunciationClipRecorder(),
        parser: ConsentDecisionParser = ConsentDecisionParser()
    ) {
        self.narrator = narrator
        self.recorder = recorder
        self.parser = parser
    }

    public func requestConsent() async {
        await narrator.submit(NarrationCopy.consentPlan())
        await narrator.flush()
    }

    public func handle(
        answer: String,
        subjectID: UUID,
        pcmStream: AsyncStream<AVAudioPCMBuffer>
    ) async throws -> ConsentPronunciationOutcome {
        let decision = parser.parse(answer)
        await narrator.submit(NarrationCopy.consentResponse(decision))
        await narrator.flush()

        switch decision {
        case .granted:
            let path = try await recorder.capture(
                from: pcmStream,
                personID: subjectID,
                maximumDuration: 1
            )
            await narrator.submit(NarrationPlan(cues: [.earcon(.captureOff)]))
            await narrator.flush()
            return .granted(pronunciationPath: path)
        case .declined:
            return .declined
        case .unclear:
            return .unclear
        }
    }
}
#endif
