import SwiftUI
import TunerCore

/// The strings themselves are the string picker: heavier gauges look heavier, and the one
/// being played shakes.
struct StringsPanel: View {
    @Environment(TunerModel.self) private var model

    var body: some View {
        if let tuning = model.currentTuning {
            let live = model.live
            // Strings tuned to the same pitch light up together: they can't be told apart.
            let playing = live.isLive ? live.stringIndex.flatMap { tuning.strings[safe: $0] } : nil
            HStack(spacing: 0) {
                ForEach(Array(tuning.strings.enumerated()), id: \.offset) { index, string in
                    StringColumn(
                        index: index,
                        name: string.note.spelled(model.settings.noteStyle).name,
                        frequency: model.settings.context.frequency(of: string),
                        isPlaying: string == playing,
                        isCrowded: tuning.strings.count > 8
                    )
                }
            }
        } else {
            ChromaticStrip()
        }
    }
}

private struct StringColumn: View {
    @Environment(TunerModel.self) private var model
    let index: Int
    let name: String
    let frequency: Double
    let isPlaying: Bool
    let isCrowded: Bool

    private var thickness: CGFloat {
        CGFloat(min(max(1 + log2(330 / frequency) * 1.15, 1), 6.5))
    }

    private var isWound: Bool { frequency < 180 }

    var body: some View {
        let live = model.live
        let isLocked = model.lockedString == index
        let isSounding = model.sounding == .string(index)
        let isTuned = model.tunedStrings.contains(index)

        Button {
            model.stringTapped(index)
        } label: {
            VStack(spacing: 8) {
                // Only the string being played reads the per-frame values, so the others
                // don't redraw on every audio frame.
                StringLine(
                    thickness: thickness,
                    isWound: isWound,
                    isPlaying: isPlaying,
                    isInTune: isPlaying && live.isInTune,
                    level: isPlaying ? live.level : 0,
                    cents: isPlaying ? live.cents : 0
                )
                .frame(maxHeight: .infinity)

                Text(name)
                    .font(Typeface.data(isCrowded ? 15 : 19))
                    .foregroundStyle(isLocked || isSounding ? Palette.ebony : (isPlaying ? Palette.honey : Palette.pearl))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, isCrowded ? 3 : 8)
                    .frame(height: 30)
                    .background {
                        if isLocked || isSounding {
                            Capsule().fill(isSounding ? Palette.amber : Palette.honey)
                        }
                    }

                Circle()
                    .fill(isTuned ? Palette.honey : Color.clear)
                    .frame(width: 6, height: 6)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name) string")
        .accessibilityValue(isTuned ? "In tune" : "")
        .accessibilityAddTraits(isLocked ? .isSelected : [])
        .accessibilityHint(model.isToneMode ? "Plays this string's note" : "Locks the tuner to this string")
    }
}

private struct StringLine: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let thickness: CGFloat
    let isWound: Bool
    let isPlaying: Bool
    let isInTune: Bool
    let level: Double
    let cents: Double

    var body: some View {
        if isPlaying && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 60)) { timeline in
                Canvas { context, size in
                    draw(&context, size: size, time: timeline.date.timeIntervalSinceReferenceDate)
                }
            }
        } else {
            Canvas { context, size in
                draw(&context, size: size, time: nil)
            }
        }
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize, time: TimeInterval?) {
        let midX = size.width / 2
        let base = isInTune ? Palette.honey : (isPlaying ? Palette.amber : (isWound ? Palette.bronze : Palette.nickel))
        let colour = isPlaying ? base : base.opacity(0.62)

        if let time {
            // A vibrating string looks like a lens. Off pitch, it pulses like two notes beating.
            let beat = min(abs(cents) / 4, 6)
            let swell = isInTune ? 1 : 0.62 + 0.38 * cos(2 * Double.pi * beat * time)
            let amplitude = CGFloat(1.5 + 9 * level) * CGFloat(swell)

            var lens = Path()
            let steps = 24
            for step in 0...steps {
                let y = size.height * CGFloat(step) / CGFloat(steps)
                let x = midX + amplitude * sin(.pi * CGFloat(step) / CGFloat(steps))
                if step == 0 { lens.move(to: CGPoint(x: x, y: y)) } else { lens.addLine(to: CGPoint(x: x, y: y)) }
            }
            for step in stride(from: steps, through: 0, by: -1) {
                let y = size.height * CGFloat(step) / CGFloat(steps)
                lens.addLine(to: CGPoint(x: midX - amplitude * sin(.pi * CGFloat(step) / CGFloat(steps)), y: y))
            }
            context.fill(lens, with: .color(base.opacity(0.32)))
        }

        var line = Path()
        line.move(to: CGPoint(x: midX, y: 0))
        line.addLine(to: CGPoint(x: midX, y: size.height))
        context.stroke(line, with: .color(colour), lineWidth: thickness)

        if isWound, thickness > 1.8 {
            context.stroke(
                line,
                with: .color(Palette.ebony.opacity(0.55)),
                style: StrokeStyle(lineWidth: thickness, dash: [1, 1.6])
            )
        }
    }
}

/// In chromatic mode there are no strings, so the panel shows the twelve notes.
private struct ChromaticStrip: View {
    @Environment(TunerModel.self) private var model

    var body: some View {
        let live = model.live
        let style = model.settings.accidentals
        let current = live.note?.name

        VStack(spacing: 10) {
            ForEach([0..<6, 6..<12], id: \.lowerBound) { range in
                HStack(spacing: 0) {
                    ForEach(range, id: \.self) { pitchClass in
                        let name = Note.pitchClassName(pitchClass, style: style)
                        let isCurrent = name == current
                        let isSounding = model.sounding == .pitchClass(pitchClass)

                        Button {
                            model.pitchClassTapped(pitchClass)
                        } label: {
                            Text(name)
                                .font(Typeface.data(20))
                                .foregroundStyle(isSounding ? Palette.ebony : (isCurrent ? Palette.honey : Palette.nickel))
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background {
                                    if isSounding { Capsule().fill(Palette.amber) }
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!model.isToneMode)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}

struct ControlsRow: View {
    @Environment(TunerModel.self) private var model

    var body: some View {
        HStack {
            if model.currentTuning != nil {
                Button {
                    model.clearLock()
                } label: {
                    Text("Auto")
                        .font(Typeface.data(16))
                        .foregroundStyle(model.lockedString == nil ? Palette.ebony : Palette.pearl)
                        .padding(.horizontal, 18)
                        .frame(height: 38)
                        .background(
                            Capsule().fill(model.lockedString == nil ? Palette.honey : Palette.rosewood)
                        )
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Automatic string detection")
                .accessibilityAddTraits(model.lockedString == nil ? .isSelected : [])
            }

            Spacer()

            Button {
                model.setToneMode(!model.isToneMode)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: model.isToneMode ? "speaker.wave.2.fill" : "speaker.wave.2")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Play tone")
                        .font(Typeface.data(16))
                }
                .foregroundStyle(model.isToneMode ? Palette.ebony : Palette.pearl)
                .padding(.horizontal, 16)
                .frame(height: 38)
                .background(Capsule().fill(model.isToneMode ? Palette.amber : Palette.rosewood))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(model.isToneMode ? .isSelected : [])
            .accessibilityHint("Plays a reference note. Tap a string or note to change it")
        }
    }
}
