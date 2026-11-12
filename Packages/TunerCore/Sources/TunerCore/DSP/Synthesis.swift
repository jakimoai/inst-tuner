import Foundation
import Synchronization

/// Renders a physically modelled plucked string. Used by the tests and the demo signal.
public enum PluckSynth {
    public struct Parameters: Sendable {
        public var frequency: Double
        /// String stiffness B in fₙ = n·f₀·√(1 + B·n²).
        public var inharmonicity: Double = 0
        public var partialCount: Int = 20
        /// Where along the string it is plucked, as a fraction of its length.
        public var pluckPosition: Double = 0.2
        /// Seconds for the fundamental to fall to 37%.
        public var decay: Double = 2.5
        /// Corner of a 12 dB/octave high-pass, modelling a phone microphone's weak low end.
        public var microphoneCorner: Double?
        /// How sharp the attack starts, in cents. Decays away over about 150 ms.
        public var attackBendCents: Double = 0
        /// White noise level relative to full scale, in dB.
        public var noiseDB: Double?
        public var amplitude: Double = 0.3

        public init(frequency: Double) {
            self.frequency = frequency
        }

        /// Each overtone's frequency and amplitude `time` seconds after the pluck.
        public func partials(at time: Double, sampleRate: Double) -> [(frequency: Double, amplitude: Double)] {
            (1...partialCount).compactMap { harmonic in
                let n = Double(harmonic)
                let frequency = n * self.frequency * (1 + inharmonicity * n * n).squareRoot()
                guard frequency < sampleRate * 0.45 else { return nil }
                var amplitude = abs(sin(n * Double.pi * pluckPosition)) / n
                if let corner = microphoneCorner {
                    let ratio = (frequency / corner) * (frequency / corner)
                    amplitude *= ratio / (1 + ratio * ratio).squareRoot()
                }
                amplitude *= exp(-PluckSynth.decayRate(self, harmonic: n) * time)
                return (frequency, amplitude)
            }
        }
    }

    static func decayRate(_ parameters: Parameters, harmonic n: Double) -> Double {
        (1 / parameters.decay) * (1 + 0.15 * n * n / 4)
    }

    public static func render(
        _ parameters: Parameters,
        sampleRate: Double,
        duration: Double,
        seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    ) -> [Float] {
        let count = Int(duration * sampleRate)
        var output = [Float](repeating: 0, count: count)

        var totalAmplitude = 0.0
        for harmonic in 1...parameters.partialCount {
            let n = Double(harmonic)
            let frequency = n * parameters.frequency * (1 + parameters.inharmonicity * n * n).squareRoot()
            guard frequency < sampleRate * 0.45 else { continue }

            var amplitude = abs(sin(n * Double.pi * parameters.pluckPosition)) / n
            if let corner = parameters.microphoneCorner {
                let ratio = (frequency / corner) * (frequency / corner)
                amplitude *= ratio / (1 + ratio * ratio).squareRoot()
            }
            totalAmplitude += amplitude

            let decayRate = Self.decayRate(parameters, harmonic: n)
            let attackTime = 0.15
            var phase = 0.0

            for index in 0..<count {
                let time = Double(index) / sampleRate
                let bend = parameters.attackBendCents * exp(-time / attackTime)
                let instantaneous = frequency * pow(2, bend / 1200)
                phase += 2 * Double.pi * instantaneous / sampleRate
                let envelope = amplitude * exp(-decayRate * time) * min(1, time / 0.002)
                output[index] += Float(envelope * sin(phase))
            }
        }

        let scale = Float(parameters.amplitude / max(totalAmplitude, 1e-9) * 2.2)
        var random = seed
        let noiseAmplitude = parameters.noiseDB.map { Float(pow(10, $0 / 20)) }
        for index in 0..<count {
            output[index] *= scale
            if let noiseAmplitude {
                random ^= random << 13
                random ^= random >> 7
                random ^= random << 17
                output[index] += noiseAmplitude * (Float(random >> 40) / Float(1 << 23) - 1)
            }
        }
        return output
    }
}

/// Plays a reference pitch. It turns down harmonics below 220 Hz, so a low string's note still
/// comes through a phone speaker, which can't reproduce the fundamental.
///
/// `render` runs on the real-time audio thread. It never locks or allocates.
public final class ToneGenerator: @unchecked Sendable {
    private static let partialCount = 12

    private let sampleRate: Double
    private let frequencyBits = Atomic<UInt64>(0)
    private let isGateOpen = Atomic<Bool>(false)

    private let phases: UnsafeMutablePointer<Double>
    private let gains: UnsafeMutablePointer<Double>
    private var preparedBits: UInt64 = 0
    private var envelope = 0.0

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        phases = .allocate(capacity: Self.partialCount)
        phases.initialize(repeating: 0, count: Self.partialCount)
        gains = .allocate(capacity: Self.partialCount)
        gains.initialize(repeating: 0, count: Self.partialCount)
    }

    deinit {
        phases.deallocate()
        gains.deallocate()
    }

    public func play(frequency: Double) {
        frequencyBits.store(frequency.bitPattern, ordering: .relaxed)
        isGateOpen.store(true, ordering: .relaxed)
    }

    public func stop() {
        isGateOpen.store(false, ordering: .relaxed)
    }

    public func render(into buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        let bits = frequencyBits.load(ordering: .relaxed)
        if bits != preparedBits {
            preparedBits = bits
            prepareGains(frequency: Double(bitPattern: bits))
        }

        let frequency = Double(bitPattern: bits)
        let target = isGateOpen.load(ordering: .relaxed) ? 1.0 : 0.0
        let step = 2 * Double.pi * frequency / sampleRate
        let envelopeRate = 1 - exp(-1 / (0.012 * sampleRate))

        for frame in 0..<frameCount {
            envelope += (target - envelope) * envelopeRate
            var sample = 0.0
            for index in 0..<Self.partialCount where gains[index] > 0 {
                let advance = step * Double(index + 1)
                phases[index] += advance
                if phases[index] > 2 * Double.pi { phases[index] -= 2 * Double.pi }
                sample += gains[index] * sin(phases[index])
            }
            buffer[frame] = Float(sample * envelope)
        }
    }

    private func prepareGains(frequency: Double) {
        var total = 0.0
        for index in 0..<Self.partialCount {
            let n = Double(index + 1)
            let partial = frequency * n
            guard partial < sampleRate * 0.45, partial > 0 else {
                gains[index] = 0
                continue
            }
            let speakerWeight = partial < 220 ? pow(partial / 220, 1.2) : 1
            gains[index] = speakerWeight / pow(n, 0.85)
            total += gains[index]
        }
        guard total > 0 else { return }
        for index in 0..<Self.partialCount {
            gains[index] *= 0.55 / total
        }
    }
}
