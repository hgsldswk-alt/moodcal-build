import SwiftUI
import StoreKit
import UIKit

@main
@MainActor
struct MoodCalApp: App {
    var body: some Scene { WindowGroup { HomeView().preferredColorScheme(.light) } }
}

enum HomeSheet: Identifiable {
    case settings, importPalette, edit(MoodEntry), note(MoodEntry), card(Int?), paywall
    var id: String {
        switch self {
        case .settings: return "settings"
        case .importPalette: return "importPalette"
        case .edit(let entry): return "edit-" + entry.id.uuidString
        case .note(let entry): return "note-" + entry.id.uuidString
        case .card: return "card"
        case .paywall: return "paywall"
        }
    }
}

@MainActor
struct HomeView: View {
    @StateObject private var model = MoodModel()
    @State private var sheet: HomeSheet?
    @Environment(\.scenePhase) private var phase
    @Environment(\.requestReview) private var requestReview

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(L.t("app.name")).font(.system(.largeTitle, design: .serif).weight(.semibold)).accessibilityAddTraits(.isHeader)
                    Spacer()
                    IconButton(symbol: "slider.horizontal.3", title: "settings.title", id: "home.settings") { sheet = .settings }
                }
                entryPanel
                HStack(alignment: .top, spacing: 16) { transferActions }
                    .font(.footnote.weight(.semibold)).buttonStyle(.borderless)
                calendarPanel
                records
                if Launch.has("-clock-controls") {
                    Button(L.t("test.nextDay")) { Task { await model.advanceDemoDay() } }.accessibilityIdentifier("test.nextDay")
                }
            }.padding(.horizontal, 16).padding(.vertical, 8)
        }
        .foregroundStyle(Paper.ink).background(Paper.background.ignoresSafeArea()).tint(Paper.green)
        .task {
            await model.start()
            await model.scheduleReminder()
            if Launch.has("-paywall") { sheet = .paywall }
        }
        .task { await model.startEntitlements() }
        .reviewAfterCoreAction(when: reviewHome, alreadyRequested: model.reviewedThisVersion) { requestReview(); model.markReviewRequested() }
        .task { await model.startClock() }
        .onChange(of: phase) { _, value in
            if value == .active { Task { await model.clockChanged(); await model.scheduleReminder() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            Task { await model.clockChanged(); await model.scheduleReminder() }
        }
        .sheet(item: $sheet, onDismiss: { model.shareRequested = false }) { destination in
            switch destination {
            case .settings: SettingsView(model: model)
            case .importPalette: PaletteImport(model: model)
            case .edit(let entry): EditView(model: model, entry: entry)
            case .note(let entry): NoteView(model: model, entry: entry)
            case .card(let milestone): CardPreview(model: model, month: model.month, milestone: milestone)
            case .paywall: Paywall(model: model)
            }
        }
    }

    private var reviewHome: Bool {
        sheet == nil && model.ready && !model.working && model.error == nil && model.milestone == nil
            && model.shareRequest == nil && !model.canUndo
    }

    @ViewBuilder
    private var transferActions: some View {
        Button { sheet = .importPalette } label: {
            Text(L.t("palette.import")).frame(minHeight: 44).contentShape(Rectangle())
        }
            .accessibilityIdentifier("home.importPalette")
        BackupRestoreButton(model: model, identifier: "home.restore")
    }

    private var entryPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(Days.format(model.target, "MMMMdEEE")).font(.footnote.weight(.semibold)).accessibilityIdentifier("home.target")
                Spacer()
                if model.selected != nil || model.browseMonth != nil {
                    Button(L.t("home.today")) { model.goToday() }.font(.footnote.bold()).frame(minHeight: 44).accessibilityIdentifier("home.today")
                }
            }
            Text(L.t(model.selected == nil ? "home.question" : "home.pastQuestion"))
                .font(.system(.title2, design: .serif).weight(.semibold)).accessibilityAddTraits(.isHeader)
            MoodButtons(palette: model.palette, selected: model.daily[model.target]?.level, prefix: "mood") { level in
                Task { await model.record(level) }
            }.disabled(!model.ready || model.working || model.target > model.today)
            if let error = model.error {
                HStack {
                    Text(L.t(error)).accessibilityIdentifier("home.error")
                    Spacer()
                    if model.canRetry {
                        Button { Task { await model.retryWrite() } } label: {
                            Text(L.t("action.retry")).frame(minHeight: 44).contentShape(Rectangle())
                        }.accessibilityIdentifier("home.retry")
                    } else { Button(L.t("action.close")) { model.dismissError() }.accessibilityIdentifier("home.dismissError") }
                }.font(.footnote)
            } else if let saved = model.saved, saved.dayKey == model.target {
                ViewThatFits(in: .horizontal) {
                    HStack { savedLabel(saved); Spacer(minLength: 3); savedActions(saved) }
                    VStack(alignment: .leading, spacing: 0) { savedLabel(saved); savedActions(saved) }
                }
            } else {
                Text(L.t(model.ready ? "home.tip" : "home.loading")).font(.footnote).foregroundStyle(Paper.muted).frame(minHeight: 28)
            }
            if let milestone = model.milestone {
                HStack {
                    Button {
                        sheet = .card(milestone); model.milestone = nil
                    } label: {
                        Text(L.f("milestone.prompt", milestone)).frame(minHeight: 44).contentShape(Rectangle())
                    }.accessibilityIdentifier("home.milestone")
                    Spacer()
                    IconButton(symbol: "xmark", title: "action.close", id: "milestone.dismiss") { model.milestone = nil }
                }.font(.footnote.weight(.semibold))
            }
        }.padding(12).background(Paper.surface, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Paper.border))
    }

    private func savedLabel(_ entry: MoodEntry) -> some View {
        Label(L.f("home.saved", L.mood(entry.level)), systemImage: "checkmark").font(.footnote.weight(.semibold))
            .accessibilityIdentifier("home.saved")
    }

    private func savedActions(_ entry: MoodEntry) -> some View {
        HStack(spacing: 8) {
            if model.canUndo {
                Button { Task { await model.undo() } } label: {
                    Text(L.t("action.undo")).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }.accessibilityIdentifier("home.undo")
            }
            Button { sheet = .note(entry) } label: {
                Text(L.t("note.add")).frame(minHeight: 44).contentShape(Rectangle())
            }.accessibilityIdentifier("home.note")
        }.font(.footnote.weight(.semibold)).disabled(model.working)
    }

    private var calendarPanel: some View {
        let month = model.month
        let monthsToday = Days.month(model.today)
        let entries = model.entries(in: month)
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(Days.format(month + "-01", "yMMMM")).font(.title2.bold()).accessibilityIdentifier("calendar.month")
                Spacer()
                IconButton(symbol: "chevron.left", title: "calendar.previous", id: "calendar.previous") { model.browseMonth = Days.shift(month, -1) }
                IconButton(symbol: "chevron.right", title: "calendar.next", id: "calendar.next") { model.browseMonth = Days.shift(month, 1) }
                    .disabled(month >= monthsToday).opacity(month >= monthsToday ? 0.45 : 1)
            }
            MonthGrid(month: month, today: model.today, selected: model.target, latest: model.daily, counts: model.counts,
                      palette: model.palette, prefix: "day") { day in
                let canPrompt = model.saved == nil && model.daily[day] != nil
                model.select(day)
                if day < model.today && canPrompt && reviewHome && phase == .active {
                    model.requestCalendarReview { requestReview() }
                }
            }.disabled(model.working || !model.ready)
            Divider()
            HStack {
                Text(L.f("calendar.count", entries.count)).font(.footnote).accessibilityIdentifier("calendar.count")
                Spacer()
                Button { model.shareRequested = false; sheet = .card(nil) } label: {
                    Label(L.t("share.make"), systemImage: "square.and.arrow.up").font(.footnote.weight(.semibold)).frame(minHeight: 44)
                }.accessibilityIdentifier("home.share").disabled(!model.ready || model.working || entries.isEmpty)
            }
        }
    }

    private var records: some View {
        VStack(alignment: .leading, spacing: 6) {
            let entries = model.entries(for: model.target)
            if !entries.isEmpty {
                Text(L.t("entry.list")).font(.footnote.weight(.semibold)).accessibilityAddTraits(.isHeader)
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    let mood = L.mood(entry.level)
                    let time = Days.clock(entry.minuteOfDay)
                    let labelParts = [mood, entry.note ?? "", time]
                    Button { sheet = .edit(entry) } label: {
                        HStack {
                            Circle().fill(Paper.color(model.palette.colors[entry.level - 1])).frame(width: 9, height: 9)
                            VStack(alignment: .leading) {
                                Text(mood).font(.subheadline.weight(.semibold))
                                if let note = entry.note, !note.isEmpty { Text(note).font(.footnote).lineLimit(2) }
                            }
                            Spacer()
                            Text(time).font(.footnote.monospacedDigit())
                            Image(systemName: "chevron.right").font(.caption2)
                        }.padding(.horizontal, 10).frame(minHeight: 44)
                            .background(Paper.surface, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Paper.border))
                    }.buttonStyle(.plain)
                        .accessibilityLabel(Text(verbatim: labelParts.filter { !$0.isEmpty }.joined(separator: ", ")))
                        .accessibilityIdentifier("entry.\(index)")
                }
            }
        }
    }
}
