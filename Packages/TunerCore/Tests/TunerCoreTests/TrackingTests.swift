import Foundation
import Testing
@testable import TunerCore

private extension PitchTracker {
    mutating func required(_ frequency: Double?) throws -> Reading {
        let reading = update(frequency)
        return try #require(reading)
    }
}

@Suite("Tracking")
struct TrackingTests {
    private let frameRate = 46.875

    @Test("One wild frame doesn't move the reading")
    func glitchIgnored() throws {
        var tracker = PitchTracker(frameRate: frameRate)
        for _ in 0..<20 { _ = tracker.update(110) }
        let steady = try tracker.required(110)
        let afterGlitch = try tracker.required(220)
        #expect(abs(Interval.cents(afterGlitch.frequency, from: steady.frequency)) < 0.5)
    }

    @Test("A real note change is followed within a few frames")
    func noteChange() throws {
        var tracker = PitchTracker(frameRate: frameRate)
        for _ in 0..<20 { _ = tracker.update(110) }
        var frames = 0
        var reading = try tracker.required(164.81)
        frames += 1
        while abs(Interval.cents(reading.frequency, from: 164.81)) > 5, frames < 20 {
            reading = try tracker.required(164.81)
            frames += 1
        }
        #expect(frames <= 4)
    }

    @Test("An octave flip needs more evidence than a note change")
    func octaveFlip() throws {
        var tracker = PitchTracker(frameRate: frameRate)
        for _ in 0..<20 { _ = tracker.update(82.41) }
        for _ in 0..<4 { _ = tracker.update(164.82) }
        let held = try tracker.required(164.82)
        #expect(abs(Interval.cents(held.frequency, from: 82.41)) < 2)
    }

    @Test("The reading holds after the note stops, then clears")
    func holdThenClear() throws {
        var tracker = PitchTracker(frameRate: frameRate, holdDuration: 0.5)
        for _ in 0..<20 { _ = tracker.update(110) }
        for _ in 0..<3 { _ = tracker.update(nil) }
        let held = try tracker.required(nil)
        #expect(held.isLive == false)
        for _ in 0..<40 { _ = tracker.update(nil) }
        #expect(tracker.update(nil) == nil)
    }

    @Test("A frame or two of dropout keeps the reading live")
    func shortGap() throws {
        var tracker = PitchTracker(frameRate: frameRate)
        for _ in 0..<20 { _ = tracker.update(110) }
        for _ in 0..<3 {
            let reading = try tracker.required(nil)
            #expect(reading.isLive)
        }
        let back = try tracker.required(110)
        #expect(back.isLive)
        #expect(abs(Interval.cents(back.frequency, from: 110)) < 0.5)
    }

    @Test("In-tune needs a moment to enter and extra error to leave")
    func inTuneHysteresis() {
        var detector = InTuneDetector(frameRate: frameRate, tolerance: 2, holdTime: 0.18)
        #expect(detector.update(cents: 1, isLive: true) == false)
        #expect(detector.isInTune == false)

        var fired = 0
        for _ in 0..<20 where detector.update(cents: 1, isLive: true) { fired += 1 }
        #expect(fired == 1)
        #expect(detector.isInTune)

        _ = detector.update(cents: 3, isLive: true)
        #expect(detector.isInTune, "3 cents is inside the exit margin")
        _ = detector.update(cents: 4, isLive: true)
        #expect(detector.isInTune == false)
    }

    @Test("Coming back into tune after a dropout isn't announced twice")
    func announceOncePerPluck() {
        var detector = InTuneDetector(frameRate: frameRate, tolerance: 2, holdTime: 0.18)
        func play(_ cents: Double?, live: Bool = true, frames: Int = 20) -> Int {
            var fired = 0
            for _ in 0..<frames where detector.update(cents: cents, isLive: live) { fired += 1 }
            return fired
        }

        #expect(play(1) == 1)
        #expect(play(nil, live: false, frames: 5) == 0)
        #expect(play(1) == 0, "Same note fading in and out")
        #expect(detector.isInTune)

        #expect(play(12) == 0)
        #expect(play(1) == 1, "Went out of tune, then back in")

        #expect(play(nil, live: false, frames: 5) == 0)
        detector.rearm()
        #expect(play(1) == 1, "A new pluck")
    }
}

@Suite("End to end")
struct SessionTests {
    private func run(_ samples: [Float], session: TunerSession, until end: Double) -> TunerReading? {
        var last: TunerReading?
        samples.withUnsafeBufferPointer { buffer in
            var position = 0
            while position + session.hopSize <= samples.count,
                  Double(position) / testSampleRate < end {
                if let reading = session.process(hop: buffer.baseAddress! + position).reading {
                    last = reading
                }
                position += session.hopSize
            }
        }
        return last
    }

    @Test("A low B on a 5-string bass lands on the right string and cents")
    func fiveStringLowB() throws {
        let tuning = try #require(TuningLibrary.tuning(id: "b5.standard"))
        let settings = TunerSession.Settings(strings: tuning.strings)
        let session = TunerSession(sampleRate: testSampleRate, settings: settings)

        var parameters = PluckSynth.Parameters(frequency: Interval.shift(midiFrequency(23), byCents: -6))
        parameters.inharmonicity = 0.0015
        parameters.decay = 3.5
        parameters.microphoneCorner = 120
        parameters.attackBendCents = 12
        parameters.noiseDB = -62

        let samples = PluckSynth.render(parameters, sampleRate: testSampleRate, duration: 2)
        let reading = try #require(run(samples, session: session, until: 1.5))
        #expect(reading.stringIndex == 0)
        let heard = Interval.cents(heardPitch(parameters, at: 1.4), from: midiFrequency(23))
        #expect(abs(reading.cents - heard) < 3, "read \(reading.cents), heard \(heard)")
    }

    @Test("A detuned guitar string is matched to the string it should be")
    func detunedString() throws {
        let tuning = try #require(TuningLibrary.tuning(id: "g6.standard"))
        let session = TunerSession(sampleRate: testSampleRate, settings: .init(strings: tuning.strings))

        var parameters = PluckSynth.Parameters(frequency: Interval.shift(midiFrequency(45), byCents: -180))
        parameters.inharmonicity = 0.0001
        let samples = PluckSynth.render(parameters, sampleRate: testSampleRate, duration: 2)
        let reading = try #require(run(samples, session: session, until: 1.5))
        #expect(reading.stringIndex == 1)
        #expect(abs(reading.cents + 180) < 2)
    }

    @Test("A string can be tuned to a microtonal custom offset")
    func customOffset() throws {
        let strings = [TuningString(note: Note(midi: 40), cents: 14)]
        let session = TunerSession(sampleRate: testSampleRate, settings: .init(strings: strings))
        var parameters = PluckSynth.Parameters(frequency: Interval.shift(midiFrequency(40), byCents: 14))
        parameters.inharmonicity = 0.0001
        let samples = PluckSynth.render(parameters, sampleRate: testSampleRate, duration: 2)
        let reading = try #require(run(samples, session: session, until: 1.5))
        #expect(abs(reading.cents) < 1)
    }

    @Test("A different reference pitch moves the target")
    func reference() throws {
        let context = PitchContext(a4: 432)
        let tuning = try #require(TuningLibrary.tuning(id: "g6.standard"))
        let session = TunerSession(sampleRate: testSampleRate, settings: .init(context: context, strings: tuning.strings))
        var parameters = PluckSynth.Parameters(frequency: context.frequency(of: Note(midi: 45)))
        parameters.inharmonicity = 0.0001
        let samples = PluckSynth.render(parameters, sampleRate: testSampleRate, duration: 2)
        let reading = try #require(run(samples, session: session, until: 1.5))
        #expect(abs(reading.cents) < 1)
    }

    @Test("The spectrum is only made when asked for")
    func spectrumOnDemand() {
        let session = TunerSession(sampleRate: testSampleRate, settings: .init(wantsSpectrum: true))
        let samples = sine(frequency: 220, duration: 0.5)
        var spectrum: [Float]?
        samples.withUnsafeBufferPointer { buffer in
            var position = 0
            while position + session.hopSize <= samples.count {
                spectrum = session.process(hop: buffer.baseAddress! + position).spectrum
                position += session.hopSize
            }
        }
        #expect(spectrum?.count == PitchEngine.spectrumColumnCount)
        #expect((spectrum?.max() ?? 0) > 0.5)
    }
}

@Suite("Ring buffer")
struct RingBufferTests {
    @Test("Samples survive wrapping around the end")
    func wraparound() {
        let ring = SampleRingBuffer(minimumCapacity: 8)
        var output = [Float](repeating: 0, count: 8)

        for round in 0..<20 {
            let input = (0..<5).map { Float(round * 10 + $0) }
            #expect(ring.write(input, count: 5) == 5)
            #expect(ring.availableToRead == 5)
            #expect(ring.read(into: &output, count: 5) == 5)
            #expect(Array(output.prefix(5)) == input)
        }
    }

    @Test("A full buffer drops the excess instead of overwriting")
    func overflow() {
        let ring = SampleRingBuffer(minimumCapacity: 4)
        let input: [Float] = [1, 2, 3, 4, 5, 6]
        #expect(ring.write(input, count: 6) == 4)
        var output = [Float](repeating: 0, count: 4)
        ring.read(into: &output, count: 4)
        #expect(output == [1, 2, 3, 4])
    }
}
