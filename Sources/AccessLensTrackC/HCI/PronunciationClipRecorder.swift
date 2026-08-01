#if canImport(AVFoundation)
import AVFoundation
import Foundation

public enum PronunciationCaptureError: Error, Equatable {
    case noAudio
    case invalidFormat
    case formatChanged
    case pathOutsidePronunciationDirectory
}

/// Records at most one second from Track B's existing PCM stream. It does not install a second
/// audio-engine tap, which would conflict with speech recognition and the glasses route.
public actor PronunciationClipRecorder {
    public let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
    }

    @discardableResult
    public func capture(
        from stream: AsyncStream<AVAudioPCMBuffer>,
        personID: UUID,
        maximumDuration: TimeInterval = 1
    ) async throws -> String {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: Self.directoryAttributes
        )

        var iterator = stream.makeAsyncIterator()
        guard let first = await iterator.next() else {
            throw PronunciationCaptureError.noAudio
        }
        let format = first.format
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw PronunciationCaptureError.invalidFormat
        }

        let duration = min(1, max(0.1, maximumDuration))
        let targetFrames = AVAudioFramePosition(duration * format.sampleRate)
        let url = directory
            .appendingPathComponent(personID.uuidString, isDirectory: false)
            .appendingPathExtension("caf")
        let audioFile = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )

        var written: AVAudioFramePosition = 0
        try write(first, to: audioFile, targetFrames: targetFrames, written: &written)

        while written < targetFrames, let buffer = await iterator.next() {
            guard buffer.format.sampleRate == format.sampleRate,
                  buffer.format.channelCount == format.channelCount,
                  buffer.format.commonFormat == format.commonFormat,
                  buffer.format.isInterleaved == format.isInterleaved else {
                try? FileManager.default.removeItem(at: url)
                throw PronunciationCaptureError.formatChanged
            }
            try write(buffer, to: audioFile, targetFrames: targetFrames, written: &written)
        }

        guard written > 0 else {
            try? FileManager.default.removeItem(at: url)
            throw PronunciationCaptureError.noAudio
        }
        return url.path
    }

    /// Deletes only paths contained by this recorder's directory. This is the safe half of the
    /// complete `forget them` artifact-deletion flow.
    public func deleteClip(at path: String) throws {
        let root = directory.standardizedFileURL.path
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        guard candidate == root || candidate.hasPrefix(root + "/") else {
            throw PronunciationCaptureError.pathOutsidePronunciationDirectory
        }
        if FileManager.default.fileExists(atPath: candidate) {
            try FileManager.default.removeItem(atPath: candidate)
        }
    }

    private func write(
        _ buffer: AVAudioPCMBuffer,
        to file: AVAudioFile,
        targetFrames: AVAudioFramePosition,
        written: inout AVAudioFramePosition
    ) throws {
        let remaining = targetFrames - written
        guard remaining > 0, buffer.frameLength > 0 else { return }

        let originalLength = buffer.frameLength
        let acceptedLength = AVAudioFrameCount(min(AVAudioFramePosition(originalLength), remaining))
        buffer.frameLength = acceptedLength
        defer { buffer.frameLength = originalLength }
        try file.write(from: buffer)
        written += AVAudioFramePosition(acceptedLength)
    }

    private static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("AccessLens", isDirectory: true)
            .appendingPathComponent("Pronunciations", isDirectory: true)
    }

    private static var directoryAttributes: [FileAttributeKey: Any]? {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        return [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #else
        return nil
        #endif
    }
}
#endif
