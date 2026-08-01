//
// ABPipelineView.swift
// Track B ↔ Track A/C integration harness.
//
// A/B on one live utterance. Both arms see byte-identical input — the same `Utterance` object —
// so any difference is the pipeline, never the audio. That is the whole point: comparing two
// separate recordings would confound the thing being measured.
//
//   ARM A (control)  transcript only. What Track B alone produced before integration.
//   ARM B (variant)  transcript → LumenCommandParser → NameExtractor → EvidenceAssessor
//                    → IdentityResolver → IdentityState
//
// Arm B is the first time Track B's output has ever reached Track A/C's code. Read it as: did the
// name survive, at which evidence rung, and did the system assert or hedge?
//

#if os(iOS)

import SwiftUI
import AccessLensTrackC

/// One utterance evaluated by both arms.
struct ABTrial: Identifiable {
  let id = UUID()
  let utterance: Utterance

  // Arm A
  var transcript: String { utterance.text }

  // Arm B
  let command: Command?
  let candidates: [NameCandidate]
  let assessment: EvidenceAssessment
  let state: IdentityState
}

@Observable
final class ABPipeline {
  private(set) var trials: [ABTrial] = []

  private let commandParser = LumenCommandParser()
  private let extractor = NameExtractor(validator: CorroboratedNameValidator.platformDefault())
  private var known: [Person] = []

  /// Run one utterance through arm B. Arm A is the utterance itself.
  func evaluate(_ utterance: Utterance) {
    let command = commandParser.parse(utterance)
    let candidates = extractor.candidates(in: utterance)
    let assessment = EvidenceAssessor.assess(candidates)
    let resolver = IdentityResolver(people: known)
    let state = resolver.resolve(names: candidates, cluster: nil)

    // Persist an asserted identity so a second encounter can be recognised in-session.
    if case .known(let person) = state,
       !known.contains(where: { $0.name.caseInsensitiveCompare(person.name) == .orderedSame }) {
      known.append(person)
    }

    trials.append(
      ABTrial(
        utterance: utterance,
        command: command,
        candidates: candidates,
        assessment: assessment,
        state: state
      )
    )
  }

  func reset() {
    trials.removeAll()
    known.removeAll()
  }
}

struct ABPipelineView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var spine = AudioSpine()
  @State private var speech = SpeechStream()
  @State private var pipeline = ABPipeline()
  /// Two independent tasks. Holding them in one handle would cancel the PCM pump the moment the
  /// utterance consumer replaced it, and capture would look alive while feeding nothing.
  @State private var pcmTask: Task<Void, Never>?
  @State private var utteranceTask: Task<Void, Never>?

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          routeBanner
          controls
          ForEach(pipeline.trials.reversed()) { trial in
            trialCard(trial)
          }
          if pipeline.trials.isEmpty {
            Text("Say \u{201C}Nice to meet you Priya\u{201D}, or \u{201C}Lumen, remember this\u{201D}.")
              .font(.system(size: 13))
              .foregroundStyle(.secondary)
          }
        }
        .padding(16)
      }
      .navigationTitle("A/B — Track B → A/C")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") { teardown(); dismiss() }
        }
      }
    }
    .task {
      _ = await AudioSpine.requestMicrophonePermission()
      await speech.requestAuthorization()
    }
  }

  private var routeBanner: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(spine.route.isGlasses ? Color.green : Color.orange)
        .frame(width: 10, height: 10)
      Text(spine.route.rawValue)
        .font(.system(size: 13, weight: .semibold))
      Spacer()
      Text("\(Int(spine.sampleRate)) Hz")
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(.secondary)
    }
    .padding(12)
    .frame(maxWidth: .infinity)
    .background(Color.gray.opacity(0.12))
    .clipShape(RoundedRectangle(cornerRadius: 12))
  }

  private var controls: some View {
    HStack(spacing: 12) {
      Button(spine.isRunning ? "Stop" : "Start capture") {
        spine.isRunning ? teardown() : startUp()
      }
      .buttonStyle(.borderedProminent)
      .tint(spine.isRunning ? .red : .blue)

      Picker("Speaker", selection: $speech.currentChannel) {
        Text("WEARER").tag(Channel.wearer)
        Text("OTHER").tag(Channel.other)
      }
      .pickerStyle(.segmented)

      Button("Clear") { pipeline.reset(); speech.reset() }
        .font(.system(size: 13))
    }
  }

  private func trialCard(_ trial: ABTrial) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      // ARM A
      VStack(alignment: .leading, spacing: 3) {
        Text("A · TRANSCRIPT ONLY")
          .font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
        Text(trial.transcript).font(.system(size: 14))
      }

      Divider()

      // ARM B
      VStack(alignment: .leading, spacing: 3) {
        Text("B · THROUGH TRACK A/C")
          .font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)

        if let command = trial.command {
          Text("command: \(String(describing: command))")
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.purple)
        }

        if trial.candidates.isEmpty {
          Text("no name candidates")
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.secondary)
        } else {
          ForEach(Array(trial.candidates.enumerated()), id: \.offset) { _, candidate in
            Text("\(candidate.name)  ·  \(candidate.template)  ·  \(String(format: "%.2f", candidate.confidence))")
              .font(.system(size: 12, design: .monospaced))
          }
        }

        Text(trial.assessment.rationale)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        Text(verdict(trial.state))
          .font(.system(size: 14, weight: .bold))
          .foregroundStyle(color(for: trial.state))
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .background(Color.gray.opacity(0.10))
    .clipShape(RoundedRectangle(cornerRadius: 14))
  }

  private func verdict(_ state: IdentityState) -> String {
    switch state {
    case .known(let p):          return "ASSERT — \(p.name)"
    case .likely(let p):         return "HEDGE — might be \(p.name)"
    case .ambiguous(let names):  return "ASK — \(names.joined(separator: " or "))"
    case .unnamedCluster:        return "UNNAMED CLUSTER"
    case .nothing:               return "NOTHING"
    }
  }

  private func color(for state: IdentityState) -> Color {
    switch state {
    case .known:     return .green
    case .likely:    return .orange
    case .ambiguous: return .yellow
    default:         return .secondary
    }
  }

  // MARK: - Wiring

  private func startUp() {
    Task {
      do {
        try await spine.start()
        speech.start()
        // Both arms are fed from this one stream, so any A/B difference is the pipeline.
        pcmTask = Task { await speech.consume(spine.pcmStream) }
        utteranceTask = Task {
          for await utterance in speech.utterances {
            await MainActor.run { pipeline.evaluate(utterance) }
          }
        }
      } catch {
        // surfaced via spine.lastError
      }
    }
  }

  private func teardown() {
    pcmTask?.cancel(); pcmTask = nil
    utteranceTask?.cancel(); utteranceTask = nil
    speech.stop()
    spine.stop()
  }
}

#endif
