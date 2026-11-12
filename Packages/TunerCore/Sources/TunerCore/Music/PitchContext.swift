import Foundation

/// The reference pitch and tuning system every reading is measured against.
public struct PitchContext: Hashable, Codable, Sendable {
    public var a4: Double
    public var temperament: Temperament
    /// Pitch class of the key the temperament is centred on.
    public var key: Int

    public init(a4: Double = 440, temperament: Temperament = .equal, key: Int = 0) {
        self.a4 = a4
        self.temperament = temperament
        self.key = key
    }

    public func frequency(of note: Note, centsOffset: Double = 0) -> Double {
        let equalCents = Double(note.midi - 69) * 100
        let temperamentCents = temperament.offsetFromEqual(pitchClass: note.pitchClass, key: key)
        return a4 * pow(2, (equalCents + temperamentCents + centsOffset) / 1200)
    }

    public func frequency(of string: TuningString) -> Double {
        frequency(of: string.note, centsOffset: string.cents)
    }

    /// The closest note in this system, and how far `frequency` sits from it.
    public func nearest(to frequency: Double) -> (note: Note, cents: Double) {
        let estimate = 69 + 12 * log2(frequency / a4)
        let centre = Int(estimate.rounded())

        var best = Note(midi: centre)
        var bestCents = Interval.cents(frequency, from: self.frequency(of: best))
        for midi in [centre - 1, centre + 1] {
            let candidate = Note(midi: midi)
            let cents = Interval.cents(frequency, from: self.frequency(of: candidate))
            if abs(cents) < abs(bestCents) {
                best = candidate
                bestCents = cents
            }
        }
        return (best, bestCents)
    }
}

/// What a reading is being measured against.
public struct TuningTarget: Hashable, Sendable {
    public var note: Note
    public var frequency: Double
    /// Index into the tuning's strings. Nil in chromatic mode.
    public var stringIndex: Int?
}

/// Decides which note or string a pitch belongs to, without flickering between neighbours.
public struct TargetResolver: Sendable {
    public var context: PitchContext {
        didSet { current = nil }
    }
    public var strings: [TuningString] {
        didSet { current = nil }
    }
    public var lockedString: Int? {
        didSet { current = nil }
    }

    private var current: TuningTarget?

    /// How much closer another string must be, in cents, before the reading moves to it.
    private let stringMargin = 40.0
    /// How far past the halfway point between notes a reading may go before it changes note.
    private let noteMargin = 10.0

    public init(context: PitchContext, strings: [TuningString], lockedString: Int? = nil) {
        self.context = context
        self.strings = strings
        self.lockedString = lockedString
    }

    public mutating func clear() {
        current = nil
    }

    public mutating func resolve(_ frequency: Double) -> (target: TuningTarget, cents: Double) {
        let target = strings.isEmpty ? chromaticTarget(frequency) : stringTarget(frequency)
        current = target
        return (target, Interval.cents(frequency, from: target.frequency))
    }

    private func chromaticTarget(_ frequency: Double) -> TuningTarget {
        if let current, abs(Interval.cents(frequency, from: current.frequency)) <= 50 + noteMargin {
            return current
        }
        let nearest = context.nearest(to: frequency)
        return TuningTarget(
            note: nearest.note,
            frequency: context.frequency(of: nearest.note),
            stringIndex: nil
        )
    }

    private func stringTarget(_ frequency: Double) -> TuningTarget {
        if let lockedString, strings.indices.contains(lockedString) {
            return target(forString: lockedString)
        }

        var bestIndex = 0
        var bestCents = Double.infinity
        for index in strings.indices {
            let cents = abs(Interval.cents(frequency, from: context.frequency(of: strings[index])))
            if cents < bestCents {
                bestCents = cents
                bestIndex = index
            }
        }

        if let current, let currentIndex = current.stringIndex, currentIndex != bestIndex {
            let currentCents = abs(Interval.cents(frequency, from: current.frequency))
            if currentCents < bestCents + stringMargin {
                return current
            }
        }
        return target(forString: bestIndex)
    }

    private func target(forString index: Int) -> TuningTarget {
        TuningTarget(
            note: strings[index].note,
            frequency: context.frequency(of: strings[index]),
            stringIndex: index
        )
    }
}
