import Foundation
import Observation
import TunerCore

/// A rolling history of cents readings for the trace view. NaN marks a gap with no signal.
struct PitchTrace {
    static let capacity = 360

    private var values = [Float](repeating: .nan, count: PitchTrace.capacity)
    private var head = 0

    mutating func append(_ cents: Double?) {
        values[head] = cents.map(Float.init) ?? .nan
        head = (head + 1) % Self.capacity
    }

    /// Value `age` frames ago, where 0 is the newest.
    func value(age: Int) -> Float {
        values[(head - 1 - age + 2 * Self.capacity) % Self.capacity]
    }
}

/// Values that change on every audio frame. Kept apart from the settings, and only written
/// when they differ, so each view redraws only for what it actually shows.
@MainActor
@Observable
final class LiveTuner {
    private(set) var note: SpelledNote?
    private(set) var cents = 0.0
    private(set) var frequency: Double?
    private(set) var stringIndex: Int?
    private(set) var isLive = false
    private(set) var isInTune = false
    /// 1 when dead on, falling towards 0 as the pitch moves away.
    private(set) var closeness = 0.0
    /// Input level from 0 (silence) to 1 (loud).
    private(set) var level = 0.0
    private(set) var spectrum: [Float] = []
    private(set) var trace = PitchTrace()
    /// Goes up by one each time a string comes into tune.
    private(set) var inTuneEvents = 0

    func apply(_ frame: TunerFrame, inTune: Bool, justTuned: Bool, style: AccidentalStyle) {
        let reading = frame.reading

        let spelled = reading?.note.spelled(style)
        if note != spelled { note = spelled }
        if let reading {
            cents = reading.cents
            frequency = reading.frequency
        } else if frequency != nil {
            frequency = nil
        }

        let string = reading?.stringIndex
        if stringIndex != string { stringIndex = string }

        let live = reading?.isLive ?? false
        if isLive != live { isLive = live }
        if isInTune != inTune { isInTune = inTune }

        let target = Self.closeness(reading)
        if abs(closeness - target) > 0.005 { closeness = target }

        let newLevel = min(max((frame.levelDB + 70) / 50, 0), 1)
        if abs(level - newLevel) > 0.01 { level = newLevel }
        if let columns = frame.spectrum { spectrum = columns }
        trace.append(live ? reading?.cents : nil)
        if justTuned { inTuneEvents += 1 }
    }

    func clear() {
        note = nil
        cents = 0
        frequency = nil
        stringIndex = nil
        isLive = false
        isInTune = false
        closeness = 0
        level = 0
        spectrum = []
    }

    private static func closeness(_ reading: TunerReading?) -> Double {
        guard let reading else { return 0 }
        let value = exp(-pow(abs(reading.cents) / 14, 1.3))
        return reading.isLive ? value : value * 0.3
    }
}
