//
// OmnivisionView.swift
// The end-to-end demo screen. Everything the product does, in one place, speaking aloud.
//
// iOS ONLY.
//
//   glasses mic  -> AudioSpine -> SpeechStream -> LumenCommandParser  -> commands
//                                              -> NameExtractor       ->\
//   glasses cam  -> FrameBridge -> FaceCluster -> FacePresence        -> IdentityResolver
//                              -> BarcodeScanner -> ProductCatalog    -> ShopNarration
//                                              all -> AnnouncementGate -> Narrator (Track D)
//
// A person is identified by name AND face. The name is what may be ASSERTED; the face is what
// makes the name stick to a human being across sessions. They are not interchangeable: a spoken
// name binds identity, and the face seen at that moment is attached to it, so a later encounter
// with no name spoken can still HEDGE ("This might be Priya"). A face alone never asserts.
//
// Every decision above happens in a pure, tested type. This file only wires them together and
// mirrors what happened on screen — because judges cannot hear what is in the wearer's ear, and a
// blind wearer cannot see this screen. Both audiences are served by the same run.
//

#if os(iOS)

import CoreGraphics
import SwiftUI
import UIKit
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

    init() {
        let url = URL.applicationSupportDirectory.appending(path: "omnivision-people.json")
        // A failed store must not take the whole session down — degrade to a temporary one so the
        // wearer still gets recognition for this session rather than a dead app.
        store = (try? PersonStore(url: url))
            ?? (try! PersonStore(url: URL.temporaryDirectory.appending(path: "people.json")))
    }

    private let spine = AudioSpine()
    private let speech = SpeechStream()
    private let commands = LumenCommandParser()
    private let extractor = NameExtractor(validator: CorroboratedNameValidator.platformDefault())
    /// The real store: persisted, encounter-counted, tier-aware.
    ///
    /// This was an in-memory `[Person]` array, which is why nothing was ever "someone I already
    /// know" — encounters could not accumulate across launches, so every meeting was a first
    /// meeting and every person stayed at `.newPerson` forever.
    private let store: PersonStore
    private var gate = AnnouncementGate()
    private var shop: ShopScanner?

    /// Face recognition. Optional on purpose: the Core ML model requires iOS 17 and is a restricted
    /// artifact that may be absent from a given build, and neither is a reason to lose the spoken
    /// name path — which is the only path allowed to assert anyway.
    private var faces: FaceCluster?
    private var presence = FacePresence()
    private(set) var faceStatus = "off"
    private(set) var facesSeen = 0

    /// One Core ML inference per interval. At the camera's frame rate the phone would cook for no
    /// benefit — a face does not change between adjacent frames, and this is frequent enough to
    /// keep `FacePresence` refreshed far inside its window.
    private static let faceInterval: TimeInterval = 1.0

    private var audioTask: Task<Void, Never>?
    private var utteranceTask: Task<Void, Never>?
    private var faceTask: Task<Void, Never>?
    private var cancelFrames: (() -> Void)?

    var context: ProactiveContext {
        ProactiveContext(
            lastOtherSpeechAt: lastOtherSpeechAt,
            silenceRequested: silenceRequested,
            now: Date())
    }

    // MARK: - Lifecycle

    /// - Parameters:
    ///   - startCamera: brings the DAT camera stream up. Injected rather than referenced directly
    ///     so this file never imports the SDK and stays usable with MockDeviceKit.
    ///   - listenForFrames: subscribes to that stream. Same reasoning.
    ///
    /// Both are optional: with neither supplied the session runs name-only, which is exactly how it
    /// behaved before faces existed.
    func start(
        startCamera: (() async -> Void)? = nil,
        listenForFrames: ((@escaping (UIImage) -> Void) -> Any)? = nil
    ) async {
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

        // The camera comes up only after HFP is established. Meta documents this ordering, and
        // reversing it costs the audio the entire system depends on.
        if let listenForFrames {
            await startCamera?()
            startFaces(listenForFrames: listenForFrames)
        }

        narrator.play(.captureOn)
    }

    /// Loads the face model and begins consuming frames. A missing or unloadable model degrades to
    /// name-only recognition and says so on screen, rather than failing silently or taking the
    /// session down.
    private func startFaces(listenForFrames: @escaping (@escaping (UIImage) -> Void) -> Any) {
        do {
            faces = try FaceCluster(
                embedder: try VisionMobileFaceEmbedder(),
                matcher: .provisional)
            faceStatus = "faces on"
        } catch {
            faces = nil
            faceStatus = "faces unavailable"
            log("face", "face recognition unavailable: \(error.localizedDescription)", spoken: nil)
            return
        }

        let (frames, cancel) = FrameBridge.stream(listen: listenForFrames)
        cancelFrames = cancel
        faceTask = Task { [weak self] in
            guard let self else { return }
            await self.consumeFaces(frames)
        }
    }

    func stop() {
        audioTask?.cancel(); utteranceTask?.cancel(); faceTask?.cancel()
        audioTask = nil; utteranceTask = nil; faceTask = nil
        cancelFrames?(); cancelFrames = nil
        speech.stop(); spine.stop()
        presence.clear()
        faces = nil
        faceStatus = "off"
        isRunning = false
        route = "stopped"
    }

    // MARK: - Faces

    private func consumeFaces(_ frames: AsyncStream<CapturedFrame>) async {
        var lastEmbedAt = Date.distantPast
        for await frame in frames {
            let now = Date()
            guard now.timeIntervalSince(lastEmbedAt) >= Self.faceInterval else { continue }
            lastEmbedAt = now
            await observe(frame)
        }
    }

    private func observe(_ frame: CapturedFrame) async {
        guard let faces else { return }
        do {
            // Orientation travels with the frame. Feeding a sideways face to the embedder produces
            // a plausible 512-d vector that does not discriminate — measured, see
            // FaceOrientationCalibrationTests.
            guard let cluster = try await faces.clusterId(
                for: frame.image, orientation: frame.orientation) else { return }

            let now = Date()
            let changed = presence.live(at: now) != cluster
            presence.saw(cluster, at: now)
            guard changed else { return }

            facesSeen += 1
            if let person = await store.find(clusterID: cluster) {
                // Seen, not announced. A face is E4 evidence; speaking a name off a face alone is
                // exactly the false assertion the accuracy claim forbids. The wearer can ask.
                log("face", "recognised \(person.name)", spoken: nil)
            } else {
                log("face", "a face I don't have a name for", spoken: nil)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Who the wearer means by "this person": the face in front of them, falling back to the person
    /// most recently met.
    ///
    /// The fallback used to be `allPersons().last`, which is sorted ALPHABETICALLY — so "forget
    /// them" deleted whoever's name sorted last rather than the person just met.
    private func currentPerson() async -> Person? {
        if let cluster = presence.live(at: Date()),
           let byFace = await store.find(clusterID: cluster) {
            return byFace
        }
        return await store.mostRecentlyEncountered()
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

        let known = await store.allPersons()
        // The face in view when the name is spoken is the face that gets attached to it. This is
        // the entire mechanism by which a person becomes identifiable by name AND face.
        let cluster = presence.live(at: Date())
        let state = IdentityResolver(people: known).resolve(names: candidates, cluster: cluster)
        await announce(state, heard: utterance.text, cluster: cluster)
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
            let known = await store.allPersons()
            let cluster = presence.live(at: Date())
            let state = IdentityResolver(people: known).resolve(names: [candidate], cluster: cluster)
            await announce(state, heard: utterance.text, cluster: cluster)

        case .whoIsThis:
            // Explicit request: always answer, even to say we do not know. Answered from the FACE,
            // because that is what "this" means when the wearer cannot see who is in front of them.
            let cluster = presence.live(at: Date())
            let known = await store.allPersons()
            switch IdentityResolver(people: known).resolve(names: [], cluster: cluster) {
            case .known(let person):
                say(greeting(for: person), priority: .discreet, kind: "who is this")
            case .likely(let person):
                // A face got us here, so this stays a hedge no matter how confident the match was.
                say("This might be \(person.name).", priority: .discreet, kind: "who is this HEDGE")
            case .ambiguous(let names):
                say("This could be \(names.joined(separator: " or ")).",
                    priority: .discreet, kind: "who is this ASK")
            case .unnamedCluster:
                say("I can see someone, but I don't have a name for them.",
                    priority: .discreet, kind: "who is this")
            case .nothing:
                say("I don't know who this is.", priority: .discreet, kind: "who is this")
            }

        case .favorite:
            // You see the barista daily and your sister monthly. Frequency cannot infer importance,
            // so an explicit designation always wins over the automatic tier.
            if let person = await currentPerson() {
                do {
                    let updated = try await store.setManualTierOverride(.inner, for: person.id)
                    say("\(updated.name) is now a favourite.", priority: .normal, kind: "favourite")
                } catch { lastError = error.localizedDescription }
            } else {
                say("I don't know who to favourite.", priority: .normal, kind: "favourite")
            }

        case .forgetThem:
            // Destructive and unrecoverable, so it must target the person actually in front of the
            // wearer. Their face goes with them — the point of "forget" is that nothing remains.
            if let person = await currentPerson(),
               let removed = try? await store.delete(id: person.id) {
                presence.clear()
                say("Forgotten \(removed.name).", priority: .normal, kind: "forget")
            } else {
                say("There's nobody to forget.", priority: .normal, kind: "forget")
            }

        default:
            log("command", String(describing: command), spoken: nil)
        }
    }

    private func announce(_ state: IdentityState, heard: String, cluster: UUID?) async {
        switch state {
        case .known(let person):
            // Persist FIRST, then narrate — the stored person carries the real encounter count and
            // tier, and it is the tier that decides how much gets said.
            let stored = await remember(person, cluster: cluster)
            let line = greeting(for: stored)
            say(line, priority: .normal,
                kind: "ASSERT · \(stored.effectiveTier) ×\(stored.encounterCount)", heard: heard)

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

    /// Records the encounter and returns the person as stored, with an up-to-date count and tier.
    ///
    /// The cluster is the face that was in view when the name was heard. Passing it here is what
    /// makes the pairing durable: on a later encounter the same face resolves back to this person
    /// with no name spoken at all.
    @discardableResult
    private func remember(_ person: Person, cluster: UUID?) async -> Person {
        do {
            if let existing = await store.find(name: person.name) {
                return try await store.registerEncounter(
                    for: existing.id, at: Date(), clusterID: cluster)
            }
            return try await store.bind(name: person.name, org: person.org, clusterID: cluster)
        } catch {
            lastError = error.localizedDescription
            return person
        }
    }

    /// Verbosity is inversely proportional to familiarity. Reading a full card to someone you see
    /// daily is insulting; a stranger needs everything.
    private func greeting(for person: Person) -> String {
        switch person.effectiveTier {
        case .inner:
            // Nearly nothing. A pending note if there is one, otherwise just the name.
            return person.pendingNotes.first ?? person.name
        case .familiar:
            return person.name
        case .acquaintance:
            let when = person.lastEncounterAt.map {
                HumanTimeFormatter().string(since: $0)
            }
            return [person.name, person.org, when].compactMap { $0 }.joined(separator: ", ")
        case .newPerson:
            return "\(person.name). Saved."
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

    /// Brings the glasses camera up, and subscribes to it. Injected so this file never imports the
    /// DAT SDK — the same pattern `FrameBridge` uses, and what keeps MockDeviceKit workable.
    /// Left nil, the session runs name-only with no face recognition.
    var startCamera: (() async -> Void)?
    var listenForFrames: ((@escaping (UIImage) -> Void) -> Any)?

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
                Text("\(session.faceStatus) · \(session.facesSeen)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(session.faceStatus == "faces on" ? .green : .secondary)
                Text("\(session.sampleRate) Hz")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Button(session.isRunning ? "Stop" : "Start") {
                Task {
                    if session.isRunning {
                        session.stop()
                    } else {
                        await session.start(
                            startCamera: startCamera, listenForFrames: listenForFrames)
                    }
                }
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
        if kind == "face" { return .teal }
        return .secondary
    }
}

#endif
