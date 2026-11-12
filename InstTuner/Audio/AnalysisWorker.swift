import Foundation
import TunerCore

/// Runs the pitch engine on its own queue, pulling audio from the ring buffer.
final class AnalysisWorker: @unchecked Sendable {
    struct Output: Sendable {
        /// Which `start` call produced this frame.
        var run: Int
        var frame: TunerFrame
    }

    let frames: AsyncStream<Output>

    private let continuation: AsyncStream<Output>.Continuation
    private let ring: SampleRingBuffer
    private let queue = DispatchQueue(label: "inst-tuner.analysis", qos: .userInteractive)

    // Only touched on `queue`.
    private var timer: DispatchSourceTimer?
    private var session: TunerSession?
    private var hopBuffer: UnsafeMutablePointer<Float>?
    private var sampleRate = 0.0
    private var run = 0

    init(ring: SampleRingBuffer) {
        self.ring = ring
        // Only the newest frame matters. If the screen falls behind, older ones are dropped.
        (frames, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    deinit {
        continuation.finish()
        hopBuffer?.deallocate()
    }

    func start(sampleRate: Double, settings: TunerSession.Settings, run: Int) {
        queue.async { [self] in
            stopTimer()
            self.run = run
            if session == nil || self.sampleRate != sampleRate {
                let created = TunerSession(sampleRate: sampleRate, settings: settings)
                session = created
                self.sampleRate = sampleRate
                hopBuffer?.deallocate()
                hopBuffer = .allocate(capacity: created.hopSize)
            } else {
                session?.update(settings: settings)
                session?.reset()
            }
            ring.discardAll()

            let timer = DispatchSource.makeTimerSource(queue: queue)
            // A frame is 21 ms of audio, so checking every 20 ms adds little delay.
            timer.schedule(deadline: .now() + 0.02, repeating: 0.02, leeway: .milliseconds(4))
            timer.setEventHandler { [weak self] in self?.drain() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.async { [self] in
            stopTimer()
        }
    }

    func update(settings: TunerSession.Settings) {
        queue.async { [self] in
            session?.update(settings: settings)
        }
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func drain() {
        guard let session, let hopBuffer else { return }

        // After a stall, skip to recent audio rather than working through old samples.
        let backlogLimit = Int(sampleRate * 0.25)
        if ring.availableToRead > backlogLimit {
            ring.discardAll()
            session.reset()
            return
        }

        var latest: TunerFrame?
        while ring.availableToRead >= session.hopSize {
            ring.read(into: hopBuffer, count: session.hopSize)
            latest = session.process(hop: hopBuffer)
        }
        if let latest {
            continuation.yield(Output(run: run, frame: latest))
        }
    }
}
