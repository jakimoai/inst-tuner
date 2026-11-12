import SwiftUI
import TunerCore

struct TuningPickerSheet: View {
    @Environment(TunerModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var family = InstrumentFamily.guitar
    @State private var editing: Tuning?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(
                        id: TunerSettings.chromaticID,
                        title: "Chromatic",
                        detail: "Any note"
                    )
                }

                let custom = model.settings.customTunings.filter { $0.family == family }
                Section("Your tunings") {
                    ForEach(custom) { tuning in
                        row(id: tuning.id, title: tuning.name, detail: tuning.noteNames)
                            .swipeActions(edge: .trailing) {
                                Button("Delete", role: .destructive) {
                                    model.deleteCustomTuning(id: tuning.id)
                                }
                                Button("Edit") {
                                    editing = tuning
                                }
                                .tint(Palette.amber)
                            }
                    }

                    Button {
                        editing = newTuning()
                    } label: {
                        Label("New tuning", systemImage: "plus")
                    }
                }

                ForEach(TuningLibrary.sections(for: family)) { section in
                    Section(section.title) {
                        ForEach(section.tunings) { tuning in
                            row(id: tuning.id, title: tuning.name, detail: tuning.noteNames)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.ebony)
            .safeAreaInset(edge: .top) {
                Picker("Instrument", selection: $family) {
                    ForEach(InstrumentFamily.allCases, id: \.self) { family in
                        Text(family.name).tag(family)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .navigationTitle("Tuning")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                family = model.currentTuning?.family ?? model.settings.lastFamily
            }
            .onChange(of: family) { _, newFamily in
                model.rememberFamily(newFamily)
            }
            .sheet(item: $editing) { tuning in
                TuningEditor(draft: tuning) { saved in
                    model.saveCustomTuning(saved)
                    model.select(tuningID: saved.id)
                }
            }
        }
    }

    private func row(id: String, title: String, detail: String) -> some View {
        Button {
            model.select(tuningID: id)
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(Palette.pearl)
                    Text(detail)
                        .font(Typeface.data(14))
                        .foregroundStyle(Palette.nickel)
                }
                Spacer()
                if model.settings.selectedTuningID == id {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.amber)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(model.settings.selectedTuningID == id ? .isSelected : [])
    }

    private func newTuning() -> Tuning {
        let starting = model.currentTuning?.family == family ? model.currentTuning : nil
        let template = starting ?? TuningLibrary.sections(for: family)[0].tunings[0]
        return Tuning(
            id: "custom.\(UUID().uuidString)",
            name: "",
            family: family,
            strings: template.strings,
            prefersFlats: template.prefersFlats,
            isCustom: true
        )
    }
}

struct TuningEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: Tuning
    let onSave: (Tuning) -> Void

    /// G0. Anything lower is below what the tuner can hear.
    private let lowestMIDI = 19
    private let highestMIDI = 84
    private let maximumStrings = 12

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                }

                Section {
                    ForEach(draft.strings.indices, id: \.self) { index in
                        stringRow(index)
                    }

                    if draft.strings.count < maximumStrings {
                        Button {
                            let highest = draft.strings.last?.note.midi ?? 40
                            draft.strings.append(TuningString(note: Note(midi: min(highest + 5, highestMIDI))))
                        } label: {
                            Label("Add string", systemImage: "plus")
                        }
                    }
                } header: {
                    Text("Strings, lowest first")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.ebony)
            .navigationTitle(draft.name.isEmpty ? "New tuning" : draft.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var saved = draft
                        saved.name = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        if saved.name.isEmpty { saved.name = saved.noteNames }
                        onSave(saved)
                        dismiss()
                    }
                    .disabled(draft.strings.isEmpty)
                }
            }
        }
    }

    private func stringRow(_ index: Int) -> some View {
        let midi = Binding<Int>(
            get: { draft.strings[safe: index]?.note.midi ?? 40 },
            set: { value in
                guard draft.strings.indices.contains(index) else { return }
                draft.strings[index].note = Note(midi: value)
            }
        )
        let cents = Binding<Double>(
            get: { draft.strings[safe: index]?.cents ?? 0 },
            set: { value in
                guard draft.strings.indices.contains(index) else { return }
                draft.strings[index].cents = value
            }
        )
        let style: AccidentalStyle = draft.prefersFlats ? .flats : .sharps
        let note = Note(midi: midi.wrappedValue).spelled(style)

        return VStack(spacing: 6) {
            HStack {
                Text("\(note.name)\(note.octave)")
                    .font(Typeface.data(20))
                    .foregroundStyle(Palette.pearl)
                    .frame(width: 58, alignment: .leading)
                Stepper("Note", value: midi, in: lowestMIDI...highestMIDI)
                    .labelsHidden()
                Spacer()
                if draft.strings.count > 1 {
                    Button {
                        draft.strings.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(Palette.nickel)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove string")
                }
            }

            HStack {
                Text(Format.cents(cents.wrappedValue))
                    .font(Typeface.data(15))
                    .monospacedDigit()
                    .foregroundStyle(Palette.nickel)
                    .frame(width: 58, alignment: .leading)
                Stepper("Cents", value: cents, in: -50...50, step: 0.5)
                    .labelsHidden()
                Text("cents")
                    .font(Typeface.data(13))
                    .foregroundStyle(Palette.nickel)
                Spacer()
            }
        }
    }
}
