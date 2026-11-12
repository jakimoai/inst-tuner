import Accelerate
import Foundation

/// Turns a stream of samples into per-frame pitch measurements.
///
/// Each frame runs three stages:
/// 1. Find the waveform's repeating period (`PeriodDetector`).
/// 2. Decide the correct octave, using the spectrum and the strings being tuned.
/// 3. Measure the overtones precisely and combine them into the pitch the ear hears (`PartialAnalyzer`).
public final class PitchEngine {
    public struct Configuration: Sendable, Equatable {
        public var minFrequency: Double
        public var maxFrequency: Double
        /// Open-string frequencies, used to settle octave doubts. Empty in chromatic mode.
        public var stringFrequencies: [Double]
        /// Set when the player has locked the tuner to one string.
        public var lockedFrequency: Double?
        public var wantsSpectrum: Bool

        public init(
            minFrequency: Double = 24,
            maxFrequency: Double = 2200,
            stringFrequencies: [Double] = [],
            lockedFrequency: Double? = nil,
            wantsSpectrum: Bool = false
        ) {
            self.minFrequency = minFrequency
            self.maxFrequency = maxFrequency
            self.stringFrequencies = stringFrequencies
            self.lockedFrequency = lockedFrequency
            self.wantsSpectrum = wantsSpectrum
        }
    }

    public struct Analysis: Sendable, Equatable {
        public var frequency: Double
        public var clarity: Double
        public var inharmonicity: Double
        public var partialCount: Int
    }

    public struct Output: Sendable {
        public var analysis: Analysis?
        public var levelDB: Double
        public var spectrum: [Float]?
        /// Goes up by one each time a new note starts.
        public var noteCount: Int
    }

    public static let spectrumColumnCount = 128
    public static let spectrumLowFrequency = 25.0
    public static let spectrumHighFrequency = 8000.0

    public let hopSize: Int
    public let sampleRate: Double
    public var configuration: Configuration
    public private(set) var noteCount = 0

    /// Frames per second the engine produces at `sampleRate`.
    public static func frameRate(sampleRate: Double) -> Double {
        sampleRate / Double(analysisSize(sampleRate: sampleRate) / 8)
    }

    private static func analysisSize(sampleRate: Double) -> Int {
        nextPowerOfTwo(atLeast: Int(0.16 * sampleRate))
    }

    private let analysisSize: Int
    private let capacity: Int
    private let history: UnsafeMutablePointer<Float>
    private var filled = 0

    private var previousInput: Float = 0
    private var previousOutput: Float = 0
    private let dcCoefficient: Float

    private let periodDetector: PeriodDetector
    private let partialAnalyzer: PartialAnalyzer
    private let spectrumFFT: RealFFT
    private let spectrumWindow: UnsafeMutablePointer<Float>
    private let spectrumInput: UnsafeMutablePointer<Float>
    private let spectrumReal: UnsafeMutablePointer<Float>
    private let spectrumImag: UnsafeMutablePointer<Float>
    private let spectrumMagnitude: UnsafeMutablePointer<Float>
    private var spectrumReady = false
    private var displayColumns = [Float](repeating: 0, count: PitchEngine.spectrumColumnCount)
    private var peaks: [LagPeak] = []

    private var noiseFloorDB = -75.0
    // A steady hum (mains, a fridge, an amp) is perfectly periodic, so clarity alone can't tell
    // it from a note. A plucked string always fades, so a level that stays flat is background.
    private var flatLow = 0.0
    private var flatHigh = 0.0
    private var flatFrames = 0
    private var stiffness = 0.0
    private var stiffnessFrames = 0
    private var lastFrequency: Double?

    // A plucked string doesn't change octave while it rings, but its overtones take turns being
    // the loudest thing the microphone hears. So the engine decides the octave once, just after
    // the pluck when all the overtones are present, and keeps it until the next pluck.
    private var heldFrequency: Double?
    /// The note held before it faded or broke up without a new pluck. A note that comes back
    /// in the same register is the same string still ringing, so it keeps that octave.
    private var previousHeld: Double?
    private var onsetVotes: [Double] = []
    private var unrelatedFrames = 0
    private var quietFrames = 0
    private var envelopeDB = -100.0
    /// The loudest the current note has been. Its last quiet moments are where octave mistakes
    /// happen, so reading stops once it has faded well below this.
    private var notePeakDB = -100.0

    private let pickThreshold = 0.95
    private let minimumClarity = 0.72
    private let subharmonicRatio = 0.2
    private let gateMarginDB = 5.0
    private let absoluteGateDB = -85.0
    private let onsetRiseDB = 4.0
    private let envelopeDecayPerFrameDB = 0.25
    private let votesNeeded = 10
    private let framesBeforeReleasingNote = 4
    private let quietFramesBeforeReleasingNote = 12
    private let quietFramesBeforeForgettingNote: Int
    private let tailDropDB = 45.0
    private let flatRangeDB = 2.0
    private let flatFramesForBackground: Int
    /// Below this share of odd partials, a period that looks like an octave down is the note
    /// itself with a strong second overtone.
    private let upperOctaveOddShare = 0.15

    public init(sampleRate: Double, configuration: Configuration = Configuration()) {
        self.sampleRate = sampleRate
        self.configuration = configuration

        analysisSize = Self.analysisSize(sampleRate: sampleRate)
        hopSize = analysisSize / 8
        flatFramesForBackground = Int(2.5 * sampleRate / Double(hopSize))
        quietFramesBeforeForgettingNote = Int(sampleRate / Double(hopSize))
        let refineMaximum = analysisSize * 2
        capacity = refineMaximum + refineMaximum / PartialAnalyzer.hopDivisor

        history = .allocate(capacity: capacity)
        history.initialize(repeating: 0, count: capacity)
        dcCoefficient = Float(1 - 2 * Double.pi * 15 / sampleRate)

        periodDetector = PeriodDetector(
            windowSize: analysisSize,
            maxLag: min(analysisSize / 3, Int(sampleRate / 20))
        )
        partialAnalyzer = PartialAnalyzer(
            sampleRate: sampleRate,
            minimumSize: analysisSize / 4,
            maximumSize: refineMaximum
        )

        spectrumFFT = RealFFT(size: analysisSize)
        spectrumWindow = RealFFT.hannWindow(size: analysisSize)
        spectrumInput = .allocate(capacity: analysisSize)
        spectrumReal = .allocate(capacity: analysisSize / 2)
        spectrumImag = .allocate(capacity: analysisSize / 2)
        spectrumMagnitude = .allocate(capacity: analysisSize / 2)
        spectrumMagnitude.initialize(repeating: 0, count: analysisSize / 2)
    }

    deinit {
        history.deallocate()
        spectrumWindow.deallocate()
        spectrumInput.deallocate()
        spectrumReal.deallocate()
        spectrumImag.deallocate()
        spectrumMagnitude.deallocate()
    }

    public func reset() {
        history.update(repeating: 0, count: capacity)
        filled = 0
        previousInput = 0
        previousOutput = 0
        stiffness = 0
        stiffnessFrames = 0
        lastFrequency = nil
        envelopeDB = -100
        notePeakDB = -100
        quietFrames = 0
        flatFrames = 0
        beginNote()
        previousHeld = nil
        displayColumns = [Float](repeating: 0, count: Self.spectrumColumnCount)
    }

    /// Feeds exactly `hopSize` samples and analyses the newest audio.
    public func process(hop samples: UnsafePointer<Float>) -> Output {
        appendFiltered(samples)
        spectrumReady = false

        var meanSquare: Float = 0
        vDSP_measqv(history + capacity - 2 * hopSize, 1, &meanSquare, vDSP_Length(2 * hopSize))
        let levelDB = 10 * log10(Double(meanSquare) + 1e-14)

        detectOnset(levelDB)
        let analysis = isGateOpen(levelDB) ? analyzePitch() : nil
        trackSilence(voiced: analysis != nil)
        updateNoiseFloor(levelDB: levelDB, voiced: (analysis?.clarity ?? 0) >= 0.85)

        var spectrum: [Float]?
        if configuration.wantsSpectrum {
            prepareSpectrum()
            spectrum = displaySpectrum()
        }
        return Output(analysis: analysis, levelDB: levelDB, spectrum: spectrum, noteCount: noteCount)
    }

    // MARK: - Input

    private func appendFiltered(_ samples: UnsafePointer<Float>) {
        memmove(history, history + hopSize, (capacity - hopSize) * MemoryLayout<Float>.stride)
        let destination = history + capacity - hopSize
        for index in 0..<hopSize {
            let input = samples[index]
            let output = input - previousInput + dcCoefficient * previousOutput
            previousInput = input
            previousOutput = output
            destination[index] = output
        }
        filled = min(capacity, filled + hopSize)
    }

    private func isGateOpen(_ levelDB: Double) -> Bool {
        // Reset by every new pluck (`startNewNote`).
        notePeakDB = max(notePeakDB, levelDB)
        let threshold = max(noiseFloorDB + gateMarginDB, absoluteGateDB, notePeakDB - tailDropDB)
        return filled >= analysisSize && levelDB > threshold
    }

    private func updateNoiseFloor(levelDB: Double, voiced: Bool) {
        let isFlat = trackFlatness(levelDB)
        if levelDB < noiseFloorDB {
            noiseFloorDB += (levelDB - noiseFloorDB) * 0.2
        } else if isFlat {
            noiseFloorDB += min(1.0, (levelDB - noiseFloorDB) * 0.2)
        } else if !voiced {
            noiseFloorDB += min(0.05, (levelDB - noiseFloorDB) * 0.02)
        }
        noiseFloorDB = min(max(noiseFloorDB, -100), -35)
    }

    /// True once the level has stayed within a couple of dB for a few seconds.
    private func trackFlatness(_ levelDB: Double) -> Bool {
        if flatFrames == 0 || max(flatHigh, levelDB) - min(flatLow, levelDB) > flatRangeDB {
            flatLow = levelDB
            flatHigh = levelDB
            flatFrames = 1
            return false
        }
        flatLow = min(flatLow, levelDB)
        flatHigh = max(flatHigh, levelDB)
        flatFrames += 1
        return flatFrames >= flatFramesForBackground
    }

    // MARK: - Pitch

    private func analyzePitch() -> Analysis? {
        let window = UnsafePointer(history + capacity - analysisSize)
        periodDetector.compute(window)

        let minimumLag = max(2, Int(sampleRate / configuration.maxFrequency))
        periodDetector.collectPeaks(minLag: minimumLag, into: &peaks)
        let usable = peaks.filter { $0.lag <= sampleRate / configuration.minFrequency }

        guard let highest = usable.map(\.value).max() else { return nil }
        let threshold = highest * pickThreshold
        guard let picked = usable.first(where: { $0.value >= threshold }),
              picked.value >= minimumClarity
        else { return nil }

        prepareSpectrum()
        let coarse = settledFrequency(for: picked)
        return refine(coarse: coarse, clarity: picked.value)
    }

    private func settledFrequency(for peak: LagPeak) -> Double {
        var frequency = sampleRate / peak.lag

        if let held = heldFrequency {
            if let folded = fold(frequency, onto: held) {
                if isNewString(frequency, replacing: held) {
                    startNewNote()
                } else {
                    unrelatedFrames = 0
                    return folded
                }
            } else {
                unrelatedFrames += 1
                if unrelatedFrames >= framesBeforeReleasingNote {
                    beginNote()
                }
            }
        }

        if let upper = upperOctave(of: peak) {
            frequency = upper
        }
        if let lower = subharmonic(of: frequency) {
            frequency = lower
        }
        frequency = applyStringPrior(frequency, clarity: peak.value)
        castVote(frequency)
        return frequency
    }

    /// Just after a pluck, the peak at twice the true period can edge out the true one. If a
    /// nearly-as-strong peak sits at half the lag and the spectrum has almost nothing at the
    /// odd overtones of the lower note, the higher note is the real one.
    private func upperOctave(of peak: LagPeak) -> Double? {
        let half = peak.lag / 2
        guard let upper = peaks.first(where: { abs($0.lag - half) <= 0.03 * half }),
              upper.value >= 0.85 * peak.value
        else { return nil }

        let frequency = sampleRate / upper.lag
        guard frequency <= configuration.maxFrequency else { return nil }

        var main = 0.0
        for multiple in 1...4 {
            main += spectralPeak(near: frequency * Double(multiple))
        }
        guard main > 0 else { return nil }
        var odd = 0.0
        for multiple in stride(from: 1, through: 7, by: 2) {
            odd += spectralPeak(near: frequency / 2 * Double(multiple))
        }
        return odd / main < upperOctaveOddShare ? frequency : nil
    }

    /// In tuning mode, a quieter pluck on another string may not register as an onset, and if
    /// it lands on an overtone of the held note (high E over low E) it would fold onto it.
    /// It's a new string once the pitch sits on that string and the held note's own overtones,
    /// the ones the new note doesn't share, have gone.
    private func isNewString(_ frequency: Double, replacing held: Double) -> Bool {
        guard configuration.lockedFrequency == nil else { return false }
        let strings = configuration.stringFrequencies
        let multiple = (frequency / held).rounded()
        guard multiple >= 2,
              let target = strings.min(by: { abs(Interval.cents(frequency, from: $0)) < abs(Interval.cents(frequency, from: $1)) }),
              abs(Interval.cents(frequency, from: target)) <= 50,
              let heldString = strings.min(by: { abs(Interval.cents(held, from: $0)) < abs(Interval.cents(held, from: $1)) }),
              abs(Interval.cents(target, from: heldString)) > 50
        else { return false }

        var shared = 0.0
        for harmonic in 1...4 {
            shared += spectralPeak(near: frequency * Double(harmonic))
        }
        guard shared > 0 else { return false }

        var own = 0.0
        let partialMultiple = Int(multiple)
        for partial in 1...8 where partial % partialMultiple != 0 {
            let partialFrequency = held * Double(partial)
            guard partialFrequency < sampleRate * 0.45 else { break }
            own += spectralPeak(near: partialFrequency)
        }
        return own < 0.1 * shared
    }

    /// If `frequency` is an overtone or undertone of the held note, returns it in the held
    /// note's register. Returns nil if it's unrelated.
    private func fold(_ frequency: Double, onto held: Double) -> Double? {
        let tolerance = 90.0
        if abs(Interval.cents(frequency, from: held)) <= tolerance { return frequency }

        for multiple in 2...6 {
            let candidate = frequency / Double(multiple)
            if abs(Interval.cents(candidate, from: held)) <= tolerance { return candidate }
        }
        for divisor in 2...3 {
            let candidate = frequency * Double(divisor)
            if abs(Interval.cents(candidate, from: held)) <= tolerance { return candidate }
        }
        return nil
    }

    /// A strong even overtone can look like the fundamental. Several odd overtones of the note an
    /// octave down show that the lower note is the real one. One stray peak isn't enough, because
    /// other open strings vibrate along with the one played.
    private func subharmonic(of frequency: Double) -> Double? {
        let candidate = frequency / 2
        guard candidate >= configuration.minFrequency else { return nil }

        var main = 0.0
        for multiple in 1...4 {
            main += spectralPeak(near: frequency * Double(multiple))
        }
        guard main > 0 else { return nil }

        var odd = 0.0
        var oddCount = 0
        for multiple in stride(from: 1, through: 7, by: 2) {
            let height = spectralPeak(near: candidate * Double(multiple))
            if height >= 0.06 * main {
                odd += height
                oddCount += 1
            }
        }
        return oddCount >= 2 && odd >= subharmonicRatio * main ? candidate : nil
    }

    // MARK: - Holding a note

    private func detectOnset(_ levelDB: Double) {
        if levelDB > envelopeDB + onsetRiseDB, levelDB > max(noiseFloorDB + gateMarginDB, absoluteGateDB) {
            startNewNote()
        }
        envelopeDB = max(levelDB, envelopeDB - envelopeDecayPerFrameDB)
    }

    /// Starts a new note and decides its octave from scratch.
    private func startNewNote() {
        notePeakDB = -100
        heldFrequency = nil
        previousHeld = nil
        beginNote()
        noteCount &+= 1
    }

    private func trackSilence(voiced: Bool) {
        quietFrames = voiced ? 0 : quietFrames + 1
        if quietFrames >= quietFramesBeforeReleasingNote {
            beginNote()
        }
        // After a real silence, whatever comes next is a new note.
        if quietFrames >= quietFramesBeforeForgettingNote {
            previousHeld = nil
        }
    }

    private func beginNote() {
        if let heldFrequency { previousHeld = heldFrequency }
        heldFrequency = nil
        onsetVotes.removeAll(keepingCapacity: true)
        unrelatedFrames = 0
    }

    private func castVote(_ frequency: Double) {
        guard heldFrequency == nil else { return }
        onsetVotes.append(frequency)
        guard onsetVotes.count >= votesNeeded else { return }
        heldFrequency = winningVote().map { winner in
            guard let previousHeld,
                  let folded = octave(of: winner, nearest: previousHeld),
                  !isNewString(winner, replacing: previousHeld)
            else { return winner }
            return folded
        }
        onsetVotes.removeAll(keepingCapacity: true)
    }

    /// `frequency` moved into the octave of `reference`, if it's the same pitch class.
    private func octave(of frequency: Double, nearest reference: Double) -> Double? {
        for factor in [1.0, 2, 0.5, 4, 0.25] {
            let candidate = frequency * factor
            if abs(Interval.cents(candidate, from: reference)) <= 90 { return candidate }
        }
        return nil
    }

    /// Finds the pitch class most votes agree on, then the lowest octave with real support.
    private func winningVote() -> Double? {
        func samePitchClass(_ a: Double, _ b: Double) -> Bool {
            let distance = abs(Interval.cents(a, from: b)).truncatingRemainder(dividingBy: 1200)
            return min(distance, 1200 - distance) <= 60
        }

        var bestGroup: [Double] = []
        for vote in onsetVotes {
            let group = onsetVotes.filter { samePitchClass($0, vote) }
            if group.count > bestGroup.count { bestGroup = group }
        }
        guard bestGroup.count >= votesNeeded / 2 else { return nil }

        let sorted = bestGroup.sorted()
        let required = max(2, Int((Double(bestGroup.count) * 0.3).rounded(.up)))
        for vote in sorted {
            let sameOctave = sorted.filter { abs(Interval.cents($0, from: vote)) <= 100 }
            if sameOctave.count >= required {
                return sameOctave[sameOctave.count / 2]
            }
        }
        return sorted[sorted.count / 2]
    }

    /// The player is tuning open strings, so a pitch that matches a string an octave down is
    /// far more likely than one that matches nothing.
    private func applyStringPrior(_ frequency: Double, clarity: Double) -> Double {
        if let locked = configuration.lockedFrequency {
            let candidates = [frequency / 3, frequency / 2, frequency, frequency * 2]
            return candidates.min {
                abs(Interval.cents($0, from: locked)) < abs(Interval.cents($1, from: locked))
            } ?? frequency
        }

        let strings = configuration.stringFrequencies
        guard !strings.isEmpty else { return frequency }
        if strings.contains(where: { abs(Interval.cents(frequency, from: $0)) <= 150 }) {
            return frequency
        }

        for divisor in [2.0, 3.0] {
            let candidate = frequency / divisor
            guard candidate >= configuration.minFrequency,
                  strings.contains(where: { abs(Interval.cents(candidate, from: $0)) <= 60 })
            else { continue }
            if periodDetector.value(near: sampleRate / candidate, tolerance: 3) >= clarity - 0.1 {
                return candidate
            }
        }
        return frequency
    }

    private func refine(coarse: Double, clarity: Double) -> Analysis? {
        if let lastFrequency, abs(Interval.cents(coarse, from: lastFrequency)) > 80 {
            stiffness = 0
            stiffnessFrames = 0
        }

        var frequency = coarse
        var partialCount = 0
        if let partials = partialAnalyzer.analyze(
            end: history + capacity,
            available: filled,
            coarseFrequency: coarse,
            stiffnessGuess: stiffness
        ) {
            if let measured = partials.inharmonicity {
                stiffnessFrames = min(stiffnessFrames + 1, 40)
                stiffness += (measured - stiffness) / Double(stiffnessFrames)
            }
            let refined = partials.heardPitch
            if abs(Interval.cents(refined, from: coarse)) < 130 {
                frequency = refined
                partialCount = partials.partials.count
            }
        }

        guard frequency >= configuration.minFrequency * 0.9,
              frequency <= configuration.maxFrequency * 1.1
        else { return nil }

        lastFrequency = frequency
        if let held = heldFrequency, abs(Interval.cents(frequency, from: held)) <= 130 {
            heldFrequency = frequency
        }
        return Analysis(
            frequency: frequency,
            clarity: clarity,
            inharmonicity: stiffness,
            partialCount: partialCount
        )
    }

    // MARK: - Spectrum

    private func prepareSpectrum() {
        guard !spectrumReady else { return }
        vDSP_vmul(
            history + capacity - analysisSize, 1,
            spectrumWindow, 1,
            spectrumInput, 1,
            vDSP_Length(analysisSize)
        )
        spectrumFFT.forward(spectrumInput, real: spectrumReal, imag: spectrumImag)
        spectrumFFT.magnitudes(real: spectrumReal, imag: spectrumImag, into: spectrumMagnitude)
        spectrumReady = true
    }

    /// The height of a true spectral peak near `frequency`, or zero if there isn't one.
    private func spectralPeak(near frequency: Double) -> Double {
        let binWidth = sampleRate / Double(analysisSize)
        let centre = frequency / binWidth
        let tolerance = max(1.2, frequency * 0.03 / binWidth)
        let low = max(2, Int((centre - tolerance).rounded(.down)))
        let high = min(analysisSize / 2 - 2, Int((centre + tolerance).rounded(.up)))
        guard low <= high else { return 0 }

        var best: Float = 0
        for bin in low...high
        where spectrumMagnitude[bin] > best
            && spectrumMagnitude[bin] > spectrumMagnitude[bin - 1]
            && spectrumMagnitude[bin] >= spectrumMagnitude[bin + 1] {
            best = spectrumMagnitude[bin]
        }
        return Double(best)
    }

    private func displaySpectrum() -> [Float] {
        let binWidth = sampleRate / Double(analysisSize)
        let ratio = log(Self.spectrumHighFrequency / Self.spectrumLowFrequency)
        let fullScale = Float(analysisSize) / 2
        let count = Self.spectrumColumnCount

        for column in 0..<count {
            let lowFrequency = Self.spectrumLowFrequency * exp(ratio * Double(column) / Double(count))
            let highFrequency = Self.spectrumLowFrequency * exp(ratio * Double(column + 1) / Double(count))
            let lastBin = analysisSize / 2 - 1
            let lowBin = min(max(1, Int(lowFrequency / binWidth)), lastBin)
            let highBin = max(lowBin, min(lastBin, Int(highFrequency / binWidth)))

            var peak: Float = 0
            vDSP_maxv(spectrumMagnitude + lowBin, 1, &peak, vDSP_Length(highBin - lowBin + 1))

            let decibels = 20 * log10(peak / fullScale + 1e-7)
            let height = min(max((decibels + 90) / 80, 0), 1)
            displayColumns[column] = max(height, displayColumns[column] * 0.86)
        }
        return displayColumns
    }
}
