import SwiftUI
import TunerCore

struct TunerScreen: View {
    @Environment(TunerModel.self) private var model
    @State private var isShowingTunings = false
    @State private var isShowingSettings = false

    var body: some View {
        GeometryReader { geometry in
            let isCompact = geometry.size.height < 700
            ZStack {
                SunburstBackground()

                VStack(spacing: 0) {
                    topBar
                    NoteHero()
                        .frame(maxHeight: .infinity)
                    ReadoutPanel()
                        .frame(height: isCompact ? 132 : 184)
                        .padding(.horizontal, 16)
                    StringsPanel()
                        .frame(height: isCompact ? 104 : 148)
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                    ControlsRow()
                        .padding(.horizontal, 20)
                        .padding(.top, 6)
                        .padding(.bottom, 8)
                }
                // The layout has fixed heights, so the largest accessibility sizes would clip.
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)

                if [.denied, .failed, .paused].contains(model.micStatus) {
                    MicrophoneNotice()
                }
            }
        }
        .sheet(isPresented: $isShowingTunings) {
            TuningPickerSheet()
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsSheet()
                .presentationDragIndicator(.visible)
        }
        .sensoryFeedback(.success, trigger: model.live.inTuneEvents) { _, _ in
            model.settings.hapticsEnabled
        }
    }

    private var topBar: some View {
        let isInTune = model.live.isInTune
        let primary = isInTune ? Palette.ebony : Palette.pearl
        let secondary = isInTune ? Palette.ebony.opacity(0.72) : Palette.nickel

        return HStack(alignment: .center) {
            Button {
                isShowingTunings = true
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tuningTitle)
                            .font(Typeface.data(21))
                            .foregroundStyle(primary)
                            .lineLimit(1)
                        Text(tuningSubtitle)
                            .font(Typeface.data(15))
                            .foregroundStyle(secondary)
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Tuning: \(tuningTitle), \(tuningSubtitle)")
            .accessibilityHint("Choose a tuning")

            Spacer()

            Button {
                isShowingSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .animation(.easeOut(duration: 0.16), value: isInTune)
    }

    private var tuningTitle: String {
        model.currentTuning?.name ?? "Chromatic"
    }

    private var tuningSubtitle: String {
        var parts: [String] = []
        if let tuning = model.currentTuning {
            parts.append("\(tuning.family.name), \(tuning.strings.count) strings")
        } else {
            parts.append("Any note")
        }

        let settings = model.settings
        if settings.a4 != 440 {
            parts.append("A \(settings.a4.formatted(.number.precision(.fractionLength(0...1))))")
        }
        if settings.temperamentID != Temperament.equal.id {
            parts.append(settings.temperament.name)
        }
        return parts.joined(separator: " · ")
    }
}

/// The dark field, and the glow that opens behind the note as a string nears pitch.
/// The glow drifts left when flat and right when sharp, so direction reads from across a room.
struct SunburstBackground: View {
    @Environment(TunerModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let live = model.live
            let width = geometry.size.width
            let height = geometry.size.height
            let diameter = max(width, height) * 1.25
            let closeness = live.closeness
            let inTune = live.isInTune
            let drift = inTune ? 0 : CGFloat(min(max(live.cents / 50, -1), 1)) * width * 0.34

            ZStack {
                LinearGradient(
                    colors: [Palette.ebony, Palette.rosewood.opacity(0.7), Palette.ebony],
                    startPoint: .top,
                    endPoint: .bottom
                )

                Circle()
                    .fill(
                        RadialGradient(
                            stops: [
                                .init(color: Palette.honey, location: 0),
                                .init(color: Palette.honey, location: 0.16),
                                .init(color: Palette.amber, location: 0.34),
                                .init(color: Palette.cherry, location: 0.60),
                                .init(color: Palette.rosewood.opacity(0.5), location: 0.82),
                                .init(color: .clear, location: 1),
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: diameter / 2
                        )
                    )
                    .frame(width: diameter, height: diameter)
                    .scaleEffect(inTune ? 0.92 : 0.28 + 0.44 * closeness)
                    .opacity(inTune ? 1 : (live.frequency == nil ? 0 : 0.28 + 0.5 * closeness))
                    .offset(x: drift, y: -height * 0.18)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: drift)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: closeness)
                    .animation(reduceMotion ? nil : .spring(duration: 0.34, bounce: 0.12), value: inTune)
            }
            .frame(width: width, height: height)
            .clipped()
        }
        .ignoresSafeArea()
    }
}

struct NoteHero: View {
    @Environment(TunerModel.self) private var model

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width * 0.66, geometry.size.height * 0.68)
            VStack(spacing: 0) {
                NoteGlyph(size: size)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                ReadingLine()
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var accessibilityText: String {
        let live = model.live
        if live.note == nil, let note = model.soundingNote {
            return "Playing \(note.spelled(model.settings.noteStyle).name)"
        }
        guard let note = live.note else { return "No note" }
        if live.isInTune { return "\(note.name), in tune" }
        let direction = live.cents < 0 ? "flat" : "sharp"
        return "\(note.name), \(Int(abs(live.cents).rounded())) cents \(direction)"
    }
}

struct NoteGlyph: View {
    @Environment(TunerModel.self) private var model
    let size: CGFloat

    var body: some View {
        let live = model.live
        let colour = live.isInTune ? Palette.ebony : Palette.pearl
        // While a reference tone plays the mic is off, so show the note being played.
        let tone = live.note == nil ? model.soundingNote?.spelled(model.settings.noteStyle) : nil

        Group {
            if let note = live.note ?? tone {
                HStack(alignment: .top, spacing: size * 0.03) {
                    marks(note).hidden()
                    Text(note.letter)
                        .font(Typeface.glyph(size))
                        .lineLimit(1)
                        .fixedSize()
                    marks(note)
                }
                .foregroundStyle(colour)
                .opacity(live.isLive || tone != nil ? 1 : 0.42)
            } else {
                Capsule()
                    .fill(Palette.pearl.opacity(0.14))
                    .frame(width: size * 0.42, height: size * 0.05)
            }
        }
        .animation(.easeOut(duration: 0.16), value: live.isInTune)
    }

    private func marks(_ note: SpelledNote) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(note.accidental.isEmpty ? " " : note.accidental)
                .font(Typeface.glyph(size * 0.34))
            Spacer(minLength: 0)
            Text("\(note.octave)")
                .font(Typeface.fixedData(size * 0.18))
                .padding(.bottom, size * 0.2)
        }
        .frame(width: size * 0.26, height: size * 1.1, alignment: .leading)
    }
}

struct ReadingLine: View {
    @Environment(TunerModel.self) private var model

    var body: some View {
        let live = model.live
        let colour = live.isInTune ? Palette.ebony : Palette.pearl
        let secondary = live.isInTune ? Palette.ebony.opacity(0.72) : Palette.nickel

        let hertz = live.frequency ?? model.soundingFrequency

        ZStack {
            Text(stateWord)
                .font(Typeface.data(26))
                .foregroundStyle(colour)

            HStack(alignment: .firstTextBaseline) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(live.frequency == nil ? "" : Format.cents(live.cents))
                        .font(Typeface.data(34))
                        .monospacedDigit()
                        .foregroundStyle(colour)
                    Text(live.frequency == nil ? "" : "cents")
                        .font(Typeface.data(16))
                        .foregroundStyle(secondary)
                }
                Spacer()
                Text(hertz.map(Format.hertz) ?? "")
                    .font(Typeface.data(18))
                    .monospacedDigit()
                    .foregroundStyle(secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .frame(minHeight: 44)
        .animation(.easeOut(duration: 0.16), value: live.isInTune)
    }

    private var stateWord: String {
        let live = model.live
        guard live.frequency != nil else { return "" }
        if live.isInTune { return "In tune" }
        return live.cents < 0 ? "Flat" : "Sharp"
    }
}

struct MicrophoneNotice: View {
    @Environment(TunerModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            Text(title)
                .font(Typeface.data(22))
                .foregroundStyle(Palette.pearl)
                .multilineTextAlignment(.center)

            Button {
                if model.micStatus == .denied {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } else {
                    model.retryMicrophone()
                }
            } label: {
                Text(buttonTitle)
                    .font(Typeface.data(18))
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background(Palette.amber, in: Capsule())
                    .foregroundStyle(Palette.ebony)
            }
            .buttonStyle(.plain)
        }
        .padding(28)
        .background(Palette.rosewood, in: RoundedRectangle(cornerRadius: 24))
        .padding(32)
    }

    private var title: String {
        switch model.micStatus {
        case .denied: "Microphone access is off"
        case .paused: "Microphone paused"
        default: "The microphone didn't start"
        }
    }

    private var buttonTitle: String {
        switch model.micStatus {
        case .denied: "Open Settings"
        case .paused: "Resume"
        default: "Try again"
        }
    }
}
