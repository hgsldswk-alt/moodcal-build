import SwiftUI

struct NoteView: View {
    @ObservedObject var model: MoodModel
    let entry: MoodEntry
    @State private var note: String
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    init(model: MoodModel, entry: MoodEntry) {
        self.model = model
        self.entry = entry
        _note = State(initialValue: entry.note ?? "")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SheetHeader(title: "note.add") { dismiss() }
                TextEditor(text: $note).frame(minHeight: 112).scrollContentBackground(.hidden)
                    .padding(8).background(Paper.surface, in: RoundedRectangle(cornerRadius: 12))
                    .focused($focused).accessibilityLabel(Text(L.t("note.label"))).accessibilityIdentifier("note.input")
                    .onChange(of: note) { _, value in if value.count > 280 { note = String(value.prefix(280)) } }
                Text(L.f("note.count", note.count)).font(.footnote).foregroundStyle(Paper.muted)
                    .accessibilityIdentifier("note.count")
                if let error = model.error { Text(L.t(error)).foregroundStyle(.red) }
                Button(L.t("action.done")) {
                    var updated = entry
                    updated.note = note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : note
                    Task { if await model.edit(updated) { dismiss() } }
                }.buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("note.done").disabled(model.working)
            }.padding(20)
        }.background(Paper.background.ignoresSafeArea()).foregroundStyle(Paper.ink).tint(Paper.green)
            .task { focused = true }.presentationDetents([.medium, .large])
            .interactiveDismissDisabled(model.working)
    }
}

struct EditView: View {
    @ObservedObject var model: MoodModel
    let entry: MoodEntry
    @Environment(\.dismiss) private var dismiss
    @State private var dateMode = false
    @State private var noteMode = false
    @State private var deleting = false
    @State private var month: String?

    private var current: MoodEntry { model.history.entries.first { $0.id == entry.id } ?? entry }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SheetHeader(title: dateMode ? "entry.date" : "entry.edit") { if dateMode { dateMode = false } else { dismiss() } }
                if let error = model.error { Text(L.t(error)).foregroundStyle(.red) }
                if dateMode { datePicker }
                else {
                    Text(Days.format(current.dayKey, "yMMMMEEEEd") + " · " + Days.clock(current.minuteOfDay)).font(.subheadline)
                    MoodButtons(palette: model.palette, selected: current.level, prefix: "edit.mood") { level in
                        var updated = current
                        updated.level = level
                        Task { if await model.edit(updated) { dismiss() } }
                    }.disabled(model.working)
                    if let note = current.note {
                        Text(note).accessibilityIdentifier("edit.note.content")
                    }
                    Button(L.t(current.note == nil ? "note.add" : "note.edit")) { noteMode = true }.accessibilityIdentifier("edit.note")
                    Button(L.t("entry.date")) { month = Days.month(current.dayKey); dateMode = true }.accessibilityIdentifier("edit.date")
                    Button(L.t("action.delete"), role: .destructive) { deleting = true }.accessibilityIdentifier("edit.delete")
                }
            }.padding(20)
        }.background(Paper.background.ignoresSafeArea()).foregroundStyle(Paper.ink).tint(Paper.green)
            .sheet(isPresented: $noteMode) { NoteView(model: model, entry: current) }
            .interactiveDismissDisabled(model.working)
            .alert(L.t("entry.deleteConfirm"), isPresented: $deleting) {
                Button(L.t("action.delete"), role: .destructive) {
                    Task { await model.delete(current); if model.error == nil { dismiss() } }
                }
                Button(L.t("action.cancel"), role: .cancel) {}
            }
    }

    private var datePicker: some View {
        let month = month ?? Days.month(current.dayKey)
        return VStack(spacing: 8) {
            HStack {
                Text(Days.format(month + "-01", "yMMMM")).font(.headline)
                Spacer()
                IconButton(symbol: "chevron.left", title: "calendar.previous", id: "move.previous") { self.month = Days.shift(month, -1) }
                IconButton(symbol: "chevron.right", title: "calendar.next", id: "move.next") { self.month = Days.shift(month, 1) }
                    .disabled(month >= Days.month(model.today))
            }
            MonthGrid(month: month, today: model.today, selected: current.dayKey, latest: model.daily, counts: model.counts,
                      palette: model.palette, prefix: "move.day") { key in
                var updated = current
                updated.dayKey = key
                Task { if await model.edit(updated) { dismiss() } }
            }.disabled(model.working)
        }
    }
}
