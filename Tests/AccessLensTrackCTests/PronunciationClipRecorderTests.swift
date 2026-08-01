#if canImport(AVFoundation)
import AVFoundation
import XCTest
@testable import AccessLensTrackC

final class PronunciationClipRecorderTests: XCTestCase {
    func testCaptureIsCappedAtOneSecond() async throws {
        let directory = temporaryDirectory()
        let recorder = PronunciationClipRecorder(directory: directory)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 20_000)!
        buffer.frameLength = 20_000

        let stream = AsyncStream<AVAudioPCMBuffer> { continuation in
            continuation.yield(buffer)
            continuation.finish()
        }
        let path = try await recorder.capture(
            from: stream,
            personID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            maximumDuration: 1
        )

        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        XCTAssertEqual(file.length, 16_000)
        XCTAssertEqual(buffer.frameLength, 20_000, "shared PCM buffer length must be restored")
    }

    func testDeletionCannotEscapeOwnedDirectory() async throws {
        let directory = temporaryDirectory()
        let recorder = PronunciationClipRecorder(directory: directory)
        let outside = directory.deletingLastPathComponent().appendingPathComponent("outside.caf")

        do {
            try await recorder.deleteClip(at: outside.path)
            XCTFail("expected pathOutsidePronunciationDirectory")
        } catch let error as PronunciationCaptureError {
            XCTAssertEqual(error, .pathOutsidePronunciationDirectory)
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Pronunciations", isDirectory: true)
    }
}
#endif
