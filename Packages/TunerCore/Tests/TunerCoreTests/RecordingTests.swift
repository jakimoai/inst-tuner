import AVFoundation
import Foundation
import Testing
@testable import TunerCore

/// Scores real recordings. Skipped unless TUNER_RECORDINGS points at a folder of files named
/// like the University of Iowa samples ("Guitar.mf.sulE.E2B2.stereo.aif"), each a rising
/// chromatic run between the two notes in its name.
@Suite(
    "Real recordings",
    .enabled(if: ProcessInfo.processInfo.environment["TUNER_RECORDINGS"] != nil)
)
struct RecordingTests {
    private struct Segment {
        var midi: Int
        var duration: Double
        var medianCents: Double
        var spreadCents: Double
    }

    private struct Score {
        var found: Int
        var expected: Int
        var strayDuration: Double
        var octaveDuration: Double
        var worstSpread: Double
        /// Time spent reading a note that was actually played.
        var goodDuration: Double
    }

    @Test("Report")
    func report() throws {
        let folder = try #require(ProcessInfo.processInfo.environment["TUNER_RECORDINGS"])
        let names = try FileManager.default.contentsOfDirectory(atPath: folder)
            .filter { $0.hasSuffix(".aif") }
            .sorted()

        var misses = 0
        var totalOctave = 0.0
        var totalStray = 0.0
        var totalGood = 0.0
        for corner in [nil, 100.0, 180.0] as [Double?] {
            print("\n=== \(corner.map { "Phone mic simulation, \(Int($0)) Hz corner" } ?? "As recorded") ===")
            for name in names {
                let range = try #require(Self.expectedRange(name), "Unrecognised name \(name)")
                let audio = try Self.load("\(folder)/\(name)", highPassCorner: corner)
                let segments = Self.segments(audio.samples, sampleRate: audio.sampleRate)
                let score = Self.score(segments, expected: range)
                misses += score.expected - score.found
                totalOctave += score.octaveDuration
                totalStray += score.strayDuration
                totalGood += score.goodDuration

                let line = String(
                    format: "%@  found %d/%d  stray %.2fs  octave-wrong %.2fs  worst wobble %.1f¢",
                    name.replacingOccurrences(of: ".stereo.aif", with: "").padding(toLength: 32, withPad: " ", startingAt: 0),
                    score.found, score.expected, score.strayDuration, score.octaveDuration, score.worstSpread
                )
                print(line)
                if ProcessInfo.processInfo.environment["TUNER_VERBOSE"] != nil,
                   score.found < score.expected || score.octaveDuration > 0.3 {
                    let detail = segments.map {
                        "\(Note(midi: $0.midi).spelled(.sharps).name)\(Note(midi: $0.midi).octave)(\(String(format: "%.1f", $0.duration)))"
                    }
                    print("    heard: \(detail.joined(separator: " "))")
                }
            }
        }
        try openStrings(folder: folder, names: names)
        print(String(
            format: "\nTotal missed notes: %d, octave-wrong %.1fs, stray %.1fs, right note %.1fs",
            misses, totalOctave, totalStray, totalGood
        ))
    }

    /// Tests the job that matters most, which is open strings in a real tuning through a weak microphone.
    /// The first note of each file is an open string. Double bass files use a 5-string tuning.
    private func openStrings(folder: String, names: [String]) throws {
        print("\n=== Open strings in tuning mode ===")
        for corner in [nil, 100.0, 180.0, 250.0] as [Double?] {
            var correct = 0
            var total = 0
            var wrongNames: [String] = []
            for name in names where !name.contains("sulC") {
                let range = try #require(Self.expectedRange(name))
                let tuningID = name.hasPrefix("Guitar") ? "g6.standard" : "b5.standard"
                let tuning = try #require(TuningLibrary.tuning(id: tuningID))
                let expectedIndex = try #require(tuning.strings.firstIndex { $0.note.midi == range.lowerBound })

                let audio = try Self.load("\(folder)/\(name)", highPassCorner: corner)
                let session = TunerSession(sampleRate: audio.sampleRate, settings: .init(strings: tuning.strings))
                let frames = Int(1.8 * audio.sampleRate) / session.hopSize
                let start = try #require(audio.samples.firstIndex { abs($0) > 0.002 })

                var votes: [Int: Int] = [:]
                audio.samples.withUnsafeBufferPointer { buffer in
                    guard let base = buffer.baseAddress else { return }
                    var position = start
                    for frame in 0..<frames where position + session.hopSize <= audio.samples.count {
                        let result = session.process(hop: base + position)
                        position += session.hopSize
                        if frame > 16, let index = result.reading?.stringIndex, result.reading?.isLive == true {
                            votes[index, default: 0] += 1
                        }
                    }
                }

                total += 1
                let winner = votes.max { $0.value < $1.value }?.key
                let share = Double(votes[expectedIndex] ?? 0) / Double(max(votes.values.reduce(0, +), 1))
                if winner == expectedIndex, share > 0.9 {
                    correct += 1
                } else {
                    wrongNames.append("\(name.prefix(24)) \(votes)")
                }
            }
            let label = corner.map { "\(Int($0)) Hz corner" } ?? "as recorded"
            print("\(label): \(correct)/\(total) on the right string for over 90% of frames")
            wrongNames.forEach { print("    \($0)") }
        }
    }

    private static func expectedRange(_ name: String) -> ClosedRange<Int>? {
        let parts = name.split(separator: ".").map(String.init)
        guard let token = parts.first(where: { $0.range(of: #"^[A-G]b?\d[A-G]b?\d$"#, options: .regularExpression) != nil }),
              let split = token.dropFirst().firstIndex(where: { $0.isNumber }),
              let low = Note(String(token[...split])),
              let high = Note(String(token[token.index(after: split)...]))
        else { return nil }
        return low.midi...high.midi
    }

    private static func load(_ path: String, highPassCorner: Double?) throws -> (samples: [Float], sampleRate: Double) {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        try file.read(into: buffer)
        let channel = try #require(buffer.floatChannelData)[0]
        var samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        if let highPassCorner {
            samples = highPass(samples, corner: highPassCorner, sampleRate: format.sampleRate)
        }
        return (samples, format.sampleRate)
    }

    /// 12 dB/octave Butterworth high-pass.
    private static func highPass(_ input: [Float], corner: Double, sampleRate: Double) -> [Float] {
        let omega = 2 * Double.pi * corner / sampleRate
        let alpha = sin(omega) / (2 * 0.7071)
        let cosine = cos(omega)
        let a0 = 1 + alpha
        let b0 = ((1 + cosine) / 2) / a0
        let b1 = -(1 + cosine) / a0
        let b2 = b0
        let a1 = -2 * cosine / a0
        let a2 = (1 - alpha) / a0

        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        return input.map { sample in
            let x0 = Double(sample)
            let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x0; y2 = y1; y1 = y0
            return Float(y0)
        }
    }

    private static func segments(_ samples: [Float], sampleRate: Double) -> [Segment] {
        let session = TunerSession(sampleRate: sampleRate, settings: .init())
        let frameDuration = Double(session.hopSize) / sampleRate

        var result: [Segment] = []
        var currentMidi: Int?
        var cents: [Double] = []

        func close() {
            guard let midi = currentMidi, !cents.isEmpty else { return }
            let duration = Double(cents.count) * frameDuration
            let settled = Array(cents.dropFirst(min(cents.count / 3, 12))).sorted()
            let low = settled[Int(Double(settled.count) * 0.1)]
            let high = settled[Int(Double(settled.count) * 0.9)]
            result.append(Segment(
                midi: midi,
                duration: duration,
                medianCents: settled[settled.count / 2],
                spreadCents: high - low
            ))
        }

        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var position = 0
            while position + session.hopSize <= samples.count {
                let frame = session.process(hop: base + position)
                position += session.hopSize

                if let reading = frame.reading, reading.isLive {
                    if reading.note.midi != currentMidi {
                        close()
                        currentMidi = reading.note.midi
                        cents = []
                    }
                    cents.append(reading.cents)
                } else {
                    close()
                    currentMidi = nil
                    cents = []
                }
            }
        }
        close()

        // Merge neighbouring pieces of the same note split by a brief dropout.
        var merged: [Segment] = []
        for segment in result {
            if let last = merged.last, last.midi == segment.midi {
                merged[merged.count - 1].duration += segment.duration
                merged[merged.count - 1].spreadCents = max(last.spreadCents, segment.spreadCents)
            } else {
                merged.append(segment)
            }
        }
        return merged
    }

    private static func score(_ segments: [Segment], expected: ClosedRange<Int>) -> Score {
        var found = 0
        var worstSpread = 0.0
        for midi in expected {
            let matches = segments.filter { $0.midi == midi && $0.duration >= 0.25 }
            if !matches.isEmpty { found += 1 }
            worstSpread = max(worstSpread, matches.map(\.spreadCents).max() ?? 0)
        }

        let expectedClasses = Set(expected.map { ($0 % 12 + 12) % 12 })
        var stray = 0.0
        var octave = 0.0
        for segment in segments where !expected.contains(segment.midi) {
            stray += segment.duration
            if expectedClasses.contains((segment.midi % 12 + 12) % 12) {
                octave += segment.duration
            }
        }
        return Score(
            found: found,
            expected: expected.count,
            strayDuration: stray,
            octaveDuration: octave,
            worstSpread: worstSpread,
            goodDuration: segments.filter { expected.contains($0.midi) }.map(\.duration).reduce(0, +)
        )
    }
}
