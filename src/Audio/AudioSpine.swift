//
// AudioSpine.swift
//
// Owns AVAudioSession + AVAudioEngine for glasses microphone capture over Bluetooth HFP.
//
// Hard rules (see Omnivision docs/IMPLEMENTATION_PLAN.md):
//  - `.allowBluetooth` is what enables HFP (8 kHz mono). `.allowBluetoothA2DP` is output-only.
//  - HFP must be fully configured and ACTIVE before any DAT stream that needs audio starts.
//  - If the route is not HFP we are silently on the phone mic. That must be SURFACED, never
//    hidden — a silent fallback is a lie about coverage, and a blind user cannot see a UI badge.
//

import AVFoundation
import Foundation

@Observable
final class AudioSpine {

  enum RouteKind: String {
    case glassesHFP = "Glasses — Bluetooth HFP"
    case phoneMic = "Phone microphone"
    case otherRoute = "Other / unknown route"
    case inactive = "Not started"

    /// Only the HFP route proves we are actually capturing from the glasses.
    var isGlasses: Bool { self == .glassesHFP }
  }

  private(set) var route: RouteKind = .inactive
  private(set) var inputPortName = "—"
  private(set) var sampleRate: Double = 0
  private(set) var channelCount: UInt32 = 0
  private(set) var isRunning = false
  private(set) var lastError: String?

  /// Called for every captured PCM buffer. `SpeechStream` subscribes to this.
  var onBuffer: ((AVAudioPCMBuffer) -> Void)?

  private let engine = AVAudioEngine()
  private var tapInstalled = false

  init() {
    NotificationCenter.default.addObserver(
      forName: AVAudioSession.routeChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.refreshRoute()
    }
  }

  // MARK: - Lifecycle

  func start() {
    do {
      let session = AVAudioSession.sharedInstance()

      // `.allowBluetooth` enables the HFP input path. Without it we get A2DP, which is
      // output-only, and the microphone silently falls back to the phone.
      try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth])
      try session.setActive(true, options: .notifyOthersOnDeactivation)

      refreshRoute()

      let input = engine.inputNode
      let format = input.outputFormat(forBus: 0)
      sampleRate = format.sampleRate
      channelCount = format.channelCount

      guard format.sampleRate > 0 else {
        lastError = "Input format has zero sample rate — no usable input route."
        return
      }

      if !tapInstalled {
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
          self?.onBuffer?(buffer)
        }
        tapInstalled = true
      }

      engine.prepare()
      try engine.start()
      isRunning = true
      lastError = nil
    } catch {
      lastError = error.localizedDescription
      isRunning = false
    }
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

  /// The single most important diagnostic in this file. 8 kHz mono confirms HFP;
  /// 44.1/48 kHz means we are on the phone and the whole premise is untested.
  private func refreshRoute() {
    let inputs = AVAudioSession.sharedInstance().currentRoute.inputs

    guard let port = inputs.first else {
      route = .inactive
      inputPortName = "—"
      return
    }

    inputPortName = port.portName

    switch port.portType {
    case .bluetoothHFP:
      route = .glassesHFP
    case .builtInMic:
      route = .phoneMic
    default:
      route = .otherRoute
    }
  }

  // MARK: - Permissions

  static func requestMicrophonePermission() async -> Bool {
    await withCheckedContinuation { continuation in
      AVAudioApplication.requestRecordPermission { granted in
        continuation.resume(returning: granted)
      }
    }
  }
}
