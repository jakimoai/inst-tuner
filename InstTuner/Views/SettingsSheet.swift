import SwiftUI
import TunerCore

struct SettingsSheet: View {
    @Environment(TunerModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            Form {
                Section("Reference pitch") {
                    HStack {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("A4")
                                .font(Typeface.data(17))
                                .foregroundStyle(Palette.nickel)
                            Text(model.settings.a4.formatted(.number.precision(.fractionLength(1))))
                                .font(Typeface.data(34))
                                .monospacedDigit()
                                .foregroundStyle(Palette.pearl)
                            Text("Hz")
                                .font(Typeface.data(15))
                                .foregroundStyle(Palette.nickel)
                        }
                        .fixedSize()
                        Spacer()
                        Stepper("Reference pitch", value: $model.settings.a4, in: 390...490, step: 0.1)
                            .labelsHidden()
                    }

                    HStack(spacing: 8) {
                        ForEach([432.0, 440.0, 442.0, 444.0], id: \.self) { value in
                            Button {
                                model.settings.a4 = value
                            } label: {
                                Text("\(Int(value))")
                                    .font(Typeface.data(16))
                                    .foregroundStyle(model.settings.a4 == value ? Palette.ebony : Palette.pearl)
                                    .frame(maxWidth: .infinity, minHeight: 38)
                                    .background(
                                        Capsule().fill(model.settings.a4 == value ? Palette.honey : Palette.rosewood)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section {
                    NavigationLink {
                        TemperamentList()
                    } label: {
                        LabeledContent("Tuning system", value: temperamentSummary)
                    }
                }

                Section {
                    Picker("In-tune range", selection: $model.settings.toleranceCents) {
                        ForEach([0.5, 1.0, 2.0, 3.0, 5.0], id: \.self) { value in
                            Text("±\(value.formatted()) cents").tag(value)
                        }
                    }

                    Picker("Note names", selection: $model.settings.accidentals) {
                        Text("Sharps").tag(AccidentalStyle.sharps)
                        Text("Flats").tag(AccidentalStyle.flats)
                    }

                    Toggle("Vibrate when in tune", isOn: $model.settings.hapticsEnabled)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.ebony)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var temperamentSummary: String {
        let settings = model.settings
        guard settings.temperamentID != Temperament.equal.id,
              settings.temperamentID != Temperament.customID
        else { return settings.temperament.name }
        let key = Note.pitchClassName(settings.key, style: settings.accidentals)
        return "\(settings.temperament.name), \(key)"
    }
}

private struct TemperamentList: View {
    @Environment(TunerModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Form {
            Section {
                ForEach(Temperament.builtIn) { temperament in
                    selectionRow(temperament.name, id: temperament.id)
                }
                selectionRow("Custom", id: Temperament.customID)
            }

            // Custom offsets are set per note name, so a key would only move them around.
            if model.settings.temperamentID != Temperament.equal.id,
               model.settings.temperamentID != Temperament.customID {
                Section {
                    Picker("Key", selection: $model.settings.key) {
                        ForEach(0..<12, id: \.self) { pitchClass in
                            Text(Note.pitchClassName(pitchClass, style: model.settings.accidentals))
                                .tag(pitchClass)
                        }
                    }
                }
            }

            if model.settings.temperamentID == Temperament.customID {
                Section("Offset from equal, in cents") {
                    ForEach(0..<12, id: \.self) { pitchClass in
                        offsetRow(pitchClass)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.ebony)
        .navigationTitle("Tuning system")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func selectionRow(_ name: String, id: String) -> some View {
        Button {
            model.settings.temperamentID = id
        } label: {
            HStack {
                Text(name)
                    .foregroundStyle(Palette.pearl)
                Spacer()
                if model.settings.temperamentID == id {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.amber)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(model.settings.temperamentID == id ? .isSelected : [])
    }

    private func offsetRow(_ pitchClass: Int) -> some View {
        let binding = Binding<Double>(
            get: { model.settings.customTemperamentOffsets[pitchClass] },
            set: { model.settings.customTemperamentOffsets[pitchClass] = $0 }
        )
        return HStack {
            Text(Note.pitchClassName(pitchClass, style: model.settings.accidentals))
                .font(Typeface.data(18))
                .foregroundStyle(Palette.pearl)
                .frame(width: 40, alignment: .leading)
            Text(Format.cents(binding.wrappedValue))
                .font(Typeface.data(15))
                .monospacedDigit()
                .foregroundStyle(Palette.nickel)
            Spacer()
            if pitchClass == 9 {
                // A is the reference pitch, so it can't move.
                Text("Reference")
                    .font(Typeface.data(15))
                    .foregroundStyle(Palette.nickel)
            } else {
                Stepper("Offset", value: binding, in: -50...50, step: 0.5)
                    .labelsHidden()
            }
        }
    }
}
