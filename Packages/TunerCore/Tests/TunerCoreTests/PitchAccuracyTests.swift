import Foundation
import Testing
@testable import TunerCore

@Suite("Pitch accuracy")
struct PitchAccuracyTests {
    static let guitarNotes = ["E2", "A2", "D3", "G3", "B3", "E4", "E5", "E6"]
    static let bassNotes = ["A0", "B0", "E1", "A1", "D2", "G2"]

    @Test("Pure tones read within 0.2 cents across the range", arguments: Array(stride(from: 21, through: 96, by: 3)))
    func pureTones(midi: Int) throws {
        for detune in [-23.7, 0.0, 17.3] {
            let truth = Interval.shift(midiFrequency(midi), byCents: detune)
            let frames = engineFrequencies(sine(frequency: truth))
            #expect(!frames.isEmpty)
            #expect(trimmedWorstCents(frames, truth: truth) < 0.2, "midi \(midi), detune \(detune)")
        }
    }

    @Test("Guitar plucks read within 0.5 cents", arguments: guitarNotes)
    func guitarPlucks(name: String) throws {
        var parameters = PluckSynth.Parameters(frequency: midiFrequency(try #require(Note(name)).midi))
        parameters.inharmonicity = 0.00012
        parameters.attackBendCents = 8
        let readings = engineReadings(PluckSynth.render(parameters, sampleRate: testSampleRate, duration: 2))
        #expect(!readings.isEmpty)
        #expect(trimmedWorstHeardCents(readings, parameters) < 0.5, "\(name)")
    }

    /// The pitch a stiff string sounds at drifts as its bright overtones fade, so the allowance
    /// is wider than for guitar.
    @Test("Stiff bass strings read within 3.5 cents of the pitch they sound", arguments: bassNotes)
    func bassPlucks(name: String) throws {
        var parameters = PluckSynth.Parameters(frequency: midiFrequency(try #require(Note(name)).midi))
        parameters.inharmonicity = 0.0012
        parameters.decay = 3.5
        let readings = engineReadings(PluckSynth.render(parameters, sampleRate: testSampleRate, duration: 2))
        #expect(!readings.isEmpty)
        #expect(trimmedWorstHeardCents(readings, parameters) < 3.5, "\(name)")
    }

    /// The hard case: a phone mic barely hears a low B's fundamental, so the reading rests on
    /// the overtones alone.
    @Test("Low strings through a weak phone mic read within 3.5 cents of the pitch they sound", arguments: bassNotes, [90.0, 150.0])
    func bassThroughPhoneMic(name: String, corner: Double) throws {
        var parameters = PluckSynth.Parameters(frequency: midiFrequency(try #require(Note(name)).midi))
        parameters.inharmonicity = 0.0015
        parameters.decay = 3.5
        parameters.microphoneCorner = corner
        parameters.noiseDB = -62
        let readings = engineReadings(PluckSynth.render(parameters, sampleRate: testSampleRate, duration: 2))
        #expect(!readings.isEmpty)
        #expect(trimmedWorstHeardCents(readings, parameters) < 3.5, "\(name) at \(corner) Hz")
    }

    /// Players tune a stiff string to what they hear, which is sharp of its theoretical
    /// fundamental. Reading the fundamental instead made a low E that sounded right show flat.
    @Test("A stiff low string reads the pitch you hear, not its lower fundamental")
    func stiffStringReadsHeardPitch() throws {
        var parameters = PluckSynth.Parameters(frequency: midiFrequency(28))
        parameters.inharmonicity = 0.0009
        parameters.decay = 3.5
        parameters.microphoneCorner = 180
        let readings = engineReadings(PluckSynth.render(parameters, sampleRate: testSampleRate, duration: 2))
        let heard = try #require(median(readings.map(\.frequency)))
        #expect(Interval.cents(heard, from: midiFrequency(28)) > 5)
        #expect(trimmedWorstHeardCents(readings, parameters) < 3)
    }

    @Test("Readings hold up in room noise", arguments: Array(guitarNotes.prefix(6)) + Array(bassNotes.suffix(3)))
    func noisyPlucks(name: String) throws {
        var parameters = PluckSynth.Parameters(frequency: midiFrequency(try #require(Note(name)).midi))
        parameters.inharmonicity = 0.0003
        parameters.noiseDB = -38
        let readings = engineReadings(PluckSynth.render(parameters, sampleRate: testSampleRate, duration: 2))
        #expect(!readings.isEmpty)
        #expect(trimmedWorstHeardCents(readings, parameters) < 1.5, "\(name)")
    }

    @Test("Works at 44.1 kHz too")
    func otherSampleRate() throws {
        var parameters = PluckSynth.Parameters(frequency: midiFrequency(40))
        parameters.inharmonicity = 0.0002
        let samples = PluckSynth.render(parameters, sampleRate: 44_100, duration: 2)
        let readings = engineReadings(samples, sampleRate: 44_100)
        #expect(!readings.isEmpty)
        #expect(trimmedWorstHeardCents(readings, parameters, sampleRate: 44_100) < 0.5)
    }
}

@Suite("Octave choice")
struct OctaveTests {
    /// Almost all the energy is in the second harmonic, the classic cause of octave errors.
    private func evenHeavy(_ fundamental: Double) -> [Float] {
        let count = Int(2 * testSampleRate)
        let amplitudes: [(Double, Float)] = [(1, 0.01), (2, 0.5), (3, 0.09), (4, 0.2), (5, 0.04)]
        return (0..<count).map { index in
            let time = Double(index) / testSampleRate
            return amplitudes.reduce(Float(0)) { sum, partial in
                sum + partial.1 * Float(sin(2 * Double.pi * fundamental * partial.0 * time))
            }
        }
    }

    @Test("A missing fundamental still reads the right octave", arguments: ["B0", "E1", "A1", "E2", "A2"])
    func missingFundamental(name: String) throws {
        let truth = midiFrequency(try #require(Note(name)).midi)
        let frames = engineFrequencies(evenHeavy(truth))
        #expect(!frames.isEmpty)
        #expect(trimmedWorstCents(frames, truth: truth) < 20, "\(name)")
    }

    @Test("A real high note isn't dragged down an octave", arguments: ["B1", "E3", "A3", "E4"])
    func genuineHighNote(name: String) throws {
        let truth = midiFrequency(try #require(Note(name)).midi)
        let frames = engineFrequencies(sine(frequency: truth))
        #expect(trimmedWorstCents(frames, truth: truth) < 5, "\(name)")
    }

    @Test("Knowing the strings fixes an octave doubt")
    func stringPrior() throws {
        let truth = midiFrequency(40)
        // A pure octave-up signal: nothing in the spectrum points to E2.
        let samples = sine(frequency: truth * 2)
        let configuration = PitchEngine.Configuration(stringFrequencies: strings("E2 A2 D3 G3 B3 E4"))
        let frames = engineFrequencies(samples, configuration: configuration)
        #expect(trimmedWorstCents(frames, truth: truth) < 5)
    }

    @Test("Locking a string pulls the reading to that string's octave")
    func lockedString() throws {
        let truth = midiFrequency(28)
        let samples = sine(frequency: truth * 2)
        let configuration = PitchEngine.Configuration(lockedFrequency: truth)
        let frames = engineFrequencies(samples, configuration: configuration)
        #expect(trimmedWorstCents(frames, truth: truth) < 5)
    }
}

@Suite("Silence and noise")
struct RejectionTests {
    @Test("Silence reads nothing")
    func silence() {
        let samples = [Float](repeating: 0, count: Int(2 * testSampleRate))
        #expect(engineFrequencies(samples, from: 0, to: 2).isEmpty)
    }

    @Test("White noise doesn't produce a note")
    func whiteNoise() {
        var random: UInt64 = 0xDEAD_BEEF_CAFE_F00D
        let samples: [Float] = (0..<Int(3 * testSampleRate)).map { _ in
            random ^= random << 13
            random ^= random >> 7
            random ^= random << 17
            return 0.05 * (Float(random >> 40) / Float(1 << 23) - 1)
        }

        let session = TunerSession(sampleRate: testSampleRate, settings: .init())
        var readings = 0
        samples.withUnsafeBufferPointer { buffer in
            var position = 0
            while position + session.hopSize <= samples.count {
                if session.process(hop: buffer.baseAddress! + position).reading != nil {
                    readings += 1
                }
                position += session.hopSize
            }
        }
        #expect(readings == 0)
    }

    /// Mains hum is perfectly periodic, so only its steadiness gives it away.
    @Test("Steady hum fades out, and a note played over it still reads", arguments: [50.0, 60.0])
    func hum(mains: Double) throws {
        let duration = 9.0
        let count = Int(duration * testSampleRate)
        var random: UInt64 = 0x1234_5678_9ABC_DEF1
        let background: [Float] = (0..<count).map { index in
            let time = Double(index) / testSampleRate
            random ^= random << 13
            random ^= random >> 7
            random ^= random << 17
            let noise = 0.0001 * (Double(random >> 40) / Double(1 << 23) - 1)
            let hum = 0.0025 * sin(2 * .pi * mains * time)
                + 0.0012 * sin(2 * .pi * 2 * mains * time)
                + 0.0006 * sin(2 * .pi * 3 * mains * time)
            return Float(hum + noise)
        }

        // The A string of each instrument, played six seconds in.
        for (tuningID, midi) in [("g6.standard", 45), ("b4.standard", 33), (nil, 45)] as [(String?, Int)] {
            let strings = try tuningID.map { try #require(TuningLibrary.tuning(id: $0)).strings } ?? []
            var parameters = PluckSynth.Parameters(frequency: midiFrequency(midi))
            parameters.inharmonicity = 0.0001
            var samples = background
            let pluckStart = Int(6 * testSampleRate)
            for (offset, value) in PluckSynth.render(parameters, sampleRate: testSampleRate, duration: 2).enumerated() {
                samples[pluckStart + offset] += value
            }

            let session = TunerSession(sampleRate: testSampleRate, settings: .init(strings: strings))
            var humReadings = 0
            var noteReadings: [TunerReading] = []
            samples.withUnsafeBufferPointer { buffer in
                var position = 0
                while position + session.hopSize <= samples.count {
                    let reading = session.process(hop: buffer.baseAddress! + position).reading
                    position += session.hopSize
                    let time = Double(position) / testSampleRate
                    if time > 4, time < 6, reading?.isLive == true { humReadings += 1 }
                    if time > 6.4, time < 7.4, let reading, reading.isLive { noteReadings.append(reading) }
                }
            }
            let label = "\(tuningID ?? "chromatic") at \(mains) Hz"
            #expect(humReadings == 0, "\(label)")
            #expect(noteReadings.count > 30, "\(label)")
            let read = median(noteReadings.map(\.frequency)) ?? 0
            let sounded = heardPitch(parameters, at: 0.8)
            #expect(abs(Interval.cents(read, from: sounded)) < 1, "\(label): read \(read) Hz, sounded \(sounded) Hz")
        }
    }
}

@Suite("Tone generator")
struct ToneTests {
    @Test("The reference tone measures on pitch", arguments: [30.87, 41.2, 82.41, 329.63])
    func loopback(frequency: Double) {
        let generator = ToneGenerator(sampleRate: testSampleRate)
        generator.play(frequency: frequency)
        var samples = [Float](repeating: 0, count: Int(2 * testSampleRate))
        samples.withUnsafeMutableBufferPointer {
            generator.render(into: $0.baseAddress!, frameCount: $0.count)
        }
        let frames = engineFrequencies(samples)
        #expect(!frames.isEmpty)
        #expect(trimmedWorstCents(frames, truth: frequency) < 1)
    }
}

@Suite("Changing strings")
struct StringChangeTests {
    private func readings(_ samples: [Float], tuning: Tuning) -> [(time: Double, reading: TunerReading)] {
        let session = TunerSession(sampleRate: testSampleRate, settings: .init(strings: tuning.strings))
        var result: [(Double, TunerReading)] = []
        samples.withUnsafeBufferPointer { buffer in
            var position = 0
            while position + session.hopSize <= samples.count {
                let reading = session.process(hop: buffer.baseAddress! + position).reading
                position += session.hopSize
                if let reading, reading.isLive { result.append((Double(position) / testSampleRate, reading)) }
            }
        }
        return result
    }

    private func pluck(_ name: String, amplitude: Double, corner: Double? = nil, duration: Double = 3) throws -> [Float] {
        var parameters = PluckSynth.Parameters(frequency: midiFrequency(try #require(Note(name)).midi))
        parameters.inharmonicity = 0.0001
        parameters.amplitude = amplitude
        parameters.microphoneCorner = corner
        return PluckSynth.render(parameters, sampleRate: testSampleRate, duration: duration)
    }

    /// High E is the 4th overtone of low E, and B the 3rd. A quieter pluck right after the low
    /// string is damped may not count as a new note, but it must still move to its own string.
    @Test("A quieter pluck on an overtone string moves to that string", arguments: [("E4", 5), ("B3", 4)])
    func overtoneString(name: String, index: Int) throws {
        let tuning = try #require(TuningLibrary.tuning(id: "g6.standard"))
        var samples = try pluck("E2", amplitude: 0.3)
        let change = Int(0.9 * testSampleRate)
        for position in change..<samples.count {
            samples[position] *= Float(exp(-Double(position - change) / testSampleRate / 0.02))
        }
        let second = try pluck(name, amplitude: 0.15, duration: 2.1)
        for (offset, value) in second.enumerated() { samples[change + offset] += value }

        let heard = readings(samples, tuning: tuning)
        let before = heard.filter { $0.time > 0.4 && $0.time < 0.85 }
        let after = heard.filter { $0.time > 1.6 && $0.time < 2.8 }
        #expect(!before.isEmpty && before.allSatisfy { $0.reading.stringIndex == 0 })
        #expect(after.count > 30)
        let onNewString = after.filter { $0.reading.stringIndex == index }.count
        #expect(Double(onNewString) > 0.9 * Double(after.count), "\(name): \(onNewString) of \(after.count)")
    }

    @Test("A low string heard mostly through its overtones stays on its own string", arguments: [150.0, 250.0])
    func lowStringStays(corner: Double) throws {
        let tuning = try #require(TuningLibrary.tuning(id: "g6.standard"))
        let heard = readings(try pluck("E2", amplitude: 0.3, corner: corner, duration: 4), tuning: tuning)
        #expect(heard.count > 100)
        let wrong = heard.filter { $0.reading.stringIndex != 0 }.count
        #expect(wrong == 0, "\(wrong) of \(heard.count) frames on another string")
    }
}

@Suite("Odd sample rates")
struct SampleRateTests {
    @Test("The spectrum stays in bounds at a low sample rate")
    func lowRate() {
        let sampleRate = 8_000.0
        let session = TunerSession(sampleRate: sampleRate, settings: .init(wantsSpectrum: true))
        let samples: [Float] = (0..<Int(sampleRate)).map { Float(0.3 * sin(2 * .pi * 220 * Double($0) / sampleRate)) }
        var spectrum: [Float]?
        samples.withUnsafeBufferPointer { buffer in
            var position = 0
            while position + session.hopSize <= samples.count {
                spectrum = session.process(hop: buffer.baseAddress! + position).spectrum
                position += session.hopSize
            }
        }
        #expect(spectrum?.count == PitchEngine.spectrumColumnCount)
    }
}
