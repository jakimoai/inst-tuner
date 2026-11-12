import Foundation

public enum InstrumentFamily: String, Codable, Hashable, CaseIterable, Sendable {
    case guitar
    case bass

    public var name: String {
        switch self {
        case .guitar: "Guitar"
        case .bass: "Bass"
        }
    }
}

public struct TuningString: Hashable, Codable, Sendable {
    public var note: Note
    /// Fine offset from the note, in cents. Lets a string sit between notes.
    public var cents: Double

    public init(note: Note, cents: Double = 0) {
        self.note = note
        self.cents = cents
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        note = try container.decode(Note.self, forKey: .note)
        cents = try container.decodeIfPresent(Double.self, forKey: .cents) ?? 0
    }
}

/// A set of open-string pitches, lowest string first.
public struct Tuning: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var family: InstrumentFamily
    public var strings: [TuningString]
    public var prefersFlats: Bool
    public var isCustom: Bool

    public init(
        id: String,
        name: String,
        family: InstrumentFamily,
        strings: [TuningString],
        prefersFlats: Bool = false,
        isCustom: Bool = false
    ) {
        self.id = id
        self.name = name
        self.family = family
        self.strings = strings
        self.prefersFlats = prefersFlats
        self.isCustom = isCustom
    }

    /// Fields added after the first release are optional, so saved tunings keep loading.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        family = try container.decodeIfPresent(InstrumentFamily.self, forKey: .family) ?? .guitar
        strings = try container.decode([TuningString].self, forKey: .strings)
        prefersFlats = try container.decodeIfPresent(Bool.self, forKey: .prefersFlats) ?? false
        isCustom = try container.decodeIfPresent(Bool.self, forKey: .isCustom) ?? true
    }

    public var noteNames: String {
        strings.map { $0.note.spelled(prefersFlats ? .flats : .sharps).name }.joined(separator: " ")
    }
}

public struct TuningSection: Identifiable, Sendable {
    public var family: InstrumentFamily
    public var stringCount: Int
    public var tunings: [Tuning]

    public var id: String { "\(family.rawValue)-\(stringCount)" }
    public var title: String { "\(stringCount) strings" }
}

public enum TuningLibrary {
    public static let all: [Tuning] = guitar6 + guitar7 + guitar8 + bass4 + bass5 + bass6

    public static let defaultTuning = guitar6[0]

    public static func tuning(id: String) -> Tuning? {
        let id = canonicalID(id)
        return all.first { $0.id == id }
    }

    /// Presets that were removed or renamed, mapped to what replaced them.
    private static let replacedIDs = ["g6.baritone-b": "g6.b-standard"]

    public static func canonicalID(_ id: String) -> String {
        replacedIDs[id] ?? id
    }

    public static func sections(for family: InstrumentFamily) -> [TuningSection] {
        let tunings = all.filter { $0.family == family }
        let counts = Array(Set(tunings.map(\.strings.count))).sorted()
        return counts.map { count in
            TuningSection(
                family: family,
                stringCount: count,
                tunings: tunings.filter { $0.strings.count == count }
            )
        }
    }

    private static func make(_ id: String, _ name: String, _ family: InstrumentFamily, _ notes: String) -> Tuning {
        let names = notes.split(separator: " ").map(String.init)
        let strings = names.map { name -> TuningString in
            guard let note = Note(name) else { preconditionFailure("Bad note in tuning table: \(name)") }
            return TuningString(note: note)
        }
        return Tuning(
            id: id,
            name: name,
            family: family,
            strings: strings,
            prefersFlats: names.contains { $0.dropFirst().first == "b" }
        )
    }

    private static let guitar6: [Tuning] = [
        make("g6.standard", "Standard", .guitar, "E2 A2 D3 G3 B3 E4"),
        make("g6.half-down", "Half step down", .guitar, "Eb2 Ab2 Db3 Gb3 Bb3 Eb4"),
        make("g6.whole-down", "Whole step down", .guitar, "D2 G2 C3 F3 A3 D4"),
        make("g6.c-standard", "C standard", .guitar, "C2 F2 Bb2 Eb3 G3 C4"),
        make("g6.b-standard", "B standard", .guitar, "B1 E2 A2 D3 F#3 B3"),
        make("g6.drop-d", "Drop D", .guitar, "D2 A2 D3 G3 B3 E4"),
        make("g6.drop-db", "Drop D♭", .guitar, "Db2 Ab2 Db3 Gb3 Bb3 Eb4"),
        make("g6.drop-c", "Drop C", .guitar, "C2 G2 C3 F3 A3 D4"),
        make("g6.drop-b", "Drop B", .guitar, "B1 F#2 B2 E3 G#3 C#4"),
        make("g6.drop-a", "Drop A", .guitar, "A1 E2 A2 D3 F#3 B3"),
        make("g6.dadgad", "DADGAD", .guitar, "D2 A2 D3 G3 A3 D4"),
        make("g6.open-g", "Open G", .guitar, "D2 G2 D3 G3 B3 D4"),
        make("g6.open-d", "Open D", .guitar, "D2 A2 D3 F#3 A3 D4"),
        make("g6.open-e", "Open E", .guitar, "E2 B2 E3 G#3 B3 E4"),
        make("g6.open-a", "Open A", .guitar, "E2 A2 E3 A3 C#4 E4"),
        make("g6.open-c", "Open C", .guitar, "C2 G2 C3 G3 C4 E4"),
        make("g6.open-dm", "Open D minor", .guitar, "D2 A2 D3 F3 A3 D4"),
        make("g6.c6", "C6", .guitar, "C2 A2 C3 G3 C4 E4"),
        make("g6.all-fourths", "All fourths", .guitar, "E2 A2 D3 G3 C4 F4"),
        make("g6.new-standard", "New standard", .guitar, "C2 G2 D3 A3 E4 G4"),
        make("g6.nashville", "Nashville high-strung", .guitar, "E3 A3 D4 G4 B3 E4"),
        make("g6.baritone-a", "Baritone A", .guitar, "A1 D2 G2 C3 E3 A3"),
    ]

    private static let guitar7: [Tuning] = [
        make("g7.standard", "Standard", .guitar, "B1 E2 A2 D3 G3 B3 E4"),
        make("g7.drop-a", "Drop A", .guitar, "A1 E2 A2 D3 G3 B3 E4"),
        make("g7.half-down", "Half step down", .guitar, "Bb1 Eb2 Ab2 Db3 Gb3 Bb3 Eb4"),
        make("g7.whole-down", "Whole step down", .guitar, "A1 D2 G2 C3 F3 A3 D4"),
        make("g7.drop-g", "Drop G", .guitar, "G1 D2 G2 C3 F3 A3 D4"),
    ]

    private static let guitar8: [Tuning] = [
        make("g8.standard", "Standard", .guitar, "F#1 B1 E2 A2 D3 G3 B3 E4"),
        make("g8.drop-e", "Drop E", .guitar, "E1 B1 E2 A2 D3 G3 B3 E4"),
        make("g8.half-down", "Half step down", .guitar, "F1 Bb1 Eb2 Ab2 Db3 Gb3 Bb3 Eb4"),
    ]

    private static let bass4: [Tuning] = [
        make("b4.standard", "Standard", .bass, "E1 A1 D2 G2"),
        make("b4.half-down", "Half step down", .bass, "Eb1 Ab1 Db2 Gb2"),
        make("b4.whole-down", "Whole step down", .bass, "D1 G1 C2 F2"),
        make("b4.drop-d", "Drop D", .bass, "D1 A1 D2 G2"),
        make("b4.drop-c", "Drop C", .bass, "C1 G1 C2 F2"),
        make("b4.bead", "BEAD", .bass, "B0 E1 A1 D2"),
        make("b4.tenor", "Tenor", .bass, "A1 D2 G2 C3"),
        make("b4.piccolo", "Piccolo", .bass, "E2 A2 D3 G3"),
    ]

    private static let bass5: [Tuning] = [
        make("b5.standard", "Standard", .bass, "B0 E1 A1 D2 G2"),
        make("b5.high-c", "High C", .bass, "E1 A1 D2 G2 C3"),
        make("b5.half-down", "Half step down", .bass, "Bb0 Eb1 Ab1 Db2 Gb2"),
        make("b5.whole-down", "Whole step down", .bass, "A0 D1 G1 C2 F2"),
        make("b5.drop-a", "Drop A", .bass, "A0 E1 A1 D2 G2"),
    ]

    private static let bass6: [Tuning] = [
        make("b6.standard", "Standard", .bass, "B0 E1 A1 D2 G2 C3"),
        make("b6.half-down", "Half step down", .bass, "Bb0 Eb1 Ab1 Db2 Gb2 B2"),
        make("b6.drop-a", "Drop A", .bass, "A0 E1 A1 D2 G2 C3"),
    ]
}
