import Foundation
@testable import TunerCore

let testSampleRate = 48_000.0

/// Runs `samples` through the raw engine and returns the frequencies measured between
/// `from` and `to` seconds.
func engineFrequencies(
    _ samples: [Float],
    configuration: PitchEngine.Configuration = .init(),
    from start: Double = 0.5,
    to end: Double = 1.6,
    sampleRate: Double = testSampleRate
) -> [Double] {
    let engine = PitchEngine(sampleRate: sampleRate, configuration: configuration)
    var results: [Double] = []
    samples.withUnsafeBufferPointer { buffer in
        guard let base = buffer.baseAddress else { return }
        var position = 0
        while position + engine.hopSize <= samples.count {
            let output = engine.process(hop: base + position)
            position += engine.hopSize
            let time = Double(position) / sampleRate
            if time >= start, time <= end, let analysis = output.analysis {
                results.append(analysis.frequency)
            }
        }
    }
    return results
}

/// Like `engineFrequencies`, with each frame's time.
func engineReadings(
    _ samples: [Float],
    configuration: PitchEngine.Configuration = .init(),
    from start: Double = 0.5,
    to end: Double = 1.6,
    sampleRate: Double = testSampleRate
) -> [(time: Double, frequency: Double)] {
    let engine = PitchEngine(sampleRate: sampleRate, configuration: configuration)
    var results: [(Double, Double)] = []
    samples.withUnsafeBufferPointer { buffer in
        guard let base = buffer.baseAddress else { return }
        var position = 0
        while position + engine.hopSize <= samples.count {
            let output = engine.process(hop: base + position)
            position += engine.hopSize
            let time = Double(position) / sampleRate
            if time >= start, time <= end, let analysis = output.analysis {
                results.append((time, analysis.frequency))
            }
        }
    }
    return results
}

/// The pitch a synthesised string's overtones add up to at `time`, weighted by loudness. That's
/// what the ear and a period-based tuner hear. On a stiff string it's sharp of the fundamental.
func heardPitch(_ parameters: PluckSynth.Parameters, at time: Double, sampleRate: Double = testSampleRate) -> Double {
    let partials = parameters.partials(at: time, sampleRate: sampleRate)
        .enumerated()
        .filter { $0.offset < 16 && $0.element.frequency < 6000 }
    let strongest = partials.map(\.element.amplitude).max() ?? 0
    var total = 0.0
    var weights = 0.0
    for (index, partial) in partials where partial.amplitude >= 0.03 * strongest {
        total += partial.amplitude * partial.frequency / Double(index + 1)
        weights += partial.amplitude
    }
    return total / weights
}

/// Worst distance of each frame from what the string sounded like then, ignoring the 5% of
/// frames furthest away. Each frame measures a window of about 12 periods ending at the
/// frame, so it hears the string as it was half a window earlier.
func trimmedWorstHeardCents(_ readings: [(time: Double, frequency: Double)], _ parameters: PluckSynth.Parameters, sampleRate: Double = testSampleRate) -> Double {
    var size = 2048
    while size < 16384, Double(size) < 12 * sampleRate / parameters.frequency { size *= 2 }
    let lag = Double(size) / 2 / sampleRate
    let errors = readings.map {
        abs(Interval.cents($0.frequency, from: heardPitch(parameters, at: $0.time - lag, sampleRate: sampleRate)))
    }.sorted()
    if ProcessInfo.processInfo.environment["TUNER_VERBOSE"] != nil, !errors.isEmpty {
        let signed = readings.map { Interval.cents($0.frequency, from: heardPitch(parameters, at: $0.time - lag, sampleRate: sampleRate)) }.sorted()
        print(String(format: "HEARD f=%.1f B=%.4f median %+.2f p5 %+.2f p95 %+.2f", parameters.frequency, parameters.inharmonicity, signed[signed.count / 2], signed[signed.count / 20], signed[signed.count * 19 / 20]))
    }
    guard !errors.isEmpty else { return .infinity }
    return errors[min(errors.count - 1, Int(Double(errors.count) * 0.95))]
}

func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    return values.sorted()[values.count / 2]
}

/// Worst distance of the measured frames from `truth`, ignoring the 5% furthest away.
func trimmedWorstCents(_ values: [Double], truth: Double) -> Double {
    let errors = values.map { abs(Interval.cents($0, from: truth)) }.sorted()
    guard !errors.isEmpty else { return .infinity }
    return errors[min(errors.count - 1, Int(Double(errors.count) * 0.95))]
}

func midiFrequency(_ midi: Int) -> Double {
    440 * pow(2, Double(midi - 69) / 12)
}

func sine(frequency: Double, duration: Double = 2, amplitude: Float = 0.3) -> [Float] {
    let count = Int(duration * testSampleRate)
    return (0..<count).map { index in
        amplitude * Float(sin(2 * Double.pi * frequency * Double(index) / testSampleRate))
    }
}

func strings(_ text: String) -> [Double] {
    text.split(separator: " ").compactMap { Note(String($0)) }.map { midiFrequency($0.midi) }
}
