#if canImport(AVFoundation)
import AVFoundation
import Foundation

/// Apple audio adapter for the portable Narrator. All AVFoundation state is touched on the main
/// queue; Track B's already-active `.playAndRecord` session determines the glasses route.
public final class AVNarrationOutput: NSObject, NarrationOutput, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var speechContinuation: CheckedContinuation<Void, Never>?
    private var playerContinuation: CheckedContinuation<Bool, Never>?

    public override init() {
        super.init()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.synthesizer.delegate = self
        }
    }

    public func speak(_ text: String, priority: Priority) async {
        guard !text.isEmpty, !Task.isCancelled else { return }

        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                self.finishSpeech()
                self.speechContinuation = continuation

                let utterance = AVSpeechUtterance(string: text)
                switch priority {
                case .critical:
                    utterance.rate = 0.52
                    utterance.volume = 1
                case .normal:
                    utterance.rate = 0.48
                    utterance.volume = 0.9
                case .discreet:
                    utterance.rate = 0.46
                    utterance.volume = 0.55
                }
                self.synthesizer.speak(utterance)
            }
        }
    }

    public func play(_ earcon: Earcon) async {
        _ = await playAudio(data: EarconWaveRenderer.data(for: earcon))
    }

    public func playPronunciation(at url: URL, priority: Priority) async -> Bool {
        guard FileManager.default.isReadableFile(atPath: url.path) else { return false }
        return await playAudio(url: url, volume: priority == .discreet ? 0.6 : 0.9)
    }

    public func stop() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                _ = self.synthesizer.stopSpeaking(at: .immediate)
                self.player?.stop()
                self.player = nil
                self.finishSpeech()
                self.finishPlayer(success: false)
                continuation.resume()
            }
        }
    }

    private func playAudio(data: Data) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: false)
                    return
                }
                do {
                    let player = try AVAudioPlayer(data: data)
                    self.start(player, continuation: continuation, volume: 0.9)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private func playAudio(url: URL, volume: Float) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: false)
                    return
                }
                do {
                    let player = try AVAudioPlayer(contentsOf: url)
                    self.start(player, continuation: continuation, volume: volume)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private func start(
        _ player: AVAudioPlayer,
        continuation: CheckedContinuation<Bool, Never>,
        volume: Float
    ) {
        finishPlayer(success: false)
        self.player = player
        player.delegate = self
        player.volume = volume
        player.prepareToPlay()
        playerContinuation = continuation
        if !player.play() {
            finishPlayer(success: false)
        }
    }

    private func finishSpeech() {
        let continuation = speechContinuation
        speechContinuation = nil
        continuation?.resume()
    }

    private func finishPlayer(success: Bool) {
        let continuation = playerContinuation
        playerContinuation = nil
        player = nil
        continuation?.resume(returning: success)
    }
}

extension AVNarrationOutput: AVSpeechSynthesizerDelegate {
    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        finishSpeech()
    }

    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        finishSpeech()
    }
}

extension AVNarrationOutput: AVAudioPlayerDelegate {
    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finishPlayer(success: flag)
    }

    public func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        finishPlayer(success: false)
    }
}
#endif
