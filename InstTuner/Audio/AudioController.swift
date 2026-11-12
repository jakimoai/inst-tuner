import AVFoundation
import TunerCore

enum AudioEvent: Sendable {
    case interrupted
    case interruptionEnded
    case routeChanged
}

enum AudioFailure: Error {
    case noInput
}

/// Owns the audio session and engines. The microphone and the reference tone never run at the
/// same time: the tuner must not hear its own tone, and each path gets the session mode it
/// needs (raw input for measuring, full speaker volume for playback).
actor AudioController {
    /// About five seconds of audio, far more than the analysis ever falls behind by.
    nonisolated let ring = SampleRingBuffer(minimumCapacity: 1 << 18)
    nonisolated let events: AsyncStream<AudioEvent>

    private let eventContinuation: AsyncStream<AudioEvent>.Continuation
    private var inputEngine: AVAudioEngine?
    private var toneEngine: AVAudioEngine?
    private var toneGenerator: ToneGenerator?
    private var observersInstalled = false

    init() {
        (events, eventContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
    }

    /// True while the microphone path is actually running.
    var isInputRunning: Bool { inputEngine?.isRunning == true }

    /// True while the reference tone is actually running.
    var isToneRunning: Bool { toneEngine?.isRunning == true }

    /// Returns the input sample rate.
    func startListening() throws -> Double {
        installObserversIfNeeded()
        stopEngines()

        do {
            return try startInput(category: .record)
        } catch {
            // Some routes refuse a record-only session. Both categories give the same raw input.
            stopEngines()
            return try startInput(category: .playAndRecord)
        }
    }

    private func startInput(category: AVAudioSession.Category) throws -> Double {
        let session = AVAudioSession.sharedInstance()
        // Measurement mode turns off the gain control and filtering that would damage low notes.
        try session.setCategory(category, mode: .measurement, options: [])
        // iOS silences haptics while recording unless the app asks otherwise.
        try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try session.setPreferredSampleRate(48_000)
        // The analysis works in 21 ms frames, so smaller buffers only cost battery.
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)
        Self.preferOmnidirectionalMicrophone(session)

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioFailure.noInput }

        let sink = Self.makeSink(ring: ring)
        engine.attach(sink)
        engine.connect(input, to: sink, format: format)
        try engine.start()

        inputEngine = engine
        return format.sampleRate
    }

    func startTone(frequency: Double) throws {
        installObserversIfNeeded()
        if let toneGenerator, toneEngine?.isRunning == true {
            toneGenerator.play(frequency: frequency)
            return
        }
        stopEngines()

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true)

        let engine = AVAudioEngine()
        let hardwareRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let sampleRate = hardwareRate > 0 ? hardwareRate : 48_000
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw AudioFailure.noInput
        }

        let generator = ToneGenerator(sampleRate: sampleRate)
        generator.play(frequency: frequency)
        let source = Self.makeSource(generator: generator, format: format)
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        try engine.start()

        toneEngine = engine
        toneGenerator = generator
    }

    func stopTone() async {
        toneGenerator?.stop()
        // Let the fade-out finish so the tone doesn't end in a click.
        try? await Task.sleep(for: .milliseconds(60))
        toneEngine?.stop()
        toneEngine = nil
        toneGenerator = nil
    }

    func stopAll() async {
        if toneEngine != nil {
            await stopTone()
        }
        stopEngines()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func stopEngines() {
        inputEngine?.stop()
        inputEngine = nil
        toneGenerator?.stop()
        toneEngine?.stop()
        toneEngine = nil
        toneGenerator = nil
    }

    // MARK: - Real-time blocks

    // These are built in nonisolated static functions so the closures carry no actor isolation.
    // They run on the real-time audio thread, where an isolation check would crash the app.

    private nonisolated static func makeSink(ring: SampleRingBuffer) -> AVAudioSinkNode {
        AVAudioSinkNode { @Sendable _, frameCount, bufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
            guard let data = buffers.first?.mData else { return noErr }
            ring.write(data.assumingMemoryBound(to: Float.self), count: Int(frameCount))
            return noErr
        }
    }

    private nonisolated static func makeSource(generator: ToneGenerator, format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { @Sendable _, _, frameCount, bufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard let data = buffers.first?.mData else { return noErr }
            generator.render(into: data.assumingMemoryBound(to: Float.self), frameCount: Int(frameCount))
            return noErr
        }
    }

    // MARK: - Session setup

    /// Uses the bottom microphone in omnidirectional mode. The directional modes combine
    /// several mics in a way that thins out low notes. External inputs are left alone.
    private static func preferOmnidirectionalMicrophone(_ session: AVAudioSession) {
        guard session.currentRoute.inputs.contains(where: { $0.portType == .builtInMic }),
              let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }),
              let source = builtIn.dataSources?.first(where: { $0.location == .lower }) ?? builtIn.dataSources?.first
        else { return }

        if source.supportedPolarPatterns?.contains(.omnidirectional) == true {
            try? source.setPreferredPolarPattern(.omnidirectional)
        }
        try? builtIn.setPreferredDataSource(source)
        try? session.setPreferredInput(builtIn)
    }

    private func installObserversIfNeeded() {
        guard !observersInstalled else { return }
        observersInstalled = true
        let continuation = eventContinuation
        let center = NotificationCenter.default

        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { @Sendable note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw)
            else { return }
            continuation.yield(type == .began ? .interrupted : .interruptionEnded)
        }
        center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { @Sendable _ in
            continuation.yield(.routeChanged)
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { @Sendable _ in
            continuation.yield(.routeChanged)
        }
    }
}
