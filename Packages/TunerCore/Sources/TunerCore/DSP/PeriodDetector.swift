import Accelerate
import Foundation

struct LagPeak: Equatable {
    var lag: Double
    var value: Double
}

/// Finds repeating periods with the normalised square difference function (McLeod's method).
/// Because it looks at the waveform's period, it still works when the fundamental is missing,
/// which is what a phone microphone does to a low B.
final class PeriodDetector {
    let windowSize: Int
    let maxLag: Int

    private let fft: RealFFT
    private let padded: UnsafeMutablePointer<Float>
    private let correlation: UnsafeMutablePointer<Float>
    private let real: UnsafeMutablePointer<Float>
    private let imag: UnsafeMutablePointer<Float>
    private let nsdf: UnsafeMutablePointer<Float>

    init(windowSize: Int, maxLag: Int) {
        precondition(maxLag < windowSize)
        self.windowSize = windowSize
        self.maxLag = maxLag

        let fftSize = nextPowerOfTwo(atLeast: windowSize + maxLag + 1)
        fft = RealFFT(size: fftSize)
        padded = .allocate(capacity: fftSize)
        correlation = .allocate(capacity: fftSize)
        real = .allocate(capacity: fftSize / 2)
        imag = .allocate(capacity: fftSize / 2)
        nsdf = .allocate(capacity: maxLag + 2)
        nsdf.initialize(repeating: 0, count: maxLag + 2)
    }

    deinit {
        padded.deallocate()
        correlation.deallocate()
        real.deallocate()
        imag.deallocate()
        nsdf.deallocate()
    }

    /// Computes the NSDF of the `windowSize` samples starting at `samples`.
    func compute(_ samples: UnsafePointer<Float>) {
        padded.update(from: samples, count: windowSize)
        (padded + windowSize).initialize(repeating: 0, count: fft.size - windowSize)

        var energy: Float = 0
        vDSP_svesq(samples, 1, &energy, vDSP_Length(windowSize))
        guard energy > 1e-12 else {
            nsdf.update(repeating: 0, count: maxLag + 2)
            return
        }

        fft.forward(padded, real: real, imag: imag)
        real[0] *= real[0]
        imag[0] *= imag[0]
        for bin in 1..<fft.halfSize {
            real[bin] = real[bin] * real[bin] + imag[bin] * imag[bin]
            imag[bin] = 0
        }
        fft.inverse(real: real, imag: imag, output: correlation)

        // correlation[0] must equal the signal energy, which sets the FFT's scale exactly.
        let scale = Double(energy) / Double(correlation[0])

        var denominator = 2 * Double(energy)
        for lag in 0...(maxLag + 1) {
            if lag > 0 {
                let leaving = Double(samples[lag - 1])
                let entering = Double(samples[windowSize - lag])
                denominator -= leaving * leaving + entering * entering
            }
            let numerator = 2 * Double(correlation[lag]) * scale
            nsdf[lag] = denominator > 1e-12 ? Float(numerator / denominator) : 0
        }
    }

    /// Collects the highest point of each positive lobe between `minLag` and `maxLag`.
    func collectPeaks(minLag: Int, into peaks: inout [LagPeak]) {
        peaks.removeAll(keepingCapacity: true)

        var lag = 1
        while lag <= maxLag && nsdf[lag] > 0 { lag += 1 }

        while lag <= maxLag {
            while lag <= maxLag && nsdf[lag] <= 0 { lag += 1 }

            var best = -1
            var bestValue: Float = 0
            while lag <= maxLag && nsdf[lag] > 0 {
                let value = nsdf[lag]
                if value > bestValue, value > nsdf[lag - 1], value >= nsdf[lag + 1] {
                    best = lag
                    bestValue = value
                }
                lag += 1
            }

            if best >= minLag {
                peaks.append(interpolatedPeak(at: best))
            }
        }
    }

    /// The NSDF's highest value within `tolerance` samples of `lag`.
    func value(near lag: Double, tolerance: Int) -> Double {
        let centre = Int(lag.rounded())
        let low = max(1, centre - tolerance)
        let high = min(maxLag, centre + tolerance)
        guard low <= high else { return 0 }

        var best: Float = -1
        for index in low...high where nsdf[index] > best {
            best = nsdf[index]
        }
        return Double(best)
    }

    private func interpolatedPeak(at index: Int) -> LagPeak {
        let before = Double(nsdf[index - 1])
        let centre = Double(nsdf[index])
        let after = Double(nsdf[index + 1])
        let curvature = before - 2 * centre + after
        guard curvature < 0 else { return LagPeak(lag: Double(index), value: centre) }

        let shift = 0.5 * (before - after) / curvature
        return LagPeak(lag: Double(index) + shift, value: centre - 0.25 * (before - after) * shift)
    }
}
