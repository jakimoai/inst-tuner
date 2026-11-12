import Foundation

/// One moment's reading, ready to show.
public struct TunerReading: Sendable, Equatable {
    public var frequency: Double
    public var note: Note
    public var targetFrequency: Double
    public var stringIndex: Int?
    public var cents: Double
    public var isLive: Bool
    public var isSettled: Bool
}

public struct TunerFrame: Sendable {
    public var reading: TunerReading?
    public var levelDB: Double
    public var spectrum: [Float]?
    /// Goes up by one each time a new pluck is heard.
    public var noteCount: Int
}

/// Everything between raw samples and a reading. It isn't thread-safe, so use it from one queue.
public final class TunerSession {
    public struct Settings: Sendable, Equatable {
        public var context: PitchContext
        public var strings: [TuningString]
        public var lockedString: Int?
        public var wantsSpectrum: Bool

        public init(
            context: PitchContext = PitchContext(),
            strings: [TuningString] = [],
            lockedString: Int? = nil,
            wantsSpectrum: Bool = false
        ) {
            self.context = context
            self.strings = strings
            self.lockedString = lockedString
            self.wantsSpectrum = wantsSpectrum
        }
    }

    public var hopSize: Int { engine.hopSize }
    public var frameRate: Double { engine.sampleRate / Double(engine.hopSize) }

    /// Frames per second a session produces at `sampleRate`.
    public static func frameRate(sampleRate: Double) -> Double {
        PitchEngine.frameRate(sampleRate: sampleRate)
    }

    private let engine: PitchEngine
    private var tracker: PitchTracker
    private var resolver: TargetResolver
    private var settings: Settings

    public init(sampleRate: Double, settings: Settings) {
        self.settings = settings
        engine = PitchEngine(sampleRate: sampleRate, configuration: Self.engineConfiguration(settings))
        tracker = PitchTracker(frameRate: engine.sampleRate / Double(engine.hopSize))
        resolver = TargetResolver(
            context: settings.context,
            strings: settings.strings,
            lockedString: settings.lockedString
        )
    }

    public func update(settings newValue: Settings) {
        guard newValue != settings else { return }
        let pitchRulesChanged = newValue.context != settings.context
            || newValue.strings != settings.strings
            || newValue.lockedString != settings.lockedString
        settings = newValue
        engine.configuration = Self.engineConfiguration(newValue)
        guard pitchRulesChanged else { return }

        resolver.context = newValue.context
        resolver.strings = newValue.strings
        resolver.lockedString = newValue.lockedString
        tracker.reset()
    }

    public func reset() {
        engine.reset()
        tracker.reset()
        resolver.clear()
    }

    public func process(hop samples: UnsafePointer<Float>) -> TunerFrame {
        let output = engine.process(hop: samples)
        guard let tracked = tracker.update(output.analysis?.frequency) else {
            resolver.clear()
            return TunerFrame(reading: nil, levelDB: output.levelDB, spectrum: output.spectrum, noteCount: output.noteCount)
        }

        let resolved = resolver.resolve(tracked.frequency)
        let reading = TunerReading(
            frequency: tracked.frequency,
            note: resolved.target.note,
            targetFrequency: resolved.target.frequency,
            stringIndex: resolved.target.stringIndex,
            cents: resolved.cents,
            isLive: tracked.isLive,
            isSettled: tracked.isSettled
        )
        return TunerFrame(reading: reading, levelDB: output.levelDB, spectrum: output.spectrum, noteCount: output.noteCount)
    }

    private static func engineConfiguration(_ settings: Settings) -> PitchEngine.Configuration {
        let frequencies = settings.strings.map { settings.context.frequency(of: $0) }
        var configuration = PitchEngine.Configuration(wantsSpectrum: settings.wantsSpectrum)

        if let lowest = frequencies.min(), let highest = frequencies.max() {
            // Leave room for a slack string, and for fretted notes and harmonics above the top string.
            configuration.minFrequency = max(22, lowest * 0.55)
            configuration.maxFrequency = min(2600, highest * 4.5)
            configuration.stringFrequencies = frequencies
        }
        if let locked = settings.lockedString, frequencies.indices.contains(locked) {
            configuration.lockedFrequency = frequencies[locked]
        }
        return configuration
    }
}
