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

      Text("Tag who is speaking BEFORE they talk. Say the same sentence from each side.")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)

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
      Text("G1 GATE — mean recognition confidence")
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(.secondary)

      ForEach(Channel.allCases, id: \.self) { channel in
        HStack {
          Text(channel.rawValue)
            .font(.system(size: 15, weight: .semibold, design: .monospaced))
          Spacer()
          Text("n=\(speech.count(for: channel))")
            .font(.system(size: 13, design: .monospaced))
            .foregroundStyle(.secondary)
          Text(formatted(speech.meanConfidence(for: channel)))
            .font(.system(size: 17, weight: .bold, design: .monospaced))
            .foregroundStyle(color(for: speech.meanConfidence(for: channel)))
        }
      }

      Divider()

      if let wearer = speech.meanConfidence(for: .wearer),
         let other = speech.meanConfidence(for: .other) {
        let gap = wearer - other
        Text(verdict(gap: gap))
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(gap > 0.15 ? .green : .orange)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        Text("Record utterances tagged as both WEARER and OTHER to get a verdict.")
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
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

  private func verdict(gap: Float) -> String {
    if gap > 0.15 {
      return "PASS — wearer channel is clearly cleaner (gap \(String(format: "%.2f", gap))). Echo-primary design holds."
    }
    return "FAIL — gap is only \(String(format: "%.2f", gap)). Beamforming is not buying us enough. Fall back to explicit binding (\"Lumen, this is Priya\") as the primary path."
  }

  private func formatted(_ value: Float?) -> String {
    guard let value else { return "—" }
    return String(format: "%.2f", value)
  }

  private func color(for value: Float?) -> Color {
    guard let value else { return .secondary }
    if value > 0.7 { return .green }
    if value > 0.4 { return .orange }
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
