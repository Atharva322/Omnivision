//
// ShopView.swift
// The shop screen — see docs/SHOP_SCREEN_PLAN.md Tasks 4, 5, 8.
//
// iOS ONLY. Modelled on OmnivisionView.swift's wiring pattern, as the plan instructs.
//
//   glasses mic  -> AudioSpine -> SpeechStream -> LumenCommandParser -> lookingFor/whatIsThis/
//                                                                        rememberThisOne/pause
//   glasses cam  -> FrameBridge -> PackageTextReader -> ProductTextMatcher -> ShopNarration
//                                        (Task 1)            (Task 2)            (Task 3)
//                                  -> BarcodeScanner  ---------^  (Task 5, tiebreaker only,
//                                                                  never something to aim at)
//                     all -> AnnouncementGate -> Narrator (Track D)
//                     preferences -> ProductStore (Task 6, flat JSON, mirrors PersonStore)
//
// UNVERIFIED. Written without a Mac to compile or run this against — no Xcode, no Vision, no
// SwiftUI available in this environment. Every downstream piece it wires together (PackageText,
// ProductTextMatcher, ShopNarration, ProductStore, the Command grammar) is unit-tested via
// `scripts/swift-linux.sh test`; this file itself has never been built. Treat it exactly the way
// RED_FLAGS.md treats everything marked "should work" — build it on a Mac before trusting it, and
// expect to fix real compile errors, not just review this as if it already ran.
//

#if os(iOS)

import CoreGraphics
import Foundation
import OSLog
import SwiftUI
import AccessLensTrackC

@Observable
@MainActor
final class ShopSession {

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
    private(set) var targetCategory: String?
    private(set) var lastMatch: ProductMatch?
    private(set) var framesScanned = 0
    private(set) var framesDropped = 0

    /// Wearer-controlled, drives the gate. Set by "Lumen, pause".
    private(set) var silenceRequested = false
    private var lastOtherSpeechAt: Date?
    private var lastFrame: CapturedFrame?
    /// What the camera is ACTUALLY doing, not what was successfully constructed.
    private(set) var cameraStatus = "off"
    private(set) var framesReceived = 0
    private var cameraWatchdog: Task<Void, Never>?

    /// What "remember this one" just overwrote, so "Lumen, that's wrong" can put it back. Cleared
    /// on undo, on the next save, or once `undoWindow` has passed — an undo offered five minutes
    /// later, after the wearer has moved on, would revert a save they no longer remember making.
    private var pendingUndo: (category: String, previous: SavedProduct, at: Date)?
    private let undoWindow: TimeInterval = 30

    let narrator = Narrator()

    private let spine = AudioSpine()
    private let speech = SpeechStream()
    private let commands = LumenCommandParser()
    private let barcodeScanner = BarcodeScanner()
    private var gate = AnnouncementGate()
    private var store: ProductStore?

    /// Task 7: identifies this run to the backend, and the raw text of whatever was last
    /// scanned — sent alongside a question so /ask has something to reason over, since this
    /// session never calls /locate (see ShopAssist/backend/app/main.py's own comment on why).
    private let sessionID = UUID().uuidString
    private var lastPackageText: PackageText?
    /// Base URL of the Python backend (ShopAssist/backend), e.g. an ngrok URL during a demo.
    /// Nobody has decided how this gets configured for a real run — hardcode, a settings screen,
    /// whatever's fastest — this default is a localhost placeholder, not a real answer.
    /// Where the shop backend lives.
    ///
    /// NOT localhost — on the phone that means the phone, so every `/ask` would fail with nothing
    /// but "I can't reach the network for that one" to show for it. Resolves the Mac by its Bonjour
    /// name, which survives the DHCP lease changing between now and the demo where a hardcoded IP
    /// would not. Port 8010 because 8000 is taken by an unrelated backend on that machine.
    ///
    /// Override without rebuilding, e.g. if the venue blocks mDNS:
    ///     defaults write <app-domain> OmnivisionBackendURL "http://10.0.0.5:8010"
    var backendBaseURL: URL = {
        if let override = UserDefaults.standard.string(forKey: "OmnivisionBackendURL"),
           let url = URL(string: override) {
            return url
        }
        return URL(string: "http://MacBook-Pro-629.local:8010")!
    }()

    private var audioTask: Task<Void, Never>?
    private var utteranceTask: Task<Void, Never>?
    private var frameTask: Task<Void, Never>?
    private var cancelFrames: (() -> Void)?

    /// True while a scan is running. At 2fps a backlog would build silently if frames queued
    /// instead of being dropped — see FrameBridge/ShopScanner's own reasoning, which this repeats.
    private var isScanning = false

    var context: ProactiveContext {
        ProactiveContext(
            lastOtherSpeechAt: lastOtherSpeechAt,
            silenceRequested: silenceRequested,
            now: Date())
    }

    // MARK: - Lifecycle

    /// - Parameters:
    ///   - startCamera: brings the DAT camera stream up, returning an error message on failure.
    ///     Subscribing is not the same as starting: this view only ever subscribed, so it received
    ///     frames solely if something else had already begun streaming — which nothing had.
    ///   - listenForFrames: bridges the DAT camera publisher. Injected rather than referenced
    ///     directly so this stays usable with MockDeviceKit.
    ///
    /// The error is surfaced HERE rather than only in the host app, whose alert sits underneath
    /// this screen where a blind wearer will never find it.
    func start(
        startCamera: (() async -> String?)? = nil,
        listenForFrames: @escaping (@escaping (UIImage) -> Void) -> Any
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
        if !spine.isGlassesRoute {
            narrator.say("Using phone microphone, not the glasses.", priority: .critical)
        }

        do {
            store = try ProductStore()
        } catch {
            // A corrupt product store must not stop the wearer from shopping — see
            // ProductStore's own doc comment: it throws rather than silently starting empty, so
            // the corruption is not lost, but the session still has to degrade gracefully here.
            lastError = "Saved products unavailable, starting fresh this session: \(error.localizedDescription)"
            store = nil
        }

        speech.start()
        isRunning = true

        audioTask = Task { await speech.consume(spine.pcmStream) }
        utteranceTask = Task { [weak self] in
            guard let self else { return }
            for await utterance in await self.speech.utterances {
                await self.handle(utterance)
            }
        }

        // Camera after HFP. Meta documents that ordering, and reversing it costs the audio.
        if let cameraError = await startCamera?() ?? nil {
            cameraStatus = "camera failed"
            lastError = "Camera did not start: \(cameraError)"
            log("camera", "camera did not start: \(cameraError)", spoken: nil)
        }

        let (frames, cancel) = FrameBridge.stream(listen: listenForFrames)
        cancelFrames = cancel
        frameTask = Task { [weak self] in
            guard let self else { return }
            await self.consume(frames)
        }

        // A subscription is not a stream. Without this, "scanned 0" is indistinguishable from a
        // wearer who simply has not pointed at anything yet — and the wearer cannot see either.
        cameraWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, !Task.isCancelled, self.framesReceived == 0 else { return }
            self.cameraStatus = "no camera frames"
            self.narrator.say("The camera isn't sending anything.", priority: .critical)
            self.log("camera", "no frames in 8 seconds — scanning is not running", spoken: nil)
        }

        narrator.play(.captureOn)
    }

    func stop() {
        audioTask?.cancel(); utteranceTask?.cancel(); frameTask?.cancel(); cameraWatchdog?.cancel()
        audioTask = nil; utteranceTask = nil; frameTask = nil; cameraWatchdog = nil
        cameraStatus = "off"
        cancelFrames?(); cancelFrames = nil
        speech.stop(); spine.stop()
        isRunning = false
        route = "stopped"
    }

    // MARK: - Speech

    private func handle(_ utterance: Utterance) async {
        if utterance.channel == .other { lastOtherSpeechAt = utterance.at }

        switch commands.outcome(for: utterance) {
        case .matched(let parsed):
            await run(parsed.command)

        case .rejected(.unknownCommand(let remainder)) where !remainder.isEmpty:
            // Task 7: the wake word was heard, but the remainder matches none of the fixed
            // commands. Rather than silently dropping an utterance the wearer clearly addressed
            // to Lumen, treat it as an open-ended question for the cloud path — this is the one
            // place in the grammar that is deliberately open-ended rather than a fixed row.
            await askAboutProduct(remainder)

        default:
            log("heard", utterance.text, spoken: nil)
        }
    }

    private func run(_ command: Command) async {
        switch command {

        case .pause:
            silenceRequested = true
            narrator.play(.captureOff)
            log("command", "pause — silence requested", spoken: "(earcon)")

        case .lookingFor(let category):
            targetCategory = category
            lastMatch = nil
            let text = "Looking for \(category)."
            narrator.say(text, priority: .normal)
            log("command", "looking for \(category)", spoken: text)

        case .whatIsThis:
            guard let frame = lastFrame else {
                let text = "I don't see anything yet."
                narrator.say(text, priority: .normal)
                log("command", "what is this — no frame yet", spoken: text)
                return
            }
            await scan(frame, mode: .requested)

        case .rememberThisOne, .rememberThis:
            // Both phrasings act here. The grammar distinguishes them because on the SOCIAL screen
            // "remember this" starts a conversation capture — a meaning with no counterpart while
            // shopping. Leaving it unhandled meant the wearer said a perfectly reasonable sentence
            // and got total silence, which to someone who cannot see the screen is indistinguishable
            // from a crash. Observed on device.
            await rememberProductInFrame()

        case .thatsWrong:
            // Shared with the social grammar. Here it only means one thing: undo the most recent
            // "remember this one" — see undoLastSave() for why it is a no-op rather than an error
            // when nothing is pending, since the wearer may well have meant it for the other track.
            await undoLastSave()

        default:
            // Social-track commands. This session does not act on them; the social screen does.
            log("command", String(describing: command), spoken: nil)
        }
    }

    // MARK: - Shop: frame loop

    private func consume(_ frames: AsyncStream<CapturedFrame>) async {
        for await frame in frames {
            framesReceived += 1
            if cameraStatus != "camera on" { cameraStatus = "camera on" }
            lastFrame = frame
            guard !isScanning else {
                framesDropped += 1
                continue
            }
            await scan(frame, mode: .proactive)
        }
    }

    private func scan(_ frame: CapturedFrame, mode: NarrationMode) async {
        guard let category = targetCategory else {
            if mode == .requested {
                let text = "Tell me what you're looking for first."
                narrator.say(text, priority: .normal)
                log("command", "what is this — no category set", spoken: text)
            }
            return
        }

        isScanning = true
        defer { isScanning = false }
        framesScanned += 1

        let catalog = await store?.snapshot() ?? ProductCatalog()

        do {
            let text = try await PackageTextReader.read(frame.image, orientation: frame.orientation)
            lastPackageText = text
            var match = ProductTextMatcher.match(text, against: catalog, category: category)

            // Task 5: barcode as tiebreaker, ONLY when text matching lands on brandOnly, and
            // ONLY if a barcode happens to already be in frame. Never something to aim at — if
            // it is not there, this stays hedged rather than prompting the wearer to find one.
            if case .brandOnly = match {
                let payload = (try? await barcodeScanner.payload(
                    in: frame.image, orientation: frame.orientation)) ?? nil
                if let payload, case .yourUsual(let product) = catalog.recognize(
                    barcode: payload, inCategory: category
                ) {
                    match = .exact(product)
                }
            }

            // Narrate proactively only when the CONCLUSION changes.
            //
            // `lastMatch` was recorded and never consulted, so every frame re-announced and the
            // 90-second cooldown became a metronome: hold one package and hear the same sentence
            // forever. Comparing whole matches would not have helped — OCR jitter changes the
            // payload every frame ("Juang", "Juanz", "Jung"), so each looked like news.
            //
            // A requested answer is always given: the wearer asked, and "the same as last time"
            // is a perfectly good answer to a question.
            let previous = lastMatch
            lastMatch = match
            if mode == .proactive, previous?.conclusion == match.conclusion {
                return
            }

            let announcement = ShopNarration.announcement(for: match, mode: mode, at: Date())
            speak(announcement, mode: mode, kind: "product")
        } catch {
            lastError = error.localizedDescription
            log("error", error.localizedDescription, spoken: nil)
        }
    }

    // MARK: - Shop: saving a preference

    /// "Lumen, remember this one" — Task 6. Reads the package in frame and saves the two most
    /// prominent lines as brand and variant.
    private func rememberProductInFrame() async {
        guard let category = targetCategory else {
            let text = "Tell me what you're looking for first."
            narrator.say(text, priority: .normal)
            log("command", "remember this one — no category set", spoken: text)
            return
        }
        guard let frame = lastFrame else {
            let text = "I don't see anything yet."
            narrator.say(text, priority: .normal)
            log("command", "remember this one — no frame yet", spoken: text)
            return
        }
        guard let store else {
            // Never claim a save succeeded when nothing was written — that is what makes every
            // OTHER "Saved" in this session trustworthy. A corrupt store must not silently lose
            // the wearer's preference AND tell them it worked.
            let text = "I can't save right now."
            narrator.say(text, priority: .normal)
            log("error", "remember this one — store unavailable", spoken: text)
            return
        }

        do {
            let text = try await PackageTextReader.read(frame.image, orientation: frame.orientation)
            guard let brand = text.mostProminent else {
                let spoken = "I can't read a brand on this. Try turning the label toward the camera."
                narrator.say(spoken, priority: .normal)
                log("command", "remember this one — nothing legible", spoken: spoken)
                return
            }
            let variant = text.lines.count > 1 ? text.lines[1].text : nil

            // A barcode, if one happens to be in frame, is free to capture now and pays for
            // itself later as the Task 5 tiebreaker — never something the wearer had to aim for.
            let barcode = (try? await barcodeScanner.payload(
                in: frame.image, orientation: frame.orientation)) ?? nil

            let product = SavedProduct(
                barcode: barcode ?? "", brand: brand, variant: variant, category: category)
            let previous = await store.saved(inCategory: category)
            try await store.save(product)

            // "Is that right?" was spoken here before, but nothing ever listened for an answer —
            // asking a question the system cannot hear is worse than not asking. Offering a real
            // undo instead (Task 6, Step 3's actual intent: the wearer cannot see what was
            // captured, so a silently wrong preference would poison every future comparison).
            if let previous {
                pendingUndo = (category: category, previous: previous, at: Date())
                let spoken = "Replacing your usual \(previous.label) with \(product.label). Say \"that's wrong\" to undo."
                narrator.say(spoken, priority: .normal)
                log("command", "remember this one — replaced \(previous.label)", spoken: spoken)
            } else {
                pendingUndo = nil
                let spoken = "Saved \(product.label)."
                narrator.say(spoken, priority: .normal)
                log("command", "remember this one", spoken: spoken)
            }
        } catch {
            lastError = error.localizedDescription
            log("error", error.localizedDescription, spoken: nil)
        }
    }

    /// "Lumen, that's wrong" within `undoWindow` of a "remember this one" that replaced an
    /// existing preference — puts the previous one back.
    private func undoLastSave() async {
        guard let pending = pendingUndo, let store else {
            // Nothing pending, or the store is unavailable. Not an error: the wearer may well
            // have meant this for the social track, since `that's wrong` is shared vocabulary.
            log("command", "that's wrong — nothing to undo here", spoken: nil)
            return
        }
        guard Date().timeIntervalSince(pending.at) <= undoWindow else {
            pendingUndo = nil
            log("command", "that's wrong — undo window expired", spoken: nil)
            return
        }

        do {
            try await store.save(pending.previous)
            pendingUndo = nil
            let spoken = "Reverted. Your usual \(pending.previous.label) is back."
            narrator.say(spoken, priority: .normal)
            log("command", "undo remember this one", spoken: spoken)
        } catch {
            lastError = error.localizedDescription
            log("error", error.localizedDescription, spoken: nil)
        }
    }

    // MARK: - Shop: open-ended questions (Task 7, cloud path)
    //
    // The one deliberate exception to "on-device by default" — nothing on this side can answer
    // "is this sugar free", so this reasons over whatever text was last read on-device rather
    // than trying to replicate that judgement locally.

    private func askAboutProduct(_ question: String) async {
        // Immediate acknowledgement before the call — measured at 2.5-7.8s per call (see
        // docs/SHOP_SCREEN_PLAN.md), and several seconds of silence reads as a crash to someone
        // who cannot see a spinner.
        narrator.say("Let me look.", priority: .normal)
        log("command", "asked: \(question)", spoken: "Let me look.")

        let url = backendBaseURL.appendingPathComponent("ask")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15

        let boundary = "shop-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func addField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append(
                "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        addField("session_id", sessionID)
        addField("question", question)
        if let visibleText = lastPackageText?.lines.map(\.text).joined(separator: "\n"),
           !visibleText.isEmpty {
            addField("product_context", visibleText)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            struct AskResponse: Decodable { let answer: String }
            let decoded = try JSONDecoder().decode(AskResponse.self, from: data)
            narrator.say(decoded.answer, priority: .normal)
            log("product", "answered: \(question)", spoken: decoded.answer)
        } catch {
            // No network → say so explicitly (Task 7, Step 4). The on-device text path keeps
            // working regardless; make that distinction audible rather than leaving the wearer
            // wondering why nothing happened.
            let text = "I can't reach the network for that one."
            narrator.say(text, priority: .normal)
            log("error", error.localizedDescription, spoken: text)
        }
    }

    // MARK: - Output

    private func speak(_ announcement: Announcement?, mode: NarrationMode, kind: String) {
        guard let announcement else { return }

        // An explicit request bypasses the gate's repeat cooldown — asking and being ignored a
        // second time reads as the app having crashed, the same reasoning ShopScanner uses.
        if mode == .requested {
            narrator.say(announcement.text, priority: announcement.priority.speechPriority)
            log(kind, announcement.text, spoken: announcement.text)
            return
        }

        switch gate.decide(announcement, context: context) {
        case .speak(let approved):
            narrator.say(approved.text, priority: approved.priority.speechPriority)
            log(kind, approved.text, spoken: approved.text)
        case .suppress(_, let reason):
            log("\(kind) (held)", announcement.text, spoken: "suppressed: \(reason.rawValue)")
        }
    }

    /// Mirrors every event to the unified log as well as the on-screen transcript.
    ///
    /// Only the social screen did this, so when the shop loop was reported there was nothing in the
    /// device log to read back — the transcript is the right channel for a demo and the wrong one
    /// for diagnosing a session that has already ended.
    ///
    ///     sudo log collect --device-udid <udid> --last 15m --output phone.logarchive
    ///     log show phone.logarchive --predicate 'subsystem == "com.omnivision.shop"'
    private static let logger = Logger(subsystem: "com.omnivision.shop", category: "session")

    private func log(_ kind: String, _ detail: String, spoken: String?) {
        Self.logger.log("\(kind, privacy: .public) | \(detail, privacy: .public) | spoken=\(spoken ?? "-", privacy: .public)")
        events.append(Event(at: Date(), kind: kind, detail: detail, spoken: spoken))
        if events.count > 80 { events.removeFirst(events.count - 80) }
    }
}

struct ShopView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var session = ShopSession()

    /// Supplies the real DAT camera subscription. See `ShopSession.start(listenForFrames:)` — this
    /// is a placeholder until whoever owns the DAT session (Track B) wires the real one in.
    var listenForFrames: (@escaping (UIImage) -> Void) -> Any = { _ in () }
    /// Brings the glasses camera up. Without it this screen subscribes to a stream nobody started.
    var startCamera: (() async -> String?)?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusBar
                Divider()
                transcript
            }
            .navigationTitle("Shop Assist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { session.stop(); dismiss() }
                }
            }
        }
    }

    // MARK: - Task 8: demo mirror
    //
    // Judges cannot hear what is in the wearer's ear, and the wearer cannot see this screen —
    // this exists for the sighted teammate debugging and for judges watching, same as
    // OmnivisionView's transcript.

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

            HStack {
                Text(session.targetCategory.map { "Looking for: \($0)" } ?? "Say what you're looking for")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(session.cameraStatus) · \(session.framesReceived)f · scanned \(session.framesScanned)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Text("Say: \u{201C}Lumen, I'm looking for milk\u{201D} · \u{201C}Lumen, what is this\u{201D} · \u{201C}Lumen, remember this one\u{201D} · \u{201C}Lumen, pause\u{201D}")
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
                    Text("Press Start, say what you're looking for, then hold up a product.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            .padding(14)
        }
    }

    private func colour(for kind: String) -> Color {
        if kind == "product" { return .green }
        if kind.contains("held") { return .purple }
        if kind == "error" { return .red }
        if kind == "command" { return .blue }
        return .secondary
    }
}

#endif
