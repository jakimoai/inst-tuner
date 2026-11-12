import Foundation

public enum AccidentalStyle: String, Codable, CaseIterable, Sendable {
    case sharps
    case flats
}

/// A note spelled for display.
public struct SpelledNote: Hashable, Sendable {
    public var letter: String
    /// "", "♯" or "♭".
    public var accidental: String
    public var octave: Int

    public var name: String { letter + accidental }
}

/// A chromatic note, stored as a MIDI number (A4 = 69).
public struct Note: Hashable, Codable, Sendable, Comparable {
    public var midi: Int

    public init(midi: Int) {
        self.midi = midi
    }

    /// Parses scientific pitch notation such as "E2", "F#1" or "Bb0".
    public init?(_ text: String) {
        var characters = Array(text)
        guard let first = characters.first, let base = Note.letterOffsets[first] else { return nil }
        characters.removeFirst()

        var accidental = 0
        while let character = characters.first, character == "#" || character == "b" {
            accidental += character == "#" ? 1 : -1
            characters.removeFirst()
        }

        guard let octave = Int(String(characters)) else { return nil }
        midi = (octave + 1) * 12 + base + accidental
    }

    public var pitchClass: Int { ((midi % 12) + 12) % 12 }
    public var octave: Int { Int((Double(midi) / 12).rounded(.down)) - 1 }

    public func spelled(_ style: AccidentalStyle) -> SpelledNote {
        let parts = Note.spellings(style)[pitchClass]
        return SpelledNote(letter: parts.0, accidental: parts.1, octave: octave)
    }

    public static func < (lhs: Note, rhs: Note) -> Bool { lhs.midi < rhs.midi }

    public static func pitchClassName(_ pitchClass: Int, style: AccidentalStyle) -> String {
        let parts = spellings(style)[((pitchClass % 12) + 12) % 12]
        return parts.0 + parts.1
    }

    private static let letterOffsets: [Character: Int] = [
        "C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11,
    ]

    private static func spellings(_ style: AccidentalStyle) -> [(String, String)] {
        switch style {
        case .sharps:
            [("C", ""), ("C", "♯"), ("D", ""), ("D", "♯"), ("E", ""), ("F", ""),
             ("F", "♯"), ("G", ""), ("G", "♯"), ("A", ""), ("A", "♯"), ("B", "")]
        case .flats:
            [("C", ""), ("D", "♭"), ("D", ""), ("E", "♭"), ("E", ""), ("F", ""),
             ("G", "♭"), ("G", ""), ("A", "♭"), ("A", ""), ("B", "♭"), ("B", "")]
        }
    }
}

public enum Interval {
    /// Distance from `reference` to `frequency` in cents.
    public static func cents(_ frequency: Double, from reference: Double) -> Double {
        1200 * log2(frequency / reference)
    }

    public static func shift(_ frequency: Double, byCents cents: Double) -> Double {
        frequency * pow(2, cents / 1200)
    }
}
