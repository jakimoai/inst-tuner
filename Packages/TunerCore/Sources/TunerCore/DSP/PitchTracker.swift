import Foundation

/// Turns noisy per-frame measurements into one steady reading.
/// Single-frame glitches are ignored, real note changes are followed quickly, and the last
/// reading is held briefly after a note dies so it can still be read.
public struct PitchTracker: Sendable {
    public struct Reading: Sendable, Equatable {
        public var frequency: Double
        /// False while the last reading is being held after the note has stopped.
        public var isLive: Bool
        /// True when the pitch has stopped moving.
        public var isSettled: Bool
    }

    private let frameRate: Double
    private let holdFrames: Int
    /// A note can drop out for a frame or two as it fades. Gaps this short don't count.
    private let gapFrames = 3
    private let startFrames = 3
    private let jumpFrames = 3
    private let octaveJumpFrames = 7
    private let jumpCents = 50.0
    private let agreementCents = 30.0

    private var smoothed: Double?
    private var filter: OneEuroFilter
    private var pending: [Double] = []
    private var medianWindow: [Double] = []
    private var settleWindow: [Double] = []
    private var quietFrames = 0

    public init(frameRate: Double, holdDuration: Double = 1.6) {
        self.frameRate = frameRate
        holdFrames = Int(holdDuration * frameRate)
        filter = OneEuroFilter(frameRate: frameRate, minimumCutoff: 1.6, speedCoefficient: 0.06)
    }

    public mutating func reset() {
        smoothed = nil
        pending.removeAll(keepingCapacity: true)
        medianWindow.removeAll(keepingCapacity: true)
        settleWindow.removeAll(keepingCapacity: true)
        quietFrames = 0
        filter.reset()
    }

    public mutating func update(_ frequency: Double?) -> Reading? {
        guard let frequency else { return updateQuiet() }
        quietFrames = 0

        let cents = Interval.cents(frequency, from: 440)
        guard let current = smoothed else {
            startIfConsistent(cents)
            return smoothed.map(makeReading)
        }

        if abs(cents - current) < jumpCents {
            pending.removeAll(keepingCapacity: true)
            let value = filter.update(median(cents))
            smoothed = value
            recordSettling(value)
            return makeReading(value)
        }

        pending.append(cents)
        let needed = isOctaveAway(cents, from: current) ? octaveJumpFrames : jumpFrames
        if pending.count > needed { pending.removeFirst(pending.count - needed) }
        if pending.count == needed, spread(pending) < agreementCents {
            jump(to: middle(of: pending))
        }
        return smoothed.map(makeReading)
    }

    private mutating func updateQuiet() -> Reading? {
        pending.removeAll(keepingCapacity: true)
        guard let current = smoothed else { return nil }

        quietFrames += 1
        if quietFrames > holdFrames {
            reset()
            return nil
        }
        if quietFrames <= gapFrames {
            return makeReading(current)
        }
        return Reading(frequency: Self.frequency(fromCents: current), isLive: false, isSettled: false)
    }

    private mutating func startIfConsistent(_ cents: Double) {
        pending.append(cents)
        if pending.count > startFrames { pending.removeFirst() }
        if pending.count == startFrames, spread(pending) < agreementCents {
            jump(to: middle(of: pending))
        }
    }

    private mutating func jump(to cents: Double) {
        filter.reset()
        smoothed = filter.update(cents)
        pending.removeAll(keepingCapacity: true)
        medianWindow.removeAll(keepingCapacity: true)
        settleWindow.removeAll(keepingCapacity: true)
    }

    private mutating func median(_ value: Double) -> Double {
        medianWindow.append(value)
        if medianWindow.count > 3 { medianWindow.removeFirst() }
        return middle(of: medianWindow)
    }

    private mutating func recordSettling(_ value: Double) {
        settleWindow.append(value)
        if settleWindow.count > 12 { settleWindow.removeFirst() }
    }

    private func makeReading(_ cents: Double) -> Reading {
        Reading(frequency: Self.frequency(fromCents: cents), isLive: true, isSettled: isSettled)
    }

    private var isSettled: Bool {
        guard settleWindow.count >= 8 else { return false }
        return spread(settleWindow) < 2.5
    }

    private func isOctaveAway(_ cents: Double, from current: Double) -> Bool {
        let distance = abs(cents - current).truncatingRemainder(dividingBy: 1200)
        return abs(cents - current) > 600 && min(distance, 1200 - distance) < 70
    }

    private func spread(_ values: [Double]) -> Double {
        guard let low = values.min(), let high = values.max() else { return .infinity }
        return high - low
    }

    private func middle(of values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private static func frequency(fromCents cents: Double) -> Double {
        440 * pow(2, cents / 1200)
    }
}

/// A low-pass filter that smooths hard when a value is still and loosens as it moves.
struct OneEuroFilter: Sendable {
    private let frameRate: Double
    private let minimumCutoff: Double
    private let speedCoefficient: Double
    private let speedCutoff = 1.0

    private var value: Double?
    private var speed = 0.0

    init(frameRate: Double, minimumCutoff: Double, speedCoefficient: Double) {
        self.frameRate = frameRate
        self.minimumCutoff = minimumCutoff
        self.speedCoefficient = speedCoefficient
    }

    mutating func reset() {
        value = nil
        speed = 0
    }

    mutating func update(_ input: Double) -> Double {
        guard let previous = value else {
            value = input
            return input
        }

        let rawSpeed = (input - previous) * frameRate
        speed += smoothing(cutoff: speedCutoff) * (rawSpeed - speed)

        let cutoff = minimumCutoff + speedCoefficient * abs(speed)
        let output = previous + smoothing(cutoff: cutoff) * (input - previous)
        value = output
        return output
    }

    private func smoothing(cutoff: Double) -> Double {
        let timeConstant = 1 / (2 * Double.pi * cutoff)
        return 1 / (1 + timeConstant * frameRate)
    }
}

/// Decides when a string counts as in tune. It takes a moment to enter, and a little extra
/// error to leave, so the display doesn't flicker at the edge.
public struct InTuneDetector: Sendable {
    public var tolerance: Double
    public private(set) var isInTune = false

    private let frameRate: Double
    private let requiredFrames: Int
    private var matchingFrames = 0
    /// Whether coming into tune should be announced. A fading note that drops out and comes
    /// back in tune is the same success, so it isn't announced again.
    private var isArmed = true

    public init(frameRate: Double, tolerance: Double = 2, holdTime: Double = 0.18) {
        self.frameRate = frameRate
        self.tolerance = tolerance
        requiredFrames = Int(holdTime * frameRate)
    }

    /// Call when a new pluck starts or the target changes, so the next success is announced.
    public mutating func rearm() {
        isArmed = true
    }

    /// Returns true on the single frame when a string comes into tune, at most once until it
    /// goes out of tune again or `rearm()` is called.
    public mutating func update(cents: Double?, isLive: Bool) -> Bool {
        guard let cents, isLive else {
            isInTune = false
            matchingFrames = 0
            return false
        }

        if isInTune {
            if abs(cents) > tolerance + 1.5 {
                isInTune = false
                matchingFrames = 0
                isArmed = true
            }
            return false
        }

        guard abs(cents) <= tolerance else {
            matchingFrames = 0
            if abs(cents) > tolerance + 1.5 { isArmed = true }
            return false
        }
        matchingFrames += 1
        if matchingFrames >= requiredFrames {
            isInTune = true
            let announce = isArmed
            isArmed = false
            return announce
        }
        return false
    }
}
