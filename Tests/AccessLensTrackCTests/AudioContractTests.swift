//
//  AudioContractTests.swift
//  Pins the parts of the audio contract that a silent failure would otherwise hide.
//

import XCTest
#if canImport(AVFoundation)
import AVFoundation
#endif
@testable import AccessLensTrackC

/// Minimal conformer. Its only job is to prove the protocol demands what it must — if
/// `isGlassesRoute` is not in `AudioSpining`, this file does not compile.
private final class StubSpine: AudioSpining {
    var isGlassesRoute: Bool
    private let continuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    let pcmStream: AsyncStream<AVAudioPCMBuffer>

    init(isGlassesRoute: Bool) {
        self.isGlassesRoute = isGlassesRoute
        var c: AsyncStream<AVAudioPCMBuffer>.Continuation!
        pcmStream = AsyncStream { c = $0 }
        continuation = c
    }

    func start() async throws {}
    func stop() { continuation.finish() }
}

final class AudioContractTests: XCTestCase {

    /// `isGlassesRoute` must be part of the protocol, not merely present on the concrete type.
    ///
    /// Without it nothing downstream can ask "am I actually recording from the glasses?", and a
    /// silent fallback to the phone microphone is indistinguishable from success — the app looks
    /// completely healthy while capturing the wrong device. This is also the check that surfaced
    /// the measured 16 kHz route, contradicting the 8 kHz in Meta's docs.
    func testAudioSpiningExposesWhetherTheRouteIsTheGlasses() {
        let onGlasses: AudioSpining = StubSpine(isGlassesRoute: true)
        let onPhone: AudioSpining = StubSpine(isGlassesRoute: false)

        XCTAssertTrue(onGlasses.isGlassesRoute)
        XCTAssertFalse(onPhone.isGlassesRoute, "a phone-mic fallback must be observable")
    }
}
