//
// Narrator.swift
// Track B — speech output through the glasses.
//
// iOS ONLY (AVSpeechSynthesizer + AVAudioSession).
//
// ⚠️ SCOPE — this is PLUMBING, not Track D's work.
//
// It carries text to the speaker and enforces ordering. It deliberately does NOT decide wording,
// design earcons, own the consent script, or run validation. Those are Track D's, and this exists
// so they inherit a working audio path instead of starting from silence.
//
// Every ordering rule lives in `SpeechQueue`, which is pure and fully tested. This file is the
// shell that obeys it, so the logic worth trusting is not trapped behind a speaker.
//

#if os(iOS)

import AVFoundation
import Foundation
import AccessLensTrackC

@Observable
final class Narrator: NSObject, Narrating {

    /// Placeholder wording so both tracks are demoable today. Track D replaces this wholesale.
    static func line(for person: Person) -> String {
        switch person.effectiveTier {
        case .inner:
            // Verbosity is inversely proportional to familiarity. Reading a full card for someone
            // you see daily is insulting, so the earcon carries it and only a pending note speaks.
            return person.pendingNotes.first ?? ""
        case .familiar:
            return person.name
        case .acquaintance, .newPerson:
            return [person.name, person.org].compactMap { $0 }.joined(separator: ", ")
        }
    }

    private(set) var isSpeaking = false
    private(set) var lastError: String?

    private var queue = SpeechQueue()
    private let synthesizer = AVSpeechSynthesizer()

    /// Set by the caller from VAD. While true, only `.critical` reaches the speaker — narrating
    /// over someone mid-sentence is worse than staying silent, and it is what makes continuous
    /// proactive narration wearable at all.
    var someoneElseIsSpeaking = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Narrating

    func say(_ text: String, priority: Priority) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        if someoneElseIsSpeaking && priority != .critical { return }

        perform(queue.enqueue(text, priority: priority))
    }

    func play(_ earcon: Earcon) {
        // Track D designs the actual tones. Distinct system sounds keep the states audibly
        // different in the meantime rather than silently identical.
        let identifier: SystemSoundID
        switch earcon {
        case .captureOn:    identifier = 1113
        case .captureOff:   identifier = 1114
        case .saved:        identifier = 1057
        case .unknown:      identifier = 1053
        case .disconnected: identifier = 1073
        }
        AudioServicesPlaySystemSound(identifier)
    }

    func repeatLast() {
        perform(queue.repeatLast())
    }

    /// Backs "Lumen, pause".
    func stopAll() {
        queue.stop()
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    // MARK: - Execution

    private func perform(_ action: SpeechAction) {
        switch action {
        case .speakNow(let text):
            utter(text)
        case .interruptAndSpeak(let text):
            synthesizer.stopSpeaking(at: .immediate)
            utter(text)
        case .queued, .dropped, .idle:
            break
        }
    }

    private func utter(_ text: String) {
        do {
            // Category is NOT changed here. AudioSpine owns the session and holds it in
            // .playAndRecord for HFP capture; reconfiguring it mid-session would tear down the
            // microphone route the whole social track depends on.
            try AVAudioSession.sharedInstance().setActive(true, options: [])
        } catch {
            lastError = error.localizedDescription
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.postUtteranceDelay = 0.1
        isSpeaking = true
        synthesizer.speak(utterance)
    }
}

extension Narrator: AVSpeechSynthesizerDelegate {

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
        isSpeaking = false
        perform(queue.finishedSpeaking())
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
    ) {
        // Cancellation is an interruption, and the interrupting utterance is already speaking.
        // Draining the queue here would talk over it.
        isSpeaking = false
    }
}

#endif
