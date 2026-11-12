import SwiftUI
import TunerCore

struct ReadoutPanel: View {
    @Environment(TunerModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 20) {
                ForEach(ReadoutMode.allCases) { mode in
                    Button {
                        model.settings.readout = mode
                    } label: {
                        Text(mode.title)
                            .font(Typeface.data(16))
                            .foregroundStyle(model.settings.readout == mode ? Palette.pearl : Palette.nickel.opacity(0.75))
                            .lineLimit(1)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.settings.readout == mode ? .isSelected : [])
                }
            }
            .frame(maxWidth: .infinity)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        .padding(.top, 2)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Palette.ebony.opacity(0.88))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Palette.nickel.opacity(0.16), lineWidth: 1)
                }
        )
    }

    @ViewBuilder
    private var content: some View {
        switch model.settings.readout {
        case .needle: NeedleReadout()
        case .strobe: StrobeReadout()
        case .trace: TraceReadout()
        case .spectrum: SpectrumReadout()
        }
    }
}

/// A scale from −50 to +50 cents, stretched near the centre (square-root spacing) so the last
/// few cents before in-tune are easy to see.
struct NeedleReadout: View {
    @Environment(TunerModel.self) private var model

    var body: some View {
        let live = model.live
        let cents = live.cents
        let hasSignal = live.frequency != nil
        let isLive = live.isLive
        let inTune = live.isInTune
        let tolerance = model.settings.toleranceCents

        Canvas { context, size in
            let midX = size.width / 2
            let halfWidth = size.width / 2 - 6
            let baseline = size.height - 18
            let position = { (value: Double) -> CGFloat in
                let clamped = min(max(value, -50), 50)
                let scaled = (abs(clamped) / 50).squareRoot() * (clamped < 0 ? -1 : 1)
                return midX + CGFloat(scaled) * halfWidth
            }
            let labelled: Set<Int> = [0, 5, 20, 50]

            // The in-tune window.
            let window = CGRect(
                x: position(-tolerance),
                y: 6,
                width: position(tolerance) - position(-tolerance),
                height: baseline - 6
            )
            context.fill(
                Path(roundedRect: window, cornerRadius: 3),
                with: .color(Palette.honey.opacity(inTune ? 0.42 : 0.16))
            )

            let ticks = [0, 1, 2, 3, 4] + Array(stride(from: 5, through: 50, by: 5))
            for tick in ticks.flatMap({ $0 == 0 ? [0] : [-$0, $0] }) {
                let isMajor = labelled.contains(abs(tick))
                let isMedium = tick % 10 == 0
                let scale = baseline - 6
                let length = scale * (isMajor ? 0.62 : (isMedium ? 0.4 : 0.22))
                let x = position(Double(tick))
                var path = Path()
                path.move(to: CGPoint(x: x, y: baseline))
                path.addLine(to: CGPoint(x: x, y: baseline - length))
                context.stroke(
                    path,
                    with: .color(Palette.nickel.opacity(isMajor ? 0.95 : 0.5)),
                    lineWidth: isMajor ? 2 : 1
                )
            }

            for value in labelled.flatMap({ $0 == 0 ? [0] : [-$0, $0] }) {
                let label = value > 0 ? "+\(value)" : (value < 0 ? "−\(-value)" : "0")
                context.draw(
                    Text(label).font(Typeface.fixedData(13)).foregroundStyle(Palette.nickel),
                    at: CGPoint(x: min(max(position(Double(value)), 14), size.width - 14), y: size.height - 7)
                )
            }

            guard hasSignal else { return }

            // The needle: a solid bar, thick enough to read from a music stand.
            let clamped = min(max(cents, -50), 50)
            let colour = inTune ? Palette.honey : (isLive ? Palette.pearl : Palette.nickel)
            let bar = CGRect(x: position(clamped) - 4, y: 2, width: 8, height: baseline - 2)
            context.fill(Path(roundedRect: bar, cornerRadius: 4), with: .color(colour))

            if abs(cents) > 50 {
                let chevron = cents < 0 ? "‹‹" : "››"
                context.draw(
                    Text(chevron).font(Typeface.fixedData(28)).foregroundStyle(Palette.amber),
                    at: CGPoint(x: cents < 0 ? 34 : size.width - 34, y: size.height * 0.34)
                )
            }
        }
    }
}

/// Four bands that drift when the pitch is off and stand still when it's right.
/// Each lower band moves half as far per cycle, like the discs on a mechanical strobe tuner.
struct StrobeReadout: View {
    @Environment(TunerModel.self) private var model
    @State private var clock = StrobeClock()

    var body: some View {
        let live = model.live
        let cents = live.cents
        let isLive = live.isLive
        let inTune = live.isInTune

        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let phase = clock.advance(to: timeline.date, cents: isLive ? cents : 0)
                let bandCount = 4
                let gap: CGFloat = 5
                let bandHeight = (size.height - gap * CGFloat(bandCount - 1)) / CGFloat(bandCount)
                let colour = inTune ? Palette.honey : (isLive ? Palette.amber : Palette.nickel.opacity(0.35))

                for band in 0..<bandCount {
                    let period = 88.0 / pow(2.0, Double(band))
                    let y = CGFloat(band) * (bandHeight + gap)
                    let offset = (phase * period).truncatingRemainder(dividingBy: period)
                    var x = -period + offset

                    context.drawLayer { layer in
                        layer.clip(to: Path(CGRect(x: 0, y: y, width: size.width, height: bandHeight)))
                        while x < size.width {
                            let rect = CGRect(x: x, y: y, width: period * 0.5, height: bandHeight)
                            layer.fill(Path(rect), with: .color(colour))
                            x += period
                        }
                    }
                }

                // Centre mark.
                var mark = Path()
                mark.move(to: CGPoint(x: size.width / 2, y: 0))
                mark.addLine(to: CGPoint(x: size.width / 2, y: size.height))
                context.stroke(mark, with: .color(Palette.pearl.opacity(0.7)), lineWidth: 1.5)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Integrates band position over time. A reference type so drawing can advance it in place.
final class StrobeClock {
    private var phase = 0.0
    private var lastDate: Date?

    func advance(to date: Date, cents: Double) -> Double {
        defer { lastDate = date }
        guard let lastDate else { return phase }
        let elapsed = min(date.timeIntervalSince(lastDate), 0.1)
        let cyclesPerSecond = min(max(cents / 3, -14), 14)
        phase += elapsed * cyclesPerSecond
        return phase
    }
}

/// The last few seconds of pitch, newest at the right.
struct TraceReadout: View {
    @Environment(TunerModel.self) private var model

    var body: some View {
        let trace = model.live.trace
        let inTune = model.live.isInTune
        let tolerance = model.settings.toleranceCents

        Canvas { context, size in
            let midY = size.height / 2
            let range = 50.0

            // Square-root scale: fine detail near pitch, still room for a wild note.
            let yPosition = { (cents: Double) -> CGFloat in
                let clamped = min(max(cents, -range), range)
                let scaled = (abs(clamped) / range).squareRoot() * (clamped < 0 ? -1 : 1)
                return midY - CGFloat(scaled) * (size.height / 2 - 2)
            }

            let top = yPosition(tolerance)
            let bottom = yPosition(-tolerance)
            context.fill(
                Path(CGRect(x: 0, y: top, width: size.width, height: bottom - top)),
                with: .color(Palette.honey.opacity(0.16))
            )

            var centre = Path()
            centre.move(to: CGPoint(x: 0, y: midY))
            centre.addLine(to: CGPoint(x: size.width, y: midY))
            context.stroke(centre, with: .color(Palette.nickel.opacity(0.55)), lineWidth: 1)

            for label in [("+50", 50.0), ("−50", -50.0)] {
                context.draw(
                    Text(label.0).font(Typeface.fixedData(12)).foregroundStyle(Palette.nickel.opacity(0.8)),
                    at: CGPoint(x: 15, y: yPosition(label.1) + (label.1 > 0 ? 8 : -8))
                )
            }

            let step = size.width / CGFloat(PitchTrace.capacity - 1)
            var line = Path()
            var isDrawing = false
            for age in 0..<PitchTrace.capacity {
                let value = trace.value(age: age)
                let x = size.width - CGFloat(age) * step
                guard !value.isNaN else {
                    isDrawing = false
                    continue
                }
                let point = CGPoint(x: x, y: yPosition(Double(value)))
                if isDrawing {
                    line.addLine(to: point)
                } else {
                    line.move(to: point)
                    isDrawing = true
                }
            }
            context.stroke(
                line,
                with: .color(inTune ? Palette.honey : Palette.amber),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
            )
        }
    }
}

/// The input's frequency content, with the note's overtones marked.
struct SpectrumReadout: View {
    @Environment(TunerModel.self) private var model

    var body: some View {
        let columns = model.live.spectrum
        let frequency = model.live.frequency

        Canvas { context, size in
            let plotHeight = size.height - 14
            let low = PitchEngine.spectrumLowFrequency
            let high = PitchEngine.spectrumHighFrequency
            let xPosition = { (value: Double) -> CGFloat in
                CGFloat(log(value / low) / log(high / low)) * size.width
            }

            if !columns.isEmpty {
                let width = size.width / CGFloat(columns.count)
                var area = Path()
                area.move(to: CGPoint(x: 0, y: plotHeight))
                for (index, value) in columns.enumerated() {
                    area.addLine(to: CGPoint(
                        x: CGFloat(index) * width,
                        y: plotHeight - CGFloat(value) * plotHeight
                    ))
                }
                area.addLine(to: CGPoint(x: size.width, y: plotHeight))
                area.closeSubpath()
                context.fill(
                    area,
                    with: .linearGradient(
                        Gradient(colors: [Palette.honey, Palette.amber, Palette.cherry.opacity(0.75)]),
                        startPoint: CGPoint(x: 0, y: 0),
                        endPoint: CGPoint(x: 0, y: plotHeight)
                    )
                )
            }

            if let frequency {
                for harmonic in 1...12 {
                    let value = frequency * Double(harmonic)
                    guard value < high else { break }
                    var marker = Path()
                    marker.move(to: CGPoint(x: xPosition(value), y: 0))
                    marker.addLine(to: CGPoint(x: xPosition(value), y: plotHeight))
                    context.stroke(
                        marker,
                        with: .color(Palette.pearl.opacity(harmonic == 1 ? 0.95 : 0.3)),
                        lineWidth: harmonic == 1 ? 1.5 : 1
                    )
                }
            }

            for (value, label) in [(50.0, "50"), (100, "100"), (200, "200"), (500, "500"), (1000, "1k"), (2000, "2k"), (5000, "5k")] {
                context.draw(
                    Text(label).font(Typeface.fixedData(12)).foregroundStyle(Palette.nickel),
                    at: CGPoint(x: xPosition(value), y: size.height - 5)
                )
            }
        }
    }
}
