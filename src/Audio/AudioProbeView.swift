//
// AudioProbeView.swift
//
// The G1 measurement rig.
//
// Answers two questions nothing else has tested:
//  1. Can we capture microphone audio from the glasses at all, or are we silently on the phone?
//  2. Is the WEARER channel dramatically cleaner than the OTHER channel?
//
// Question 2 is the kill switch for the whole echo-primary design. If the gap is small,
// wearer-echo name capture is not viable and we fall back to explicit binding only.
//

import SwiftUI

struct AudioProbeView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var spine = AudioSpine()
  @State private var speech = SpeechStream()
  @State private var micGranted = false

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          routeCard
          controls
          measurementCard
          transcriptCard
          if let error = spine.lastError ?? speech.lastError {
            Text(error)
              .font(.system(size: 13, design: .monospaced))
              .foregroundStyle(.red)
              .padding(12)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(Color.red.opacity(0.1))
              .clipShape(RoundedRectangle(cornerRadius: 12))
          }
        }
        .padding(20)
      }
      .navigationTitle("Audio Probe — G1")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") {
            spine.stop()
            speech.stop()
            dismiss()
          }
        }
      }
    }
    .task {
      micGranted = await AudioSpine.requestMicrophonePermission()
      await speech.requestAuthorization()
      spine.onBuffer = { [weak speech] buffer in
        speech?.append(buffer)
      }
    }
  }

  // MARK: - Route

  private var routeCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("AUDIO ROUTE")
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(.secondary)

      HStack(spacing: 10) {
        Circle()
          .fill(spine.route.isGlasses ? Color.green : Color.orange)
          .frame(width: 12, height: 12)
        Text(spine.route.rawValue)
          .font(.system(size: 17, weight: .semibold))
      }

      // 8 kHz mono is the signature of HFP. 44.1/48 kHz means we are on the phone
      // and every downstream assumption is untested.
      Text("\(Int(spine.sampleRate)) Hz · \(spine.channelCount) ch · port: \(spine.inputPortName)")
        .font(.system(size: 13, design: .monospaced))
        .foregroundStyle(.secondary)

      if spine.isRunning && !spine.route.isGlasses {
        Text("NOT on the glasses. Any result below measures the phone mic, not the beamformer.")
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(.orange)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
    .background(Color.gray.opacity(0.12))
    .clipShape(RoundedRectangle(cornerRadius: 16))
  }

  // MARK: - Controls

  private var controls: some View {
    VStack(spacing: 12) {
      Button {
        if spine.isRunning {
          spine.stop()
          speech.stop()
        } else {
          spine.start()
          speech.start()
        }
      } label: {
        Text(spine.isRunning ? "Stop capture" : "Start capture")
          .font(.system(size: 17, weight: .semibold))
          .frame(maxWidth: .infinity)
          .padding(.vertical, 14)
      }
      .buttonStyle(.borderedProminent)
      .tint(spine.isRunning ? .red : .blue)
      .disabled(!micGranted || !speech.isAuthorized)

      // Tag who is speaking. One mic cannot separate speakers, so the operator marks it.
      Picker("Speaker", selection: $speech.currentChannel) {
        ForEach(Channel.allCases, id: \.self) { channel in
          Text(channel.rawValue).tag(channel)
        }
      }
      .pickerStyle(.segmented)

      // A WER number without a distance is meaningless — intimate range flatters the
      // recogniser and says nothing about a real conversation.
      Picker("Distance", selection: $speech.currentDistance) {
        ForEach(Distance.allCases) { distance in
          Text(distance.label).tag(distance)
        }
      }
      .pickerStyle(.segmented)

      VStack(alignment: .leading, spacing: 4) {
        Text("READ THIS ALOUD — both speakers, same words")
          .font(.system(size: 11, weight: .bold))
          .foregroundStyle(.secondary)
        Text("\u{201C}\(SpeechStream.targetScript)\u{201D}")
          .font(.system(size: 15, weight: .medium, design: .serif))
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(12)
      .background(Color.blue.opacity(0.15))
      .clipShape(RoundedRectangle(cornerRadius: 12))

      if !micGranted || !speech.isAuthorized {
        Text("Microphone or speech permission denied — grant both in Settings.")
          .font(.system(size: 13))
          .foregroundStyle(.red)
      }
    }
  }

  // MARK: - G1 result

  private var measurementCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("G1 GATE — word error rate (lower is better)")
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(.secondary)

      // Envelope table: WER per channel per distance. This is the artefact Track C/D needs —
      // knowing where transcription degrades is what lets the app tell the user to step closer
      // instead of silently failing.
      Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
        GridRow {
          Text("").frame(width: 56, alignment: .leading)
          ForEach(Distance.allCases) { distance in
            Text(distance.label)
              .font(.system(size: 11, weight: .bold, design: .monospaced))
              .foregroundStyle(distance.isRealistic ? .primary : .secondary)
              .frame(maxWidth: .infinity)
          }
        }
        ForEach(Channel.allCases, id: \.self) { channel in
          GridRow {
            Text(channel == .wearer ? "WEAR" : "OTHER")
              .font(.system(size: 12, weight: .semibold, design: .monospaced))
              .frame(width: 56, alignment: .leading)
            ForEach(Distance.allCases) { distance in
              let wer = speech.bestWER(for: channel, at: distance)
              VStack(spacing: 1) {
                Text(percent(wer))
                  .font(.system(size: 14, weight: .bold, design: .monospaced))
                  .foregroundStyle(werColor(wer))
                if speech.count(for: channel, at: distance) > 0 {
                  Image(
                    systemName: speech.capturedName(for: channel, at: distance)
                      ? "checkmark.seal.fill" : "xmark.seal"
                  )
                  .font(.system(size: 9))
                  .foregroundStyle(
                    speech.capturedName(for: channel, at: distance) ? .green : .red)
                }
              }
              .frame(maxWidth: .infinity)
            }
          }
        }
      }

      Text("✓ = the name \u{201C}Priya\u{201D} survived. Bold columns are real conversation range.")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)

      Divider()

      // Only the realistic buckets decide the design. 0.3m results are not evidence.
      if let wearer = realisticWER(.wearer), let other = realisticWER(.other) {
        Text(verdict(wearerWER: wearer, otherWER: other))
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(.primary)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        Text("Need readings at 0.6m or 1.0m from BOTH speakers. Anything at 0.3m is intimate range and does not represent a conversation.")
          .font(.system(size: 13))
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }

      Text("recognizer rotations: \(speech.rotations)")
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
    .background(Color.gray.opacity(0.12))
    .clipShape(RoundedRectangle(cornerRadius: 16))
  }

  /// WORST WER across the realistic buckets, not the best.
  ///
  /// A channel that works at 1.0m but fails at 0.6m is not dependable — people do not stand on a
  /// mark. Taking the best score hid exactly that: OTHER read 9% at 1.0m and 36% at 0.6m, and
  /// reporting 9% made a fragile channel look solid.
  private func realisticWER(_ channel: Channel) -> Double? {
    let rates = Distance.allCases
      .filter(\.isRealistic)
      .compactMap { speech.bestWER(for: channel, at: $0) }
    return rates.isEmpty ? nil : rates.max()
  }

  /// Four possible worlds, and they imply different designs.
  private func verdict(wearerWER: Double, otherWER: Double) -> String {
    let bothUsable = wearerWER < 0.4 && otherWER < 0.4
    if bothUsable {
      return "BOTH CHANNELS USABLE — beamforming is not blocking the other speaker. Prefer direct self-introduction capture (E2/E3); wearer echo becomes a redundant backup rather than the primary path."
    }
    if wearerWER < otherWER - 0.15 {
      return "WEARER CLEARLY BETTER — echo-primary design holds as planned. Bind names from what you say, not what they say."
    }
    if otherWER < wearerWER - 0.15 {
      return "OTHER SPEAKER BETTER — unexpected. Capture self-introductions directly and treat wearer echo as backup."
    }
    return "NEITHER CHANNEL RELIABLE — fall back to explicit binding (\u{201C}Lumen, this is Priya\u{201D}) as the primary path. It always works and costs one sentence."
  }

  private func percent(_ value: Double?) -> String {
    guard let value else { return "—" }
    return String(format: "%.0f%%", value * 100)
  }

  private func werColor(_ value: Double?) -> Color {
    guard let value else { return .secondary }
    if value < 0.2 { return .green }
    if value < 0.4 { return .orange }
    return .red
  }

  // MARK: - Transcript

  private var transcriptCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("TRANSCRIPT")
          .font(.system(size: 12, weight: .bold))
          .foregroundStyle(.secondary)
        Spacer()
        Button("Clear") { speech.reset() }
          .font(.system(size: 13))
      }

      if !speech.partialText.isEmpty {
        Text(speech.partialText)
          .font(.system(size: 15, design: .monospaced))
          .foregroundStyle(.blue)
      }

      ForEach(speech.utterances.reversed()) { utterance in
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(utterance.channel.rawValue)
              .font(.system(size: 10, weight: .bold, design: .monospaced))
              .foregroundStyle(utterance.channel == .wearer ? .green : .orange)
            Text(utterance.confidence >= 0 ? String(format: "%.2f", utterance.confidence) : "n/a")
              .font(.system(size: 10, design: .monospaced))
              .foregroundStyle(.secondary)
          }
          Text(utterance.text)
            .font(.system(size: 14))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      if speech.utterances.isEmpty && speech.partialText.isEmpty {
        Text("Nothing captured yet.")
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
    .background(Color.gray.opacity(0.12))
    .clipShape(RoundedRectangle(cornerRadius: 16))
  }
}
