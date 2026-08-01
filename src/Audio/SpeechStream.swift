//
// SpeechStream.swift
//
// On-device speech recognition over the AudioSpine PCM tap.
//
// Two non-obvious requirements:
//  1. `requiresOnDeviceRecognition = true` — audio must never leave the phone. This is both a
//     privacy commitment and what lets the demo run with no network.
//  2. SFSpeechRecognizer will not run indefinitely. Tasks are rotated on a detected silence gap
//     so no words are lost mid-sentence. Building this in from the start is far cheaper than
//     bolting it on after the recognizer dies at minute 3 of a demo.
//

import AVFoundation
import Foundation
import Speech

/// Which side of the conversation an utterance came from.
///
/// The glasses mic array beamforms to the WEARER and is documented as suppressing other
/// speakers. We cannot separate channels automatically from one mic — the operator tags
/// them during the G1 measurement. In the shipping app, `.wearer` is inferred from the
/// fact that only the wearer's speech is reliably intelligible.
enum Channel: String, CaseIterable {
  case wearer = "WEARER"
  case other = "OTHER"
}

struct Utterance: Identifiable {
  let id = UUID()
  let text: String
  let channel: Channel
  let confidence: Float
  let at: Date
}

@Observable
final class SpeechStream {

  private(set) var partialText = ""
  private(set) var utterances: [Utterance] = []
  private(set) var isAuthorized = false
  private(set) var lastError: String?
  private(set) var rotations = 0

  /// Operator-controlled tag applied to the next finalized utterance.
  var currentChannel: Channel = .wearer

  private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var lastVoiceActivity = Date()

  /// SFSpeechRecognizer degrades on long-running tasks. Rotate well before that.
  private let rotateAfter: TimeInterval = 45
  private let silenceGap: TimeInterval = 0.6
  private var taskStartedAt = Date()

  // MARK: - Authorization

  func requestAuthorization() async {
    let status = await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
    }
    isAuthorized = (status == .authorized)
    if !isAuthorized {
      lastError = "Speech recognition not authorized (status: \(status.rawValue))."
    }
  }

  // MARK: - Lifecycle

  func start() {
    guard isAuthorized else {
      lastError = "Cannot start — speech recognition not authorized."
      return
    }
    guard let recognizer, recognizer.isAvailable else {
      lastError = "Speech recognizer unavailable for en-US."
      return
    }
    guard recognizer.supportsOnDeviceRecognition else {
      lastError = "On-device recognition unsupported. Refusing to fall back to network — audio must not leave the device."
      return
    }
    beginTask()
  }

  func stop() {
    endTask()
    partialText = ""
  }

  func reset() {
    utterances.removeAll()
    partialText = ""
    rotations = 0
  }

  // MARK: - Audio intake

  /// Feed PCM from `AudioSpine.onBuffer`.
  func append(_ buffer: AVAudioPCMBuffer) {
    request?.append(buffer)

    if isVoiceActive(buffer) {
      lastVoiceActivity = Date()
      return
    }

    // Rotate only during a silence gap, so we never cut a sentence in half.
    let inSilence = Date().timeIntervalSince(lastVoiceActivity) > silenceGap
    let taskIsStale = Date().timeIntervalSince(taskStartedAt) > rotateAfter
    if inSilence && taskIsStale {
      rotateTask()
    }
  }

  /// Cheap RMS gate. Not a real VAD — enough to find a pause to rotate in.
  private func isVoiceActive(_ buffer: AVAudioPCMBuffer) -> Bool {
    guard let channelData = buffer.floatChannelData?[0] else { return false }
    let count = Int(buffer.frameLength)
    guard count > 0 else { return false }

    var sum: Float = 0
    for i in 0..<count {
      let sample = channelData[i]
      sum += sample * sample
    }
    let rms = (sum / Float(count)).squareRoot()
    return rms > 0.01
  }

  // MARK: - Task management

  private func beginTask() {
    let newRequest = SFSpeechAudioBufferRecognitionRequest()
    newRequest.shouldReportPartialResults = true
    newRequest.requiresOnDeviceRecognition = true
    newRequest.taskHint = .dictation
    request = newRequest
    taskStartedAt = Date()

    task = recognizer?.recognitionTask(with: newRequest) { [weak self] result, error in
      guard let self else { return }

      if let error, (error as NSError).code != 301 {  // 301 = task cancelled during rotation
        self.lastError = error.localizedDescription
      }

      guard let result else { return }
      let transcription = result.bestTranscription
      self.partialText = transcription.formattedString

      if result.isFinal {
        self.commit(transcription)
      }
    }
  }

  private func endTask() {
    request?.endAudio()
    task?.cancel()
    request = nil
    task = nil
  }

  func rotateTask() {
    // Commit whatever partial text we have before tearing the task down, so a rotation
    // never silently discards speech.
    if !partialText.isEmpty {
      utterances.append(
        Utterance(text: partialText, channel: currentChannel, confidence: -1, at: Date())
      )
      partialText = ""
    }
    endTask()
    rotations += 1
    beginTask()
  }

  private func commit(_ transcription: SFTranscription) {
    let text = transcription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }

    let segments = transcription.segments
    let avgConfidence = segments.isEmpty
      ? -1
      : segments.map(\.confidence).reduce(0, +) / Float(segments.count)

    utterances.append(
      Utterance(text: text, channel: currentChannel, confidence: avgConfidence, at: Date())
    )
    partialText = ""
  }

  // MARK: - G1 measurement

  /// Mean confidence per channel. The G1 gate: the wearer channel must be dramatically
  /// cleaner than the other channel, or the echo-primary design is wrong and we fall back
  /// to explicit binding only ("Lumen, this is Priya").
  func meanConfidence(for channel: Channel) -> Float? {
    let scored = utterances.filter { $0.channel == channel && $0.confidence >= 0 }
    guard !scored.isEmpty else { return nil }
    return scored.map(\.confidence).reduce(0, +) / Float(scored.count)
  }

  func count(for channel: Channel) -> Int {
    utterances.filter { $0.channel == channel }.count
  }
}
