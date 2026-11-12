import Foundation
import TunerCore

enum ReadoutMode: String, Codable, CaseIterable, Identifiable {
    case needle, strobe, trace, spectrum

    var id: String { rawValue }

    var title: String {
        switch self {
        case .needle: "Needle"
        case .strobe: "Strobe"
        case .trace: "Trace"
        case .spectrum: "Spectrum"
        }
    }
}

/// Everything the player can change. Saved between launches.
struct TunerSettings: Codable, Equatable {
    static let chromaticID = "chromatic"
    private static let storageKey = "tuner.settings.v1"

    var selectedTuningID = TuningLibrary.defaultTuning.id
    var customTunings: [Tuning] = []
    var a4 = 440.0
    var temperamentID = Temperament.equal.id
    var customTemperamentOffsets = [Double](repeating: 0, count: 12)
    var key = 0
    var toleranceCents = 2.0
    var accidentals = AccidentalStyle.sharps
    var hapticsEnabled = true
    var readout = ReadoutMode.needle
    /// The instrument the tuning list opens on when chromatic mode gives no hint.
    var lastFamily = InstrumentFamily.guitar

    var tuning: Tuning? {
        guard selectedTuningID != Self.chromaticID else { return nil }
        return customTunings.first { $0.id == selectedTuningID }
            ?? TuningLibrary.tuning(id: selectedTuningID)
            ?? TuningLibrary.defaultTuning
    }

    var temperament: Temperament {
        if temperamentID == Temperament.customID {
            return .custom(offsets: customTemperamentOffsets)
        }
        return Temperament.builtIn.first { $0.id == temperamentID } ?? .equal
    }

    var context: PitchContext {
        // Custom offsets are entered per note name, so they don't move with a key.
        let key = temperamentID == Temperament.customID ? 0 : key
        return PitchContext(a4: a4, temperament: temperament, key: key)
    }

    var noteStyle: AccidentalStyle {
        tuning?.prefersFlats == true ? .flats : accidentals
    }

    static func load() -> TunerSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode(TunerSettings.self, from: data)
        else { return TunerSettings() }
        return saved
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}

extension TunerSettings {
    /// Reads whatever was saved, field by field. A field that's missing (saved by an older
    /// version) or unreadable falls back to its default instead of losing everything else.
    init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, or fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }

        selectedTuningID = TuningLibrary.canonicalID(value(.selectedTuningID, or: selectedTuningID))
        customTunings = value(.customTunings, or: [Lossy<Tuning>]())
            .compactMap(\.value)
            .filter { !$0.strings.isEmpty }
        a4 = min(max(value(.a4, or: a4), 390), 490)
        temperamentID = value(.temperamentID, or: temperamentID)
        key = value(.key, or: key)
        toleranceCents = value(.toleranceCents, or: toleranceCents)
        accidentals = value(.accidentals, or: accidentals)
        hapticsEnabled = value(.hapticsEnabled, or: hapticsEnabled)
        readout = value(.readout, or: readout)
        lastFamily = value(.lastFamily, or: lastFamily)

        let offsets = value(.customTemperamentOffsets, or: customTemperamentOffsets)
        if offsets.count == 12 {
            // A is the reference, so its offset is always zero.
            customTemperamentOffsets = offsets.map { $0 - offsets[9] }
        }
        if !(0..<12).contains(key) { key = 0 }
        if !(toleranceCents > 0) { toleranceCents = 2 }
    }
}

/// Decodes an array element by element, skipping any that can't be read.
private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}
