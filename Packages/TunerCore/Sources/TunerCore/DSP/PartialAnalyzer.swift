import Accelerate
import Foundation

/// One measured overtone of a string.
struct Partial: Equatable {
    var harmonic: Int
    var frequency: Double
    var magnitude: Double
}

struct PartialSet {
    var partials: [Partial]
    /// Measured string stiffness for this frame. Nil when too few overtones were found.
    var inharmonicity: Double?

    /// The fundamental implied by the overtones, given the string's stiffness.
    func fundamental(inharmonicity stiffness: Double) -> Double {
        PartialAnalyzer.fundamental(of: partials, inharmonicity: stiffness)
    }

    /// The pitch the overtones add up to, weighting each by how loud it is.
    ///
    /// A stiff string's overtones run sharp, so what the ear hears sits a few cents above the
    /// string's theoretical fundamental, up to 15 cents on a bass's low E. Players tune to what
    /// they hear, and other tuners measure the same thing, so this is the reading to show.
    var heardPitch: Double {
        var total = 0.0
        var weightSum = 0.0
        for partial in partials {
            total += partial.magnitude * partial.frequency / Double(partial.harmonic)
            weightSum += partial.magnitude
        }
        return total / weightSum
    }
}

/// Measures a string's overtones precisely.
///
/// Stiff strings ring slightly sharp in their upper overtones, and the effect is largest on a
/// low B. Fitting the stiffness model `fₙ = n·f₀·√(1 + B·n²)` predicts where each overtone will
/// be, so they can be found and tracked even when the microphone can't hear the fundamental.
final class PartialAnalyzer {
    private let sampleRate: Double
    private let minimumSize: Int
    private let maximumSize: Int
    private var transforms: [Int: RealFFT] = [:]
    private var windows: [Int: UnsafeMutablePointer<Float>] = [:]

    private let windowed: UnsafeMutablePointer<Float>
    private let earlierReal: UnsafeMutablePointer<Float>
    private let earlierImag: UnsafeMutablePointer<Float>
    private let laterReal: UnsafeMutablePointer<Float>
    private let laterImag: UnsafeMutablePointer<Float>
    private let magnitude: UnsafeMutablePointer<Float>

    private let maximumHarmonic = 16
    private let maximumStiffness = 0.006
    private let periodsPerWindow = 12.0

    static let hopDivisor = 4

    init(sampleRate: Double, minimumSize: Int, maximumSize: Int) {
        self.sampleRate = sampleRate
        self.minimumSize = minimumSize
        self.maximumSize = maximumSize

        var size = minimumSize
        while size <= maximumSize {
            transforms[size] = RealFFT(size: size)
            windows[size] = RealFFT.hannWindow(size: size)
            size *= 2
        }

        windowed = .allocate(capacity: maximumSize)
        earlierReal = .allocate(capacity: maximumSize / 2)
        earlierImag = .allocate(capacity: maximumSize / 2)
        laterReal = .allocate(capacity: maximumSize / 2)
        laterImag = .allocate(capacity: maximumSize / 2)
        magnitude = .allocate(capacity: maximumSize / 2)
    }

    deinit {
        windows.values.forEach { $0.deallocate() }
        windowed.deallocate()
        earlierReal.deallocate()
        earlierImag.deallocate()
        laterReal.deallocate()
        laterImag.deallocate()
        magnitude.deallocate()
    }

    /// Analyses the samples ending just before `end`.
    func analyze(
        end: UnsafePointer<Float>,
        available: Int,
        coarseFrequency: Double,
        stiffnessGuess: Double
    ) -> PartialSet? {
        let period = sampleRate / coarseFrequency
        var size = minimumSize
        while size < maximumSize, Double(size) < periodsPerWindow * period { size *= 2 }

        let hop = size / Self.hopDivisor
        guard available >= size + hop,
              let transform = transforms[size],
              let window = windows[size]
        else { return nil }

        vDSP_vmul(end - size - hop, 1, window, 1, windowed, 1, vDSP_Length(size))
        transform.forward(windowed, real: earlierReal, imag: earlierImag)
        vDSP_vmul(end - size, 1, window, 1, windowed, 1, vDSP_Length(size))
        transform.forward(windowed, real: laterReal, imag: laterImag)
        transform.magnitudes(real: laterReal, imag: laterImag, into: magnitude)

        let found = trackPartials(size: size, hop: hop, coarse: coarseFrequency, stiffness: stiffnessGuess)
        guard !found.isEmpty else { return nil }

        let strongest = found.map(\.magnitude).max() ?? 0
        var kept = found.filter { $0.magnitude >= strongest * 0.03 }
        guard !kept.isEmpty else { return nil }

        var measured = measureStiffness(kept)
        let residualBase = measured ?? stiffnessGuess
        let centre = Self.fundamental(of: kept, inharmonicity: residualBase)
        let trimmed = kept.filter { partial in
            let n = Double(partial.harmonic)
            let expected = n * centre * (1 + residualBase * n * n).squareRoot()
            return abs(Interval.cents(partial.frequency, from: expected)) <= 8
        }
        if !trimmed.isEmpty, trimmed.count < kept.count {
            kept = trimmed
            measured = measureStiffness(kept)
        }

        return PartialSet(partials: kept, inharmonicity: measured)
    }

    /// Walks up the overtone series, using what it has found so far to predict the next one.
    private func trackPartials(size: Int, hop: Int, coarse: Double, stiffness: Double) -> [Partial] {
        let binWidth = sampleRate / Double(size)
        let upperLimit = min(sampleRate * 0.42, 6000)
        let phaseToBins = Double(size) / (2 * Double.pi * Double(hop))

        var found: [Partial] = []
        found.reserveCapacity(maximumHarmonic)
        var estimate = coarse
        var currentStiffness = stiffness

        for harmonic in 1...maximumHarmonic {
            let n = Double(harmonic)
            let predicted = n * estimate * (1 + currentStiffness * n * n).squareRoot()
            if predicted >= upperLimit { break }

            let radius = max(1.5 * binWidth, 0.22 * estimate)
            let low = max(2, Int((predicted - radius) / binWidth))
            let high = min(size / 2 - 2, Int((predicted + radius) / binWidth) + 1)
            guard low <= high else { continue }

            var bestBin = -1
            var bestMagnitude: Float = 0
            for bin in low...high
            where magnitude[bin] > bestMagnitude
                && magnitude[bin] > magnitude[bin - 1]
                && magnitude[bin] >= magnitude[bin + 1] {
                bestBin = bin
                bestMagnitude = magnitude[bin]
            }
            guard bestBin > 0 else { continue }

            // The phase change between the two frames pins the frequency far below bin width.
            let earlierPhase = atan2(Double(earlierImag[bestBin]), Double(earlierReal[bestBin]))
            let laterPhase = atan2(Double(laterImag[bestBin]), Double(laterReal[bestBin]))
            let expectedAdvance = 2 * Double.pi * Double(bestBin) * Double(hop) / Double(size)
            let deviation = Self.wrapped(laterPhase - earlierPhase - expectedAdvance)
            let frequency = (Double(bestBin) + deviation * phaseToBins) * binWidth

            guard abs(frequency - predicted) < 0.3 * estimate else { continue }
            found.append(Partial(harmonic: harmonic, frequency: frequency, magnitude: Double(bestMagnitude)))

            if found.count >= 2 {
                let measured = measureStiffness(found) ?? currentStiffness
                let refined = Self.fundamental(of: found, inharmonicity: measured)
                if abs(Interval.cents(refined, from: coarse)) < 140 {
                    estimate = refined
                    currentStiffness = measured
                }
            }
        }
        return found
    }

    /// Weighted straight-line fit of (fₙ/n)² against n². Slope over intercept is the stiffness.
    private func measureStiffness(_ partials: [Partial]) -> Double? {
        guard partials.count >= 3,
              let lowest = partials.first?.harmonic,
              let highest = partials.last?.harmonic,
              highest - lowest >= 2
        else { return nil }

        var sumW = 0.0, sumX = 0.0, sumY = 0.0, sumXX = 0.0, sumXY = 0.0
        for partial in partials {
            let n = Double(partial.harmonic)
            let x = n * n
            let y = (partial.frequency / n) * (partial.frequency / n)
            let w = Self.weight(partial)
            sumW += w
            sumX += w * x
            sumY += w * y
            sumXX += w * x * x
            sumXY += w * x * y
        }

        let determinant = sumW * sumXX - sumX * sumX
        guard determinant > 1e-9 else { return nil }
        let slope = (sumW * sumXY - sumX * sumY) / determinant
        let intercept = (sumY - slope * sumX) / sumW
        guard intercept > 0 else { return nil }
        return min(max(slope / intercept, 0), maximumStiffness)
    }

    static func fundamental(of partials: [Partial], inharmonicity: Double) -> Double {
        var total = 0.0
        var weightSum = 0.0
        for partial in partials {
            let n = Double(partial.harmonic)
            let w = weight(partial)
            total += w * partial.frequency / (n * (1 + inharmonicity * n * n).squareRoot())
            weightSum += w
        }
        return total / weightSum
    }

    private static func weight(_ partial: Partial) -> Double {
        partial.magnitude * Double(partial.harmonic)
    }

    private static func wrapped(_ phase: Double) -> Double {
        phase - 2 * Double.pi * (phase / (2 * Double.pi)).rounded()
    }
}
