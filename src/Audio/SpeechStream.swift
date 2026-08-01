//
// SpeechStream.swift
// Track B — on-device speech recognition over the AudioSpine PCM tap.
//
// iOS ONLY (see AudioSpine.swift for why this is not in the package).
//
// Conforms to `SpeechStreaming` from AccessLensTrackC. `Channel` and `Utterance` now come from
// that package — Track B previously declared its own copies, which would have shadowed the
// canonical ones and failed at the boundary where an Utterance is handed to NameExtractor.
//
// Two non-obvious requirements:
//  1. `requiresOnDeviceRecognition = true` — audio must never leave the phone.
//  2. SFSpeechRecognizer will not run indefinitely. Tasks rotate on a detected silence gap so no
//     words are lost mid-sentence.
//

#if os(iOS)

import AVFoundation
import Foundation
import Speech
import AccessLensTrackC

/// Speaker distance bucket. Probe/measurement only — deliberately NOT part of `Utterance`, which
/// is Track A's frozen contract. A distance tag is a property of a test, not of an utterance.
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

  /// The range people actually stand at when meeting someone.
  var isRealistic: Bool { self == .close || self == .conversational }
}

/// UI-facing record: the canonical `Utterance` plus test metadata the contract has no business
/// carrying.
struct ProbeRecord: Identifiable {
  let id = UUID()
  let utterance: Utterance
  let distance: Distance

  var text: String { utterance.text }
  var channel: Channel { utterance.channel }
  var confidence: Float { utterance.confidence }
}

@Observable
final class SpeechStream: SpeechStreaming {

  // MARK: - Observable UI state (not part of the contract)

  private(set) var partialText = ""
  private(set) var records: [ProbeRecord] = []
  private(set) var isAuthorized = false
  private(set) var lastError: String?
  private(set) var rotations = 0

  /// Operator-controlled tags applied to the next finalized utterance.
  var currentChannel: Channel = .wearer
  var currentDistance: Distance = .conversational

  // MARK: - SpeechStreaming

  /// Finalized utterances, for Track C's `NameExtractor` and `LumenCommandParser`.
  @ObservationIgnored let utterances: AsyncStream<Utterance>
  @ObservationIgnored private let utteranceContinuation: AsyncStream<Utterance>.Continuation

  private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var lastVoiceActivity = Date()
  /// Long-session guard: SFSpeechRecognizer degrades if a task runs indefinitely.
  private let rotateAfter: TimeInterval = 45
  private let silenceGap: TimeInterval = 0.6
  /// Silence after which a pending transcript is emitted immediately.
  ///
  /// On-device recognition often never fires `isFinal`, so waiting for it meant an utterance sat
  /// unemitted until the 45 s rotation — a timer that exists to keep the recogniser healthy, not
  /// to pace output. Speech is finalised on a natural pause instead, which is what a listener
  /// does anyway.
  private let finalizeAfterSilence: TimeInterval = 0.8
  private var taskStartedAt = Date()
  /// Guards against re-emitting the same pending text on every buffer during a long silence.
  private var flushedSinceLastSpeech = true

  init() {
    var continuation: AsyncStream<Utterance>.Continuation!
    utterances = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation = $0 }
    utteranceContinuation = continuation
  }

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
    records.removeAll()
    partialText = ""
    rotations = 0
  }

  /// Drain `AudioSpine.pcmStream` into the recognizer.
  func consume(_ pcm: AsyncStream<AVAudioPCMBuffer>) async {
    for await buffer in pcm {
      append(buffer)
    }
  }

  // MARK: - Audio intake

  func append(_ buffer: AVAudioPCMBuffer) {
    request?.append(buffer)

    if isVoiceActive(buffer) {
      lastVoiceActivity = Date()
      flushedSinceLastSpeech = false
      return
    }

    let silence = Date().timeIntervalSince(lastVoiceActivity)

    // Emit on a natural pause. This is the path that actually delivers utterances; `isFinal` is
    // treated as a bonus rather than the trigger.
    if !flushedSinceLastSpeech, silence > finalizeAfterSilence, !partialText.isEmpty {
      flushedSinceLastSpeech = true
      rotateTask()
      return
    }

    // Independent of the above: keep the recogniser from running too long, but only cut over
    // during silence so a sentence is never split.
    if silence > silenceGap, Date().timeIntervalSince(taskStartedAt) > rotateAfter {
      rotateTask()
    }
  }

  /// Cheap RMS gate. Not a real VAD — enough to find a pause to rotate in.
  private func isVoiceActive(_ buffer: AVAudioPCMBuffer) -> Bool {
    guard let channelData = buffer.floatChannelData?[0] else { return false }
    let count = Int(buffer.frameLength)
    guard count > 0 else { return false }

    var sum: Float = 0
    for i in 0..<count { sum += channelData[i] * channelData[i] }
    return (sum / Float(count)).squareRoot() > 0.01
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

      // 301 = cancelled during rotation; 1110 = "no speech" at task end. Both expected.
      if let error {
        let code = (error as NSError).code
        if code != 301 && code != 1110 { self.lastError = error.localizedDescription }
      }

      guard let result else { return }
      self.partialText = result.bestTranscription.formattedString
      if result.isFinal { self.commit(result.bestTranscription) }
    }
  }

  private func endTask() {
    request?.endAudio()
    task?.cancel()
    request = nil
    task = nil
  }

  func rotateTask() {
    // Commit whatever partial text exists before tearing down, so rotation never discards speech.
    if !partialText.isEmpty {
      emit(text: partialText, confidence: 0)
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
    // On-device recognition leaves this at 0. Track C reads 0 as "unknown", not "wrong", and
    // substitutes a channel-aware neutral value calibrated from G1.
    let avgConfidence = segments.isEmpty
      ? 0
      : segments.map(\.confidence).reduce(0, +) / Float(segments.count)

    emit(text: text, confidence: avgConfidence)
    partialText = ""
  }

  /// Single place an `Utterance` is created, so the contract type and the UI record never drift.
  private func emit(text: String, confidence: Float) {
    let utterance = Utterance(
      text: text,
      channel: currentChannel,
      confidence: confidence,
      at: Date()
    )
    records.append(ProbeRecord(utterance: utterance, distance: currentDistance))
    utteranceContinuation.yield(utterance)
  }

  // MARK: - G1 measurement

  static let targetScript = "Nice to meet you Priya I work on latency at Stripe"

  /// Word error rate: Levenshtein edit distance over word tokens, normalised by reference length.
  static func wordErrorRate(hypothesis: String, reference: String = targetScript) -> Double {
    func tokens(_ s: String) -> [String] {
      s.lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
    }
    let ref = tokens(reference)
    let hyp = tokens(hypothesis)
    guard !ref.isEmpty else { return hyp.isEmpty ? 0 : 1 }
    guard !hyp.isEmpty else { return 1 }

    var previous = Array(0...hyp.count)
    var current = [Int](repeating: 0, count: hyp.count + 1)

    for i in 1...ref.count {
      current[0] = i
      for j in 1...hyp.count {
        let substitution = previous[j - 1] + (ref[i - 1] == hyp[j - 1] ? 0 : 1)
        current[j] = min(substitution, current[j - 1] + 1, previous[j] + 1)
      }
      previous = current
    }
    return Double(previous[hyp.count]) / Double(ref.count)
  }

  func bestWER(for channel: Channel, at distance: Distance? = nil) -> Double? {
    records
      .filter { $0.channel == channel && (distance == nil || $0.distance == distance!) }
      .map { Self.wordErrorRate(hypothesis: $0.text) }
      .min()
  }

  func count(for channel: Channel, at distance: Distance) -> Int {
    records.filter { $0.channel == channel && $0.distance == distance }.count
  }

  func capturedName(for channel: Channel, at distance: Distance? = nil) -> Bool {
    records
      .filter { $0.channel == channel && (distance == nil || $0.distance == distance!) }
      .contains { $0.text.lowercased().contains("priya") }
  }
}

#endif
