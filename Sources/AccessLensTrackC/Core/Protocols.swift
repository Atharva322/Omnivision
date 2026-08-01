import Foundation

#if canImport(AVFoundation)
import AVFoundation
#else
public final class AVAudioPCMBuffer: @unchecked Sendable {
    public init() {}
}
#endif

#if canImport(CoreGraphics)
import CoreGraphics
#else
public final class CGImage: @unchecked Sendable {
    public init() {}
}
#endif

public protocol AudioSpining {
    func start() async throws
    func stop()
    var pcmStream: AsyncStream<AVAudioPCMBuffer> { get }
}

public protocol SpeechStreaming {
    var utterances: AsyncStream<Utterance> { get }
    func rotateTask()
}

public protocol CommandParsing {
    func parse(_ u: Utterance) -> Command?
}

public protocol NameExtracting {
    func candidates(in u: Utterance) -> [NameCandidate]
}

public protocol FaceClustering {
    func clusterId(for image: CGImage) async throws -> UUID?
}

public protocol IdentityResolving {
    func resolve(names: [NameCandidate], cluster: UUID?) -> IdentityState
}

public protocol Narrating {
    func say(_ text: String, priority: Priority)
    func play(_ earcon: Earcon)
    func repeatLast()
    static func line(for person: Person) -> String
}

public enum Priority: Sendable {
    case critical
    case normal
    case discreet
}

public enum Earcon: Sendable {
    case captureOn
    case captureOff
    case saved
    case unknown
    case disconnected
}
