import Foundation

public struct EarconTone: Hashable, Sendable {
    public let frequency: Double
    public let duration: TimeInterval
    public let amplitude: Double

    public init(frequency: Double, duration: TimeInterval, amplitude: Double = 0.35) {
        self.frequency = frequency
        self.duration = duration
        self.amplitude = amplitude
    }
}

public struct EarconPattern: Equatable, Sendable {
    public let tones: [EarconTone]
    public let gap: TimeInterval

    public init(tones: [EarconTone], gap: TimeInterval = 0.035) {
        self.tones = tones
        self.gap = gap
    }

    public var duration: TimeInterval {
        tones.reduce(0) { $0 + $1.duration }
            + (tones.isEmpty ? 0 : Double(tones.count - 1) * gap)
    }
}

/// Synthesized at runtime so the five states cannot be broken by a missing asset in an Xcode
/// target. The recording-consent tone is the same documented `captureOn` cue.
public enum EarconLibrary {
    public static func pattern(for earcon: Earcon) -> EarconPattern {
        switch earcon {
        case .captureOn:
            return EarconPattern(tones: [
                EarconTone(frequency: 587.33, duration: 0.09),
                EarconTone(frequency: 880.00, duration: 0.13)
            ])
        case .captureOff:
            return EarconPattern(tones: [
                EarconTone(frequency: 880.00, duration: 0.09),
                EarconTone(frequency: 587.33, duration: 0.13)
            ])
        case .saved:
            return EarconPattern(tones: [
                EarconTone(frequency: 523.25, duration: 0.07),
                EarconTone(frequency: 659.25, duration: 0.07),
                EarconTone(frequency: 783.99, duration: 0.12)
            ], gap: 0.025)
        case .unknown:
            return EarconPattern(tones: [
                EarconTone(frequency: 349.23, duration: 0.16),
                EarconTone(frequency: 329.63, duration: 0.16)
            ], gap: 0.05)
        case .disconnected:
            return EarconPattern(tones: [
                EarconTone(frequency: 987.77, duration: 0.11, amplitude: 0.5),
                EarconTone(frequency: 493.88, duration: 0.14, amplitude: 0.5),
                EarconTone(frequency: 246.94, duration: 0.22, amplitude: 0.5)
            ], gap: 0.025)
        }
    }
}

enum EarconWaveRenderer {
    static func data(for earcon: Earcon, sampleRate: Int = 22_050) -> Data {
        let pattern = EarconLibrary.pattern(for: earcon)
        let samples = render(pattern, sampleRate: sampleRate)
        let byteCount = samples.count * MemoryLayout<Int16>.size

        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + byteCount), to: &data)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16), to: &data)
        append(UInt16(1), to: &data)
        append(UInt16(1), to: &data)
        append(UInt32(sampleRate), to: &data)
        append(UInt32(sampleRate * 2), to: &data)
        append(UInt16(2), to: &data)
        append(UInt16(16), to: &data)
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(byteCount), to: &data)
        samples.forEach { append(UInt16(bitPattern: $0), to: &data) }
        return data
    }

    private static func render(_ pattern: EarconPattern, sampleRate: Int) -> [Int16] {
        var result: [Int16] = []
        let gapSamples = max(0, Int(pattern.gap * Double(sampleRate)))

        for (index, tone) in pattern.tones.enumerated() {
            let sampleCount = max(1, Int(tone.duration * Double(sampleRate)))
            let fadeSamples = min(sampleCount / 2, max(1, Int(0.012 * Double(sampleRate))))
            for sampleIndex in 0..<sampleCount {
                let phase = 2 * Double.pi * tone.frequency * Double(sampleIndex) / Double(sampleRate)
                let fadeIn = min(1, Double(sampleIndex) / Double(fadeSamples))
                let fadeOut = min(1, Double(sampleCount - sampleIndex - 1) / Double(fadeSamples))
                let envelope = max(0, min(fadeIn, fadeOut))
                let value = sin(phase) * tone.amplitude * envelope * Double(Int16.max)
                result.append(Int16(value.rounded()))
            }
            if index < pattern.tones.count - 1 {
                result.append(contentsOf: repeatElement(Int16(0), count: gapSamples))
            }
        }
        return result
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
