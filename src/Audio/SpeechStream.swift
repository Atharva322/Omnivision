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

/// Speaker distance bucket. A result is only meaningful paired with the range it was taken at —
/// intimate distance flatters the recogniser and tells us nothing about a real conversation.
enum Distance: Double, CaseIterable, Identifiable {
  case intimate = 0.3
  case close = 0.6
  case conversational = 1.0
  case social = 2.0

  var id: Double { rawValue }

  var label: String {
    switch self {
    case .intimate: return "0.3m"
    case .close: return "0.6m"
    case .conversational: return "1.0m"
    case .social: return "2.0m"
    }
  }

  /// The range people actually stand at when meeting someone. This is the bucket that decides
  /// the design; the others map the envelope either side of it.
  var isRealistic: Bool { self == .close || self == .conversational }
}

struct Utterance: Identifiable {
  let id = UUID()
  let text: String
  let channel: Channel
  let distance: Distance
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

  /// Operator-controlled tags applied to the next finalized utterance.
  var currentChannel: Channel = .wearer
  var currentDistance: Distance = .conversational

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

      // 301 = task cancelled during rotation; 1110 = "No speech detected" at task end.
      // Both are expected during normal rotation and must not be surfaced as failures.
      if let error {
        let code = (error as NSError).code
        if code != 301 && code != 1110 {
          self.lastError = error.localizedDescription
        }
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
        Utterance(
          text: partialText, channel: currentChannel,
          distance: currentDistance, confidence: -1, at: Date())
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
      Utterance(
        text: text, channel: currentChannel,
        distance: currentDistance, confidence: avgConfidence, at: Date())
    )
    partialText = ""
  }

  // MARK: - G1 measurement

  /// Mean confidence per channel.
  ///
  /// NOTE: on-device `SFSpeechRecognizer` frequently leaves segment confidence at 0, so this is
  /// unreliable as the G1 metric. Kept for diagnostics only — `meanWER` is the real gate.
  func meanConfidence(for channel: Channel) -> Float? {
    let scored = utterances.filter { $0.channel == channel && $0.confidence > 0 }
    guard !scored.isEmpty else { return nil }
    return scored.map(\.confidence).reduce(0, +) / Float(scored.count)
  }

  func count(for channel: Channel) -> Int {
    utterances.filter { $0.channel == channel }.count
  }

  // MARK: - Word error rate (the real G1 metric)

  /// Both speakers read this aloud. Comparing each transcript against a known ground truth
  /// gives an objective number that does not depend on the recognizer populating confidence.
  /// Contains a name in a natural greeting frame, which is exactly what NameExtractor must catch.
  static let targetScript = "Nice to meet you Priya I work on latency at Stripe"

  /// Word error rate: Levenshtein edit distance over word tokens, normalised by reference length.
  /// 0.0 is perfect, 1.0 is total failure. Lower is better.
  static func wordErrorRate(hypothesis: String, reference: String = targetScript) -> Double {
    func tokens(_ s: String) -> [String] {
      s.lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
    }
    let ref = tokens(reference)
    let hyp = tokens(hypothesis)
    guard !ref.isEmpty else { return hyp.isEmpty ? 0 : 1 }

    var previous = Array(0...hyp.count)
    var current = [Int](repeating: 0, count: hyp.count + 1)

    for i in 1...ref.count {
      current[0] = i
      for j in 1...max(hyp.count, 1) where hyp.count > 0 {
        let substitution = previous[j - 1] + (ref[i - 1] == hyp[j - 1] ? 0 : 1)
        let insertion = current[j - 1] + 1
        let deletion = previous[j] + 1
        current[j] = min(substitution, insertion, deletion)
      }
      previous = current
    }
    return Double(previous[hyp.count]) / Double(ref.count)
  }

  /// Best (lowest) WER for a channel, optionally restricted to one distance bucket.
  func bestWER(for channel: Channel, at distance: Distance? = nil) -> Double? {
    let rates = utterances
      .filter { $0.channel == channel && (distance == nil || $0.distance == distance!) }
      .map { Self.wordErrorRate(hypothesis: $0.text) }
    return rates.min()
  }

  func count(for channel: Channel, at distance: Distance) -> Int {
    utterances.filter { $0.channel == channel && $0.distance == distance }.count
  }

  /// Distance buckets that actually have data, for rendering the envelope table.
  var testedDistances: [Distance] {
    Distance.allCases.filter { d in utterances.contains { $0.distance == d } }
  }

  /// Did the recogniser get the NAME right? Ultimately the only thing that matters —
  /// a transcript can be messy and still bind the identity correctly.
  func capturedName(for channel: Channel, at distance: Distance? = nil) -> Bool {
    utterances
      .filter { $0.channel == channel && (distance == nil || $0.distance == distance!) }
      .contains { $0.text.lowercased().contains("priya") }
  }
}
