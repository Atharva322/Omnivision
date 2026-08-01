//
// OmnivisionView.swift
// The end-to-end demo screen. Everything the product does, in one place, speaking aloud.
//
// iOS ONLY.
//
//   glasses mic  -> AudioSpine -> SpeechStream -> LumenCommandParser  -> commands
//                                              -> NameExtractor       -> IdentityResolver
//   glasses cam  -> FrameBridge -> BarcodeScanner -> ProductCatalog   -> ShopNarration
//                                              all -> AnnouncementGate -> Narrator (Track D)
//
// Every decision above happens in a pure, tested type. This file only wires them together and
// mirrors what happened on screen — because judges cannot hear what is in the wearer's ear, and a
// blind wearer cannot see this screen. Both audiences are served by the same run.
//

#if os(iOS)

import CoreGraphics
import SwiftUI
import AccessLensTrackC

@Observable
@MainActor
final class OmnivisionSession {

    struct Event: Identifiable {
        let id = UUID()
        let at: Date
        let kind: String
        let detail: String
        let spoken: String?
    }

    private(set) var events: [Event] = []
    private(set) var isRunning = false
    private(set) var route = "not started"
    private(set) var sampleRate = 0
    private(set) var lastError: String?

    /// Wearer-controlled, drives the gate. Set by "Lumen, pause".
    private(set) var silenceRequested = false
    private(set) var lastOtherSpeechAt: Date?

    let narrator = Narrator()

    private let spine = AudioSpine()
    private let speech = SpeechStream()
    private let commands = LumenCommandParser()
    private let extractor = NameExtractor(validator: CorroboratedNameValidator.platformDefault())
    private var store: [Person] = []
    private var gate = AnnouncementGate()
    private var shop: ShopScanner?

    private var audioTask: Task<Void, Never>?
    private var utteranceTask: Task<Void, Never>?

    var context: ProactiveContext {
        ProactiveContext(
            lastOtherSpeechAt: lastOtherSpeechAt,
            silenceRequested: silenceRequested,
            now: Date())
    }

    // MARK: - Lifecycle

    func start() async {
        guard !isRunning else { return }
        _ = await AudioSpine.requestMicrophonePermission()
        await speech.requestAuthorization()

        do {
            try await spine.start()
        } catch {
            lastError = error.localizedDescription
            return
        }

        route = spine.route.rawValue
        sampleRate = Int(spine.sampleRate)
        // Surface a phone-mic fallback rather than letting it look like success.
        if !spine.isGlassesRoute {
            narrator.say("Using phone microphone, not the glasses.", priority: .critical)
        }

        speech.start()
        shop = ShopScanner(narrator: narrator)
        isRunning = true

        audioTask = Task { await speech.consume(spine.pcmStream) }
        utteranceTask = Task { [weak self] in
            guard let self else { return }
            for await utterance in await self.speech.utterances {
                await self.handle(utterance)
            }
        }
        narrator.play(.captureOn)
    }

    func stop() {
        audioTask?.cancel(); utteranceTask?.cancel()
        audioTask = nil; utteranceTask = nil
        speech.stop(); spine.stop()
        isRunning = false
        route = "stopped"
    }

    // MARK: - Speech

    private func handle(_ utterance: Utterance) async {
        // Anything on the other channel means someone else is talking; the gate holds
        // non-critical speech until they stop.
        if utterance.channel == .other { lastOtherSpeechAt = utterance.at }

        if let command = commands.parse(utterance) {
            await run(command, from: utterance)
            return
        }

        let candidates = extractor.candidates(in: utterance)
        guard !candidates.isEmpty else {
            log("heard", utterance.text, spoken: nil)
            return
        }

        let state = IdentityResolver(people: store).resolve(names: candidates, cluster: nil)
        await announce(state, heard: utterance.text)
    }

    private func run(_ command: Command, from utterance: Utterance) async {
        switch command {
        case .pause:
            silenceRequested = true
            narrator.play(.captureOff)
            log("command", "pause — silence requested", spoken: "(earcon)")

        case .rememberThis:
            silenceRequested = false
            narrator.play(.captureOn)
            log("command", "remember this", spoken: "(earcon)")

        case .bind(let name):
            let candidate = NameCandidate(
                name: name, channel: .wearer, template: "e0.explicit_bind", confidence: 1.0)
            let state = IdentityResolver(people: store).resolve(names: [candidate], cluster: nil)
            await announce(state, heard: utterance.text)

        case .whoIsThis:
            // Explicit request: always answer, even to say we do not know.
            if let last = store.last {
                say(Narrator.line(for: last), priority: .discreet, kind: "who is this")
            } else {
                say("I don't know who this is.", priority: .discreet, kind: "who is this")
            }

        case .forgetThem:
            let removed = store.popLast()?.name ?? "nobody"
            say("Forgotten \(removed).", priority: .normal, kind: "forget")

        default:
            log("command", String(describing: command), spoken: nil)
        }
    }

    private func announce(_ state: IdentityState, heard: String) async {
        switch state {
        case .known(let person):
            remember(person)
            say(Narrator.line(for: person), priority: .normal, kind: "ASSERT", heard: heard)

        case .likely(let person):
            // Never phrased as a fact — this is the hedge the accuracy claim depends on.
            say("This might be \(person.name).", priority: .normal, kind: "HEDGE", heard: heard)

        case .ambiguous(let names):
            say("Did you meet \(names.joined(separator: " or "))?",
                priority: .normal, kind: "ASK", heard: heard)

        case .unnamedCluster, .nothing:
            log("no identity", heard, spoken: nil)
        }
    }

    private func remember(_ person: Person) {
        if let index = store.firstIndex(where: {
            $0.name.caseInsensitiveCompare(person.name) == .orderedSame
        }) {
            var updated = store[index]
            updated.encounterCount += 1
            updated.lastEncounterAt = Date()
            updated.tier = Person.autoTier(for: updated.encounterCount)
            store[index] = updated
        } else {
            store.append(person)
        }
    }

    // MARK: - Shop

    func scanForProduct(_ frame: CapturedFrame) async {
        await shop?.scanOnRequest(frame, context: context)
        if let recognition = shop?.lastRecognition {
            log("barcode", String(describing: recognition), spoken: "(via ShopScanner)")
        }
    }

    // MARK: - Output

    private func say(_ text: String, priority: Priority, kind: String, heard: String? = nil) {
        let announcement = Announcement(
            text: text, source: .person, priority: .normal,
            dedupeKey: "say:\(text)", at: Date())

        // Critical and explicit-request speech bypasses the gate; everything else is subject to
        // conversation suppression and repeat cooldown.
        if priority == .discreet || priority == .critical {
            narrator.say(text, priority: priority)
            log(kind, heard ?? text, spoken: text)
            return
        }

        switch gate.decide(announcement, context: context) {
        case .speak(let approved):
            narrator.say(approved.text, priority: priority)
            log(kind, heard ?? text, spoken: approved.text)
        case .suppress(_, let reason):
            log("\(kind) (held)", heard ?? text, spoken: "suppressed: \(reason.rawValue)")
        }
    }

    private func log(_ kind: String, _ detail: String, spoken: String?) {
        events.append(Event(at: Date(), kind: kind, detail: detail, spoken: spoken))
        if events.count > 80 { events.removeFirst(events.count - 80) }
    }
}

struct OmnivisionView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var session = OmnivisionSession()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusBar
                Divider()
                transcript
            }
            .navigationTitle("Omnivision")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { session.stop(); dismiss() }
                }
            }
        }
    }

    private var statusBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(session.route.contains("Glasses") ? .green : .orange)
                    .frame(width: 10, height: 10)
                Text(session.route).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(session.sampleRate) Hz")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Button(session.isRunning ? "Stop" : "Start") {
                Task { session.isRunning ? session.stop() : await session.start() }
            }
            .buttonStyle(.borderedProminent)
            .tint(session.isRunning ? .red : .blue)
            .frame(maxWidth: .infinity)

            if let error = session.lastError {
                Text(error).font(.system(size: 12)).foregroundStyle(.red)
            }

            Text("Say: \u{201C}Nice to meet you Priya\u{201D} · \u{201C}Lumen, this is Priya\u{201D} · \u{201C}Lumen, who is this\u{201D} · \u{201C}Lumen, pause\u{201D}")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
    }

    private var transcript: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(session.events.reversed()) { event in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.kind.uppercased())
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(colour(for: event.kind))
                        Text(event.detail).font(.system(size: 14))
                        if let spoken = event.spoken {
                            Text("\u{1F50A} \(spoken)")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.blue)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.gray.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                if session.events.isEmpty {
                    Text("Press Start, then speak.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            .padding(14)
        }
    }

    private func colour(for kind: String) -> Color {
        if kind.hasPrefix("ASSERT") { return .green }
        if kind.hasPrefix("HEDGE") || kind.hasPrefix("ASK") { return .orange }
        if kind.contains("held") { return .purple }
        if kind == "command" { return .blue }
        return .secondary
    }
}

#endif
