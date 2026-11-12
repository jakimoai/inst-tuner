import Accelerate
import Foundation

/// Thin wrapper over vDSP's real FFT.
///
/// Output is vDSP's packed format: `real[0]` is DC, `imag[0]` is Nyquist, and every value is
/// twice the textbook DFT.
final class RealFFT {
    let size: Int
    let halfSize: Int

    private let log2Size: vDSP_Length
    private let setup: FFTSetup

    init(size: Int) {
        precondition(size > 1 && size & (size - 1) == 0, "FFT size must be a power of two")
        self.size = size
        halfSize = size / 2
        log2Size = vDSP_Length(log2(Double(size)).rounded())
        guard let setup = vDSP_create_fftsetup(log2Size, FFTRadix(kFFTRadix2)) else {
            preconditionFailure("vDSP could not create an FFT setup")
        }
        self.setup = setup
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    func forward(
        _ input: UnsafePointer<Float>,
        real: UnsafeMutablePointer<Float>,
        imag: UnsafeMutablePointer<Float>
    ) {
        var split = DSPSplitComplex(realp: real, imagp: imag)
        input.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) {
            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(halfSize))
        }
        vDSP_fft_zrip(setup, &split, 1, log2Size, FFTDirection(kFFTDirection_Forward))
    }

    /// Inverse transform of packed data into `size` real samples. Output is unnormalised.
    func inverse(
        real: UnsafeMutablePointer<Float>,
        imag: UnsafeMutablePointer<Float>,
        output: UnsafeMutablePointer<Float>
    ) {
        var split = DSPSplitComplex(realp: real, imagp: imag)
        vDSP_fft_zrip(setup, &split, 1, log2Size, FFTDirection(kFFTDirection_Inverse))
        output.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) {
            vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(halfSize))
        }
    }

    /// Fills `magnitude` with `halfSize` values. Bin 0 holds DC only.
    func magnitudes(
        real: UnsafeMutablePointer<Float>,
        imag: UnsafeMutablePointer<Float>,
        into magnitude: UnsafeMutablePointer<Float>
    ) {
        var split = DSPSplitComplex(realp: real, imagp: imag)
        vDSP_zvabs(&split, 1, magnitude, 1, vDSP_Length(halfSize))
        magnitude[0] = abs(real[0])
    }

    static func hannWindow(size: Int) -> UnsafeMutablePointer<Float> {
        let window = UnsafeMutablePointer<Float>.allocate(capacity: size)
        vDSP_hann_window(window, vDSP_Length(size), Int32(vDSP_HANN_DENORM))
        return window
    }
}

func nextPowerOfTwo(atLeast value: Int) -> Int {
    var size = 1
    while size < value { size <<= 1 }
    return size
}
