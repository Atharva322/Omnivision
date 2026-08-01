//
// AudioSpine.swift
// Track B — glasses microphone capture over Bluetooth HFP.
//
// iOS ONLY. `AVAudioSession` does not exist on macOS or Linux, which is why this file lives in the
// app target and not in the AccessLensTrackC package (that package must stay Linux-buildable).
//
// Conforms to `AudioSpining` from AccessLensTrackC/Core/Protocols.swift. Track A owns that
// contract; Track B adopts it.
//
// Hard rules:
//  - `.allowBluetooth` is what enables HFP. `.allowBluetoothA2DP` is output-only.
//  - HFP must be fully configured and ACTIVE before any DAT stream that needs audio starts.
//  - If the route is not HFP we are on the phone mic. That must be SURFACED, never hidden —
//    a blind wearer cannot see a UI badge, and G1's 16 kHz finding came from checking this.
//

#if os(iOS)

import AVFoundation
import Foundation
import AccessLensTrackC

@Observable
final class AudioSpine: AudioSpining {

  enum RouteKind: String {
    case glassesHFP = "Glasses — Bluetooth HFP"
    case phoneMic = "Phone microphone"
    case otherRoute = "Other / unknown route"
    case inactive = "Not started"

    var isGlasses: Bool { self == .glassesHFP }
  }

  enum AudioSpineError: LocalizedError {
    case noUsableInput
    var errorDescription: String? {
      "Input format has zero sample rate — no usable input route."
    }
  }

  // MARK: - Observable diagnostics (UI only; not part of the contract)

  private(set) var route: RouteKind = .inactive
  private(set) var inputPortName = "—"
  private(set) var sampleRate: Double = 0
  private(set) var channelCount: UInt32 = 0
  private(set) var isRunning = false
  private(set) var lastError: String?

  /// Not in `AudioSpining` — it should be. Without it a silent fallback to the phone microphone
  /// looks identical to success. Proposed for the protocol; see docs/INTEGRATION.md.
  var isGlassesRoute: Bool { route.isGlasses }

  // MARK: - AudioSpining

  /// Every captured PCM buffer. Replaces the previous `onBuffer` closure so this type satisfies
  /// `AudioSpining`, and so multiple consumers (SpeechStream, a level meter, a recorder) can
  /// attach without fighting over one closure slot.
  /// `@ObservationIgnored` because @Observable rewrites stored properties into computed ones,
  /// which forbids `lazy` and makes no sense for a stream anyway — nothing observes its identity.
  @ObservationIgnored let pcmStream: AsyncStream<AVAudioPCMBuffer>
  @ObservationIgnored private let bufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation

  private let engine = AVAudioEngine()
  private var tapInstalled = false

  init() {
    // Bounded on purpose: audio arrives faster than a lagging consumer drains it, and an
    // unbounded stream would grow without limit. Dropping the oldest buffers is the right
    // failure — stale audio is worthless for live recognition.
    var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation!
    pcmStream = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation = $0 }
    bufferContinuation = continuation

    NotificationCenter.default.addObserver(
      forName: AVAudioSession.routeChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.refreshRoute()
    }
  }

  func start() async throws {
    let session = AVAudioSession.sharedInstance()

    // `.allowBluetooth` enables the HFP input path. Without it we get A2DP, which is output-only,
    // and the microphone silently falls back to the phone.
    try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth])
    try session.setActive(true, options: .notifyOthersOnDeactivation)

    refreshRoute()

    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    sampleRate = format.sampleRate
    channelCount = format.channelCount

    guard format.sampleRate > 0 else {
      lastError = AudioSpineError.noUsableInput.localizedDescription
      throw AudioSpineError.noUsableInput
    }

    if !tapInstalled {
      input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
        self?.bufferContinuation.yield(buffer)
      }
      tapInstalled = true
    }

    engine.prepare()
    try engine.start()
    isRunning = true
    lastError = nil
  }

  func stop() {
    if tapInstalled {
      engine.inputNode.removeTap(onBus: 0)
      tapInstalled = false
    }
    engine.stop()
    isRunning = false
    route = .inactive
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  // MARK: - Route inspection

  /// The single most important diagnostic here. 16 kHz mono confirms wideband HFP from the
  /// glasses; 44.1/48 kHz means we are on the phone and every downstream assumption is untested.
  private func refreshRoute() {
    let inputs = AVAudioSession.sharedInstance().currentRoute.inputs

    guard let port = inputs.first else {
      route = .inactive
      inputPortName = "—"
      return
    }

    inputPortName = port.portName

    switch port.portType {
    case .bluetoothHFP: route = .glassesHFP
    case .builtInMic:   route = .phoneMic
    default:            route = .otherRoute
    }
  }

  // MARK: - Permissions

  static func requestMicrophonePermission() async -> Bool {
    await withCheckedContinuation { continuation in
      AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
    }
  }
}

#endif
