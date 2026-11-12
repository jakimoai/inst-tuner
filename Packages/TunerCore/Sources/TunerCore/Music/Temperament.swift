import Foundation

/// A 12-note tuning system. `degrees` holds the cents above the key note for each semitone.
public struct Temperament: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var degrees: [Double]

    public init(id: String, name: String, degrees: [Double]) {
        precondition(degrees.count == 12)
        self.id = id
        self.name = name
        self.degrees = degrees
    }

    /// How far `pitchClass` sits from equal temperament in this system and key.
    /// Offsets are shifted so A always stays at the reference pitch.
    public func offsetFromEqual(pitchClass: Int, key: Int) -> Double {
        rawOffset(pitchClass, key: key) - rawOffset(9, key: key)
    }

    private func rawOffset(_ pitchClass: Int, key: Int) -> Double {
        let degree = (((pitchClass - key) % 12) + 12) % 12
        return degrees[degree] - Double(degree) * 100
    }

    /// A user-made temperament from each note's offset from equal temperament, C first.
    public static func custom(offsets: [Double]) -> Temperament {
        precondition(offsets.count == 12)
        return Temperament(
            id: customID,
            name: "Custom",
            degrees: offsets.enumerated().map { Double($0.offset) * 100 + $0.element }
        )
    }

    /// Each note's offset from equal temperament, C first. The inverse of `custom(offsets:)`.
    public var offsets: [Double] {
        degrees.enumerated().map { $0.element - Double($0.offset) * 100 }
    }

    public static let customID = "custom"
}

// MARK: - Built-in systems

extension Temperament {
    private static let pureFifth = 1200 * log2(3.0 / 2.0)
    private static let pythagoreanComma = 1200 * log2(531441.0 / 524288.0)
    private static let syntonicComma = 1200 * log2(81.0 / 80.0)
    private static let schisma = pythagoreanComma - syntonicComma

    public static let equal = Temperament(
        id: "equal",
        name: "Equal",
        degrees: (0..<12).map { Double($0) * 100 }
    )

    public static let justMajor = fromRatios(id: "just-major", name: "Just major", [
        (1, 1), (16, 15), (9, 8), (6, 5), (5, 4), (4, 3),
        (45, 32), (3, 2), (8, 5), (5, 3), (16, 9), (15, 8),
    ])

    public static let justMinor = fromRatios(id: "just-minor", name: "Just minor", [
        (1, 1), (16, 15), (9, 8), (6, 5), (5, 4), (4, 3),
        (45, 32), (3, 2), (8, 5), (5, 3), (9, 5), (15, 8),
    ])

    public static let pythagorean = fromFifths(
        id: "pythagorean", name: "Pythagorean",
        start: 3, Array(repeating: pureFifth, count: 11)
    )

    public static let quarterCommaMeantone = fromFifths(
        id: "meantone-quarter", name: "Quarter-comma meantone",
        start: 3, Array(repeating: pureFifth - syntonicComma / 4, count: 11)
    )

    public static let sixthCommaMeantone = fromFifths(
        id: "meantone-sixth", name: "Sixth-comma meantone",
        start: 3, Array(repeating: pureFifth - syntonicComma / 6, count: 11)
    )

    public static let werckmeisterIII: Temperament = {
        let narrow = pureFifth - pythagoreanComma / 4
        return fromFifths(id: "werckmeister-3", name: "Werckmeister III", start: 0, [
            narrow, narrow, narrow, pureFifth, pureFifth, narrow,
            pureFifth, pureFifth, pureFifth, pureFifth, pureFifth,
        ])
    }()

    public static let kirnbergerIII: Temperament = {
        let narrow = pureFifth - syntonicComma / 4
        return fromFifths(id: "kirnberger-3", name: "Kirnberger III", start: 0, [
            narrow, narrow, narrow, narrow, pureFifth, pureFifth,
            pureFifth - schisma, pureFifth, pureFifth, pureFifth, pureFifth,
        ])
    }()

    public static let vallotti: Temperament = {
        let narrow = pureFifth - pythagoreanComma / 6
        return fromFifths(id: "vallotti", name: "Vallotti", start: 0, [
            narrow, narrow, narrow, narrow, narrow, pureFifth,
            pureFifth, pureFifth, pureFifth, pureFifth, pureFifth,
        ])
    }()

    public static let youngII: Temperament = {
        let narrow = pureFifth - pythagoreanComma / 6
        return fromFifths(id: "young-2", name: "Young II", start: 0, [
            narrow, narrow, narrow, narrow, narrow, narrow,
            pureFifth, pureFifth, pureFifth, pureFifth, pureFifth,
        ])
    }()

    public static let builtIn: [Temperament] = [
        .equal, .justMajor, .justMinor, .pythagorean, .quarterCommaMeantone, .sixthCommaMeantone,
        .werckmeisterIII, .kirnbergerIII, .vallotti, .youngII,
    ]

    private static func fromRatios(id: String, name: String, _ ratios: [(Double, Double)]) -> Temperament {
        Temperament(id: id, name: name, degrees: ratios.map { 1200 * log2($0.0 / $0.1) })
    }

    /// Builds a temperament from a chain of 11 fifths starting at pitch class `start`.
    private static func fromFifths(id: String, name: String, start: Int, _ fifths: [Double]) -> Temperament {
        precondition(fifths.count == 11)
        var positions = Array(repeating: 0.0, count: 12)
        var pitchClass = start
        var position = 0.0
        for fifth in fifths {
            position += fifth
            pitchClass = (pitchClass + 7) % 12
            positions[pitchClass] = position
        }

        let origin = positions[0]
        let degrees = positions.map { value -> Double in
            let shifted = (value - origin).truncatingRemainder(dividingBy: 1200)
            return shifted < 0 ? shifted + 1200 : shifted
        }
        return Temperament(id: id, name: name, degrees: degrees)
    }
}
