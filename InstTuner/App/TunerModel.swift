import AVFoundation
import Observation
import SwiftUI
import TunerCore
import UIKit

enum MicStatus: Equatable {
    case starting, listening, paused, denied, failed
}

enum ToneSource: Equatable {
    case string(Int)
    case pitchClass(Int)
}

@MainActor
@Observable
final class TunerModel {
    let live = LiveTuner()

    var settings: TunerSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            inTune.tolerance = settings.toleranceCents
            worker.update(settings: sessionSettings)
            retuneTone()
        }
    }

    private(set) var micStatus = MicStatus.starting
    private(set) var lockedString: Int?
    private(set) var tunedStrings: Set<Int> = []
    private(set) var isToneMode = false
    private(set) var sounding: ToneSource?

    @ObservationIgnored private let audio = AudioController()
    @ObservationIgnored private let worker: AnalysisWorker
    @ObservationIgnored private var inTune: InTuneDetector
    @ObservationIgnored private var isActive = false
    /// Audio start and stop calls run one at a time, in the order they were asked for.
    @ObservationIgnored private var audioChain: Task<Void, Never>?
    /// Frames from an analysis run that has since been stopped are ignored.
    @ObservationIgnored private var analysisRun = 0
    @ObservationIgnored private var acceptedRun: Int?
    @ObservationIgnored private var lastNoteCount = 0
    @ObservationIgnored private var lastTarget: HeardTarget?
    @ObservationIgnored private var lastHeardString: Int?
    @ObservationIgnored private var lastHeardPitchClass: Int?
    @ObservationIgnored private var toneFrequency: Double?

    #if DEBUG
    @ObservationIgnored private var demo: DemoSignal?
    #endif

    private enum HeardTarget: Equatable {
        case string(Int)
        case note(Int)
    }

    init() {
        var loaded = TunerSettings.load()
        #if DEBUG
        DemoSignal.applyOverrides(to: &loaded)
        #endif
        settings = loaded
        worker = AnalysisWorker(ring: audio.ring)
        inTune = InTuneDetector(
            frameRate: TunerSession.frameRate(sampleRate: 48_000),
            tolerance: loaded.toleranceCents
        )
        observeFrames()
        observeAudioEvents()
    }

    var currentTuning: Tuning? { settings.tuning }

    /// The note being played as a reference tone, if any.
    var soundingNote: Note? {
        switch sounding {
        case .string(let index): settings.tuning?.strings[safe: index]?.note
        case .pitchClass(let pitchClass): Note(midi: 48 + pitchClass)
        case nil: nil
        }
    }

    var soundingFrequency: Double? {
        sounding.flatMap(frequency(of:))
    }

    private var sessionSettings: TunerSession.Settings {
        TunerSession.Settings(
            context: settings.context,
            strings: settings.tuning?.strings ?? [],
            lockedString: lockedString,
            wantsSpectrum: settings.readout == .spectrum
        )
    }

    // MARK: - Lifecycle

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            if isActive {
                // iOS doesn't promise to say when an interruption ends, so check on every return.
                enqueue { await self.recoverAudio() }
            } else {
                setActive(true)
            }
        case .background:
            setActive(false)
        default:
            break
        }
    }

    private func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            enqueue { await self.beginListening() }
        } else {
            sounding = nil
            enqueue { await self.shutDown() }
        }
    }

    func retryMicrophone() {
        micStatus = .starting
        enqueue { await self.beginListening() }
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = audioChain
        audioChain = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    private func beginListening() async {
        guard isActive, sounding == nil else { return }

        #if DEBUG
        if DemoSignal.isEnabled {
            startDemo()
            return
        }
        #endif

        var granted = AVAudioApplication.shared.recordPermission == .granted
        if AVAudioApplication.shared.recordPermission == .undetermined {
            granted = await AVAudioApplication.requestRecordPermission()
        }
        guard granted else {
            micStatus = .denied
            return
        }
        guard isActive else { return }

        do {
            let sampleRate = try await audio.startListening()
            startAnalysis(sampleRate: sampleRate)
            micStatus = .listening
            UIApplication.shared.isIdleTimerDisabled = true
        } catch {
            // Still inside a call or another app's interruption: stay paused, not failed.
            micStatus = micStatus == .paused ? .paused : .failed
        }
    }

    private func shutDown() async {
        stopAnalysis()
        #if DEBUG
        demo?.stop()
        demo = nil
        #endif
        await audio.stopAll()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func startAnalysis(sampleRate: Double) {
        analysisRun += 1
        acceptedRun = analysisRun
        lastNoteCount = 0
        lastTarget = nil
        inTune = InTuneDetector(
            frameRate: TunerSession.frameRate(sampleRate: sampleRate),
            tolerance: settings.toleranceCents
        )
        worker.start(sampleRate: sampleRate, settings: sessionSettings, run: analysisRun)
    }

    private func stopAnalysis() {
        acceptedRun = nil
        worker.stop()
        live.clear()
    }

    private func observeFrames() {
        let frames = worker.frames
        Task { [weak self] in
            for await output in frames {
                self?.apply(output)
            }
        }
    }

    private func observeAudioEvents() {
        let events = audio.events
        Task { [weak self] in
            for await event in events {
                self?.handle(event)
            }
        }
    }

    private func handle(_ event: AudioEvent) {
        switch event {
        case .interrupted:
            stopAnalysis()
            if micStatus == .listening { micStatus = .paused }
        case .interruptionEnded, .routeChanged:
            guard isActive else { return }
            enqueue { await self.recoverAudio() }
        }
    }

    /// Starting an engine can itself post a route change, so only restart what actually stopped.
    private func recoverAudio() async {
        if sounding != nil {
            if await audio.isToneRunning { return }
            sounding = nil
        }
        if micStatus == .listening, await audio.isInputRunning { return }
        await beginListening()
    }

    private func apply(_ output: AnalysisWorker.Output) {
        guard output.run == acceptedRun else { return }
        let frame = output.frame

        // A new pluck, or a different string or note, earns a fresh in-tune announcement.
        if frame.noteCount != lastNoteCount {
            lastNoteCount = frame.noteCount
            inTune.rearm()
        }
        if let reading = frame.reading {
            let target = reading.stringIndex.map(HeardTarget.string) ?? .note(reading.note.midi)
            if target != lastTarget {
                lastTarget = target
                inTune.rearm()
            }
            if reading.isLive {
                lastHeardString = reading.stringIndex
                lastHeardPitchClass = reading.note.pitchClass
            }
        }

        let justTuned = inTune.update(cents: frame.reading?.cents, isLive: frame.reading?.isLive ?? false)
        live.apply(frame, inTune: inTune.isInTune, justTuned: justTuned, style: settings.noteStyle)
        updateTunedStrings(frame.reading, justTuned: justTuned)
    }

    private func updateTunedStrings(_ reading: TunerReading?, justTuned: Bool) {
        guard let reading, let index = reading.stringIndex else { return }
        let drifted = reading.isLive && reading.isSettled && abs(reading.cents) > settings.toleranceCents + 4
        guard justTuned || (drifted && tunedStrings.contains(index)) else { return }

        // Strings tuned to the same pitch (a 12-string's unison pairs) can't be told apart.
        var same: Set<Int> = [index]
        if let strings = settings.tuning?.strings, let string = strings[safe: index] {
            same = Set(strings.indices.filter { strings[$0] == string })
        }
        if justTuned {
            tunedStrings.formUnion(same)
        } else {
            tunedStrings.subtract(same)
        }
    }

    // MARK: - Choosing what to tune

    func select(tuningID: String) {
        guard tuningID != settings.selectedTuningID else { return }
        stopTone()
        lockedString = nil
        tunedStrings = []
        lastHeardString = nil

        var updated = settings
        updated.selectedTuningID = tuningID
        if let family = updated.tuning?.family { updated.lastFamily = family }
        settings = updated
    }

    func rememberFamily(_ family: InstrumentFamily) {
        settings.lastFamily = family
    }

    func clearLock() {
        guard lockedString != nil else { return }
        lockedString = nil
        worker.update(settings: sessionSettings)
    }

    func stringTapped(_ index: Int) {
        guard settings.tuning?.strings.indices.contains(index) == true else { return }
        if isToneMode {
            toggleTone(.string(index))
        } else {
            lockedString = lockedString == index ? nil : index
            worker.update(settings: sessionSettings)
        }
    }

    func saveCustomTuning(_ tuning: Tuning) {
        let isCurrent = settings.selectedTuningID == tuning.id
        if isCurrent {
            // Clear these first, so the settings change below sends the engine no stale lock.
            stopTone()
            lockedString = nil
            tunedStrings = []
            lastHeardString = nil
        }
        if let index = settings.customTunings.firstIndex(where: { $0.id == tuning.id }) {
            settings.customTunings[index] = tuning
        } else {
            settings.customTunings.append(tuning)
        }
        if isCurrent {
            // Saving without changes leaves the settings equal, so nothing else would tell it.
            worker.update(settings: sessionSettings)
        }
    }

    func deleteCustomTuning(id: String) {
        if settings.selectedTuningID == id {
            select(tuningID: TuningLibrary.defaultTuning.id)
        }
        settings.customTunings.removeAll { $0.id == id }
    }

    // MARK: - Reference tone

    /// Turning tone mode on plays a note straight away: the locked string, else the last one
    /// heard, else the lowest.
    func setToneMode(_ enabled: Bool) {
        isToneMode = enabled
        guard enabled else {
            stopTone()
            return
        }
        if let tuning = settings.tuning {
            let index = [lockedString, lastHeardString].compactMap { $0 }
                .first { tuning.strings.indices.contains($0) } ?? 0
            toggleTone(.string(index))
        } else {
            toggleTone(.pitchClass(lastHeardPitchClass ?? 9))
        }
    }

    func pitchClassTapped(_ pitchClass: Int) {
        guard isToneMode else { return }
        toggleTone(.pitchClass(pitchClass))
    }

    private func frequency(of source: ToneSource) -> Double? {
        switch source {
        case .string(let index):
            settings.tuning?.strings[safe: index].map { settings.context.frequency(of: $0) }
        case .pitchClass(let pitchClass):
            settings.context.frequency(of: Note(midi: 48 + pitchClass))
        }
    }

    private func toggleTone(_ source: ToneSource) {
        if sounding == source {
            stopTone()
            return
        }
        guard let frequency = frequency(of: source) else { return }
        sounding = source
        toneFrequency = frequency
        enqueue {
            self.stopAnalysis()
            do {
                try await self.audio.startTone(frequency: frequency)
            } catch {
                self.sounding = nil
                self.toneFrequency = nil
                await self.beginListening()
            }
        }
    }

    /// Keeps a sounding tone on pitch when the reference, tuning system or tuning changes.
    private func retuneTone() {
        guard let sounding else { return }
        guard let frequency = frequency(of: sounding) else {
            stopTone()
            return
        }
        guard frequency != toneFrequency else { return }
        toneFrequency = frequency
        enqueue {
            guard self.sounding == sounding else { return }
            try? await self.audio.startTone(frequency: frequency)
        }
    }

    private func stopTone() {
        guard sounding != nil else { return }
        sounding = nil
        toneFrequency = nil
        enqueue {
            await self.audio.stopTone()
            await self.beginListening()
        }
    }

    #if DEBUG
    private func startDemo() {
        guard demo == nil else { return }
        let sampleRate = 48_000.0
        startAnalysis(sampleRate: sampleRate)
        let frequencies = (settings.tuning?.strings ?? [TuningString(note: Note(midi: 57))])
            .map { settings.context.frequency(of: $0) }
        let signal = DemoSignal(ring: audio.ring, frequencies: frequencies, sampleRate: sampleRate)
        signal.start()
        demo = signal
        micStatus = .listening
    }
    #endif
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
