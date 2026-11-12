import Foundation
import Testing
@testable import TunerCore

@Suite("Notes")
struct NoteTests {
    @Test("Parsing and spelling agree", arguments: [
        ("E2", 40), ("A4", 69), ("B0", 23), ("A0", 21), ("F#1", 30), ("Bb3", 58), ("C-1", 0),
    ])
    func parse(text: String, midi: Int) throws {
        #expect(try #require(Note(text)).midi == midi)
    }

    @Test("Sharps and flats spell the same note")
    func spelling() {
        let note = Note(midi: 63)
        #expect(note.spelled(.sharps).name == "D♯")
        #expect(note.spelled(.flats).name == "E♭")
        #expect(note.spelled(.flats).octave == 4)
    }

    @Test("Low notes get the right octave")
    func lowOctaves() {
        #expect(Note(midi: 23).octave == 0)
        #expect(Note(midi: 11).octave == -1)
    }
}

@Suite("Temperaments")
struct TemperamentTests {
    private func cents(_ temperament: Temperament, _ degree: Int) -> Double {
        temperament.degrees[degree]
    }

    @Test("Published interval sizes match")
    func publishedValues() {
        #expect(abs(cents(.justMajor, 4) - 386.314) < 0.01)
        #expect(abs(cents(.justMajor, 7) - 701.955) < 0.01)
        #expect(abs(cents(.pythagorean, 4) - 407.82) < 0.01)
        #expect(abs(cents(.pythagorean, 1) - 113.685) < 0.01)
        #expect(abs(cents(.quarterCommaMeantone, 4) - 386.314) < 0.01)
        #expect(abs(cents(.quarterCommaMeantone, 7) - 696.578) < 0.01)
        #expect(abs(cents(.werckmeisterIII, 7) - 696.09) < 0.01)
        #expect(abs(cents(.werckmeisterIII, 4) - 390.225) < 0.01)
        #expect(abs(cents(.werckmeisterIII, 1) - 90.225) < 0.01)
        #expect(abs(cents(.kirnbergerIII, 2) - 193.157) < 0.01)
        #expect(abs(cents(.kirnbergerIII, 6) - 590.224) < 0.01)
        #expect(abs(cents(.vallotti, 7) - 698.045) < 0.01)
    }

    @Test("Every temperament starts at zero and rises", arguments: Temperament.builtIn)
    func ordered(temperament: Temperament) {
        #expect(temperament.degrees[0] == 0)
        for index in 1..<12 {
            #expect(temperament.degrees[index] > temperament.degrees[index - 1], "\(temperament.name) \(index)")
        }
        #expect(temperament.degrees[11] < 1200)
    }

    @Test("A stays at the reference in every system and key", arguments: Temperament.builtIn)
    func aStaysPut(temperament: Temperament) {
        for key in 0..<12 {
            let context = PitchContext(a4: 442, temperament: temperament, key: key)
            #expect(abs(context.frequency(of: Note(midi: 69)) - 442) < 1e-9)
        }
    }

    @Test("Equal temperament matches the textbook frequencies")
    func equalFrequencies() {
        let context = PitchContext()
        #expect(abs(context.frequency(of: Note(midi: 40)) - 82.4069) < 0.001)
        #expect(abs(context.frequency(of: Note(midi: 23)) - 30.8677) < 0.001)
    }

    @Test("A just major third above the key is 13.7 cents flat of equal")
    func justThird() {
        // In C, E is 13.686 cents below equal; A is 15.641 below, and A is held fixed.
        let context = PitchContext(temperament: .justMajor, key: 0)
        let offset = Temperament.justMajor.offsetFromEqual(pitchClass: 4, key: 0)
        #expect(abs(offset - (-13.686 + 15.641)) < 0.01)
        let (note, cents) = context.nearest(to: context.frequency(of: Note(midi: 64)))
        #expect(note.midi == 64)
        #expect(abs(cents) < 1e-6)
    }

    @Test("Custom offsets round-trip")
    func customRoundTrip() {
        let offsets: [Double] = [0, -5, 2, 3.5, -1, 0, 7, -2, 1, 0, 4, -3]
        let temperament = Temperament.custom(offsets: offsets)
        for index in 0..<12 {
            #expect(abs(temperament.offsets[index] - offsets[index]) < 1e-9)
        }
    }
}

@Suite("Tunings")
struct TuningTests {
    @Test("No two presets in a section have the same notes")
    func noDuplicates() {
        for family in InstrumentFamily.allCases {
            for section in TuningLibrary.sections(for: family) {
                let notes = section.tunings.map { $0.strings.map(\.note.midi) }
                #expect(Set(notes).count == notes.count, "\(section.id)")
            }
        }
    }

    @Test("A removed preset still loads as its replacement")
    func replacedPreset() throws {
        let tuning = try #require(TuningLibrary.tuning(id: "g6.baritone-b"))
        #expect(tuning.id == "g6.b-standard")
    }

    @Test("Tunings saved without newer fields still load")
    func lenientDecoding() throws {
        let json = #"{"id":"custom.1","name":"Mine","family":"bass","strings":[{"note":{"midi":23}},{"note":{"midi":28},"cents":-3}]}"#
        let tuning = try JSONDecoder().decode(Tuning.self, from: Data(json.utf8))
        #expect(tuning.strings.map(\.note.midi) == [23, 28])
        #expect(tuning.strings.map(\.cents) == [0, -3])
        #expect(tuning.prefersFlats == false)
        #expect(tuning.isCustom)
    }

    @Test("IDs are unique")
    func uniqueIDs() {
        #expect(Set(TuningLibrary.all.map(\.id)).count == TuningLibrary.all.count)
    }

    @Test("Standard tunings have the textbook pitches")
    func standards() throws {
        #expect(try #require(TuningLibrary.tuning(id: "g6.standard")).strings.map(\.note.midi) == [40, 45, 50, 55, 59, 64])
        #expect(try #require(TuningLibrary.tuning(id: "b4.standard")).strings.map(\.note.midi) == [28, 33, 38, 43])
        #expect(try #require(TuningLibrary.tuning(id: "b5.standard")).strings.map(\.note.midi) == [23, 28, 33, 38, 43])
        #expect(try #require(TuningLibrary.tuning(id: "g8.standard")).strings.map(\.note.midi) == [30, 35, 40, 45, 50, 55, 59, 64])
    }

    @Test("Every preset stays in a playable range", arguments: TuningLibrary.all)
    func playable(tuning: Tuning) {
        let lowest = tuning.strings.map(\.note.midi).min() ?? 0
        let highest = tuning.strings.map(\.note.midi).max() ?? 0
        #expect(lowest >= 21)
        #expect(highest <= 67)
    }

    @Test("Flat-named tunings display with flats")
    func flats() throws {
        #expect(try #require(TuningLibrary.tuning(id: "g6.half-down")).noteNames == "E♭ A♭ D♭ G♭ B♭ E♭")
    }

    @Test("Tunings survive saving and loading")
    func codable() throws {
        let original = Tuning(
            id: "x", name: "Mine", family: .bass,
            strings: [TuningString(note: Note(midi: 28), cents: -3.5)],
            isCustom: true
        )
        let decoded = try JSONDecoder().decode(Tuning.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }
}

@Suite("Choosing a target")
struct TargetResolverTests {
    private let guitar = TuningLibrary.defaultTuning.strings

    @Test("Picks the nearest string")
    func nearest() {
        var resolver = TargetResolver(context: PitchContext(), strings: guitar)
        #expect(resolver.resolve(112).target.stringIndex == 1)
    }

    @Test("Sticks to the current string near the midpoint")
    func stringHysteresis() {
        var resolver = TargetResolver(context: PitchContext(), strings: guitar)
        // Halfway between E2 and A2 is 95.2 Hz. Start on E2 and drift just past it.
        _ = resolver.resolve(82.41)
        #expect(resolver.resolve(96).target.stringIndex == 0)
        #expect(resolver.resolve(108).target.stringIndex == 1)
    }

    @Test("A locked string stays the target whatever is played")
    func locked() {
        var resolver = TargetResolver(context: PitchContext(), strings: guitar, lockedString: 5)
        let result = resolver.resolve(82.41)
        #expect(result.target.stringIndex == 5)
        #expect(result.cents < -2000)
    }

    @Test("Chromatic mode holds the note near the boundary")
    func chromaticHysteresis() {
        var resolver = TargetResolver(context: PitchContext(), strings: [])
        _ = resolver.resolve(440)
        let nearBoundary = Interval.shift(440, byCents: 55)
        #expect(resolver.resolve(nearBoundary).target.note.midi == 69)
        let past = Interval.shift(440, byCents: 70)
        #expect(resolver.resolve(past).target.note.midi == 70)
    }
}
