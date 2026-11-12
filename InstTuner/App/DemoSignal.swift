#if DEBUG
import Foundation
import TunerCore

/// Feeds synthesised plucks into the tuner in place of the microphone, so the app can be run
/// and screenshotted without audio hardware. Debug builds only.
///
/// Launch arguments: `-demo YES`, `-demoString 0`, `-demoCents m12`, `-demoReadout strobe`,
/// `-demoTuning b5.standard`.
final class DemoSignal: @unchecked Sendable {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "demo") }

    private let ring: SampleRingBuffer
    private let frequencies: [Double]
    private let sampleRate: Double
    private let queue = DispatchQueue(label: "inst-tuner.demo", qos: .userInitiated)
    private var timer: DispatchSourceTimer?

    init(ring: SampleRingBuffer, frequencies: [Double], sampleRate: Double) {
        self.ring = ring
        self.frequencies = frequencies
        self.sampleRate = sampleRate
    }

    static func applyOverrides(to settings: inout TunerSettings) {
        let defaults = UserDefaults.standard
        if let readout = defaults.string(forKey: "demoReadout"), let mode = ReadoutMode(rawValue: readout) {
            settings.readout = mode
        }
        if let tuning = defaults.string(forKey: "demoTuning") {
            settings.selectedTuningID = tuning
        }
    }

    func start() {
        queue.async { [self] in
            let samples = makeLoop()
            var position = 0
            let block = Int(sampleRate * 0.01)

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 0.01)
            timer.setEventHandler { [self] in
                samples.withUnsafeBufferPointer { buffer in
                    guard let base = buffer.baseAddress else { return }
                    if position + block > samples.count { position = 0 }
                    ring.write(base + position, count: block)
                    position += block
                }
            }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
        }
    }

    private func makeLoop() -> [Float] {
        let defaults = UserDefaults.standard
        let index = min(defaults.integer(forKey: "demoString"), frequencies.count - 1)
        // Launch arguments can't start with a dash, so "m12" means minus twelve.
        let fixedCents = defaults.string(forKey: "demoCents")
            .flatMap { Double($0.replacingOccurrences(of: "m", with: "-")) }

        if let fixedCents {
            return pluck(Interval.shift(frequencies[index], byCents: fixedCents), decay: 60, duration: 12)
        }

        let detunes = [-14.0, 6.0, 0.4]
        var loop: [Float] = []
        for (position, frequency) in frequencies.enumerated() {
            let detune = detunes[position % detunes.count]
            loop += pluck(Interval.shift(frequency, byCents: detune), decay: 2.2, duration: 2.8)
        }
        return loop
    }

    private func pluck(_ frequency: Double, decay: Double, duration: Double) -> [Float] {
        var parameters = PluckSynth.Parameters(frequency: frequency)
        parameters.inharmonicity = frequency < 70 ? 0.0012 : 0.00015
        parameters.decay = decay
        parameters.attackBendCents = 6
        parameters.noiseDB = -66
        parameters.microphoneCorner = 90
        return PluckSynth.render(parameters, sampleRate: sampleRate, duration: duration)
    }
}
#endif
