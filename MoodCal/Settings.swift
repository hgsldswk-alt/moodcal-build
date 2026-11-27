import SwiftUI
import StoreKit
import UniformTypeIdentifiers
import UIKit

extension UTType {
    static let moodBackup = UTType(exportedAs: "com.hgsldswk.moodcal.backup", conformingTo: .data)
    static let moodPalette = UTType(exportedAs: "com.hgsldswk.moodcal.palette", conformingTo: .data)
}

private enum SettingsRoute: String, Identifiable {
    case compare, palettes, importPalette, privacy, paywall
    var id: String { rawValue }
}

struct SettingsView: View {
    @ObservedObject var model: MoodModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.requestReview) private var requestReview
    @State private var destination: SettingsRoute?
    @State private var busy = false
    @State private var status: String?

    private var reminderTime: Date {
        let minute = model.history.preferences.reminderMinute
        return Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: .now) ?? .now
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "settings.title") { dismiss() }.padding(.horizontal, 20).padding(.top, 12)
            Form {
                Section(L.t("settings.data")) {
                    Button(L.t("data.export")) { Task { await exportHistory() } }.accessibilityIdentifier("settings.export")
                    BackupRestoreButton(model: model, identifier: "settings.restore")
                    ShareFeedback(model: model)
                    if let status { Text(L.t(status)).font(.footnote).accessibilityIdentifier("data.status") }
                    if let error = model.error { Text(L.t(error)).font(.footnote).foregroundStyle(.red) }
                }.disabled(busy || model.working || !model.ready)
                Section(L.t("settings.display")) {
                    Button(L.t("compare.title")) { destination = model.hasPro ? .compare : .paywall }
                        .accessibilityIdentifier("settings.compare").disabled(model.proWaiting)
                    Button(L.t("palette.title")) { destination = .palettes }.accessibilityIdentifier("settings.palettes")
                    Button(L.t("palette.import")) { destination = .importPalette }.accessibilityIdentifier("settings.importPalette")
                }
                Section(L.t("settings.reminders")) {
                    Toggle(L.t("reminder.toggle"), isOn: Binding(get: { model.history.preferences.reminder }, set: { value in
                        Task { await model.setReminder(value, minute: model.history.preferences.reminderMinute) }
                    })).accessibilityIdentifier("settings.reminder").disabled(model.working)
                    if model.history.preferences.reminder {
                        DatePicker(L.t("reminder.time"), selection: Binding(get: { reminderTime }, set: { date in
                            let clock = Calendar.current.dateComponents([.hour, .minute], from: date)
                            Task { await model.setReminder(true, minute: (clock.hour ?? 21) * 60 + (clock.minute ?? 0)) }
                        }), displayedComponents: .hourAndMinute).accessibilityIdentifier("settings.reminderTime")
                    }
                    if let status = model.reminderStatus { Text(L.t(status)).font(.footnote).accessibilityIdentifier("reminder.status") }
                }
                Section(L.t("settings.about")) {
                    Button(L.t("privacy.title")) { destination = .privacy }.accessibilityIdentifier("settings.privacy")
                    Button(L.t("settings.rate")) { if !Launch.testing { requestReview() } }.accessibilityIdentifier("settings.rate")
                    if model.showPlans {
                        Button(L.t("store.title")) { destination = .paywall }.accessibilityIdentifier("settings.pro")
                        Button(L.t("store.restore")) { Task { await model.restorePurchases() } }
                            .accessibilityIdentifier("settings.restorePurchases").disabled(model.storeBusy || model.proWaiting)
                        if let status = model.purchaseStatus { Text(L.t(status)).font(.footnote).accessibilityIdentifier("store.status") }
                    }
                }
            }.scrollContentBackground(.hidden)
        }.background(Paper.background.ignoresSafeArea()).foregroundStyle(Paper.ink).tint(Paper.green)
            .onAppear { model.shareRequested = false }
            .sheet(item: $destination) { route in
                switch route {
                case .compare: ComparisonView(model: model)
                case .palettes: PalettesView(model: model)
                case .importPalette: PaletteImport(model: model)
                case .paywall: Paywall(model: model)
                case .privacy: PrivacyView()
                }
            }
            .activitySheet(model: model, route: .history)
            .interactiveDismissDisabled(busy || model.working)
    }

    private func exportHistory() async {
        busy = true
        status = nil
        model.shareRequested = false
        defer { busy = false }
        let snapshot = model.history
        do { model.requestShare(try await Task.detached { try Transfer.historyFiles(snapshot) }.value, route: .history) }
        catch { status = "share.failed" }
    }}

struct BackupRestoreButton: View {
    @ObservedObject var model: MoodModel
    let identifier: String
    @State private var filePicker = false
    @State private var backup: MoodBackup?
    @State private var newEntries = 0
    @State private var conflicts = 0
    @State private var confirmation = false
    @State private var busy = false
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading) {
            Button(L.t("data.restore")) {
                if Launch.has("-fixture-import"), let text = ProcessInfo.processInfo.environment["MOOD_BACKUP"] {
                    Task { await readBackup { Data(text.utf8) } }
                } else { filePicker = true }
            }.accessibilityIdentifier(identifier).frame(minHeight: 44)
            if let status { Text(L.t(status)).font(.footnote).accessibilityIdentifier("restore.status") }
        }.disabled(busy || model.working || !model.ready)
            .fileImporter(isPresented: $filePicker, allowedContentTypes: [.moodBackup, .data]) { result in
                switch result {
                case .success(let url): Task { await readBackup { try Transfer.file(url, max: Transfer.backupLimit) } }
                case .failure: status = "error.invalid"
                }
            }
            .alert(L.t("data.restore"), isPresented: $confirmation) {
                Button(L.t("data.merge")) {
                    if let backup { Task { status = await model.restore(backup) ? "data.restored" : (model.error ?? "error.invalid"); self.backup = nil } }
                }
                Button(L.t("action.cancel"), role: .cancel) { backup = nil }
            } message: { Text(L.f("data.summary", newEntries, conflicts)) }
    }

    private func readBackup(_ read: @escaping @Sendable () throws -> Data) async {
        busy = true
        status = nil
        defer { busy = false }
        do {
            let parsed = try await Task.detached { try MoodBackup.read(read()) }.value
            let summary = model.history.preview(parsed)
            backup = parsed
            newEntries = summary.new
            conflicts = summary.conflicts
            confirmation = true
        } catch { status = (error as? MoodFailure)?.rawValue ?? "error.invalid" }
    }
}

struct PrivacyView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SheetHeader(title: "privacy.title") { dismiss() }
                Text(L.t("privacy.body"))
            }.padding(20)
        }.background(Paper.background.ignoresSafeArea()).foregroundStyle(Paper.ink)
    }
}

struct ComparisonView: View {
    @ObservedObject var model: MoodModel
    @Environment(\.dismiss) private var dismiss
    @State private var first: String?
    @State private var second: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SheetHeader(title: "compare.title") { dismiss() }
                let thisMonth = Days.month(model.today)
                if model.hasPro {
                    stats(first ?? Days.shift(thisMonth, -1), id: "first") { first = $0 }
                    stats(second ?? thisMonth, id: "second") { second = $0 }
                }
            }.padding(20)
        }.background(Paper.background.ignoresSafeArea()).foregroundStyle(Paper.ink)
            .onChange(of: model.hasPro) { _, value in if !value { dismiss() } }
    }

    private func stats(_ month: String, id: String, change: @escaping (String) -> Void) -> some View {
        let entries = model.entries(in: month)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                IconButton(symbol: "chevron.left", title: "calendar.previous", id: "compare.\(id).previous") { change(Days.shift(month, -1)) }
                Text(Days.format(month + "-01", "yMMMM")).font(.headline)
                Spacer()
                IconButton(symbol: "chevron.right", title: "calendar.next", id: "compare.\(id).next") { change(Days.shift(month, 1)) }
                    .disabled(month >= Days.month(model.today))
            }
            Text(L.f("calendar.count", entries.count)).font(.footnote)
            ForEach(1...5, id: \.self) { level in
                let count = entries.filter { $0.level == level }.count
                HStack {
                    Text(L.mood(level)).font(.footnote)
                    Spacer()
                    Text(String(count)).font(.footnote.monospacedDigit())
                }
                ProgressView(value: Double(count), total: Double(max(entries.count, 1))).tint(Paper.color(model.palette.colors[level - 1]))
                    .accessibilityHidden(true)
            }
        }.padding(14).background(Paper.surface, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct Paywall: View {
    @ObservedObject var model: MoodModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                SheetHeader(title: "store.title") { dismiss() }
                Text(L.t("store.headline")).font(.system(.largeTitle, design: .serif).weight(.semibold))
                if model.entitlement.purchasedPro { Text(L.t("store.unlocked")) }
                else if model.trialActive { Text(L.f("store.trialActive", model.entitlement.trialEnd.formatted(date: .abbreviated, time: .omitted))) }
                else if model.entitlementReady { Text(L.t("store.expired")) }
                Text(L.t("store.freeFeatures")).font(.subheadline)
                ForEach(["compare.title", "palette.custom", "share.long"], id: \.self) { key in
                    Label(L.t(key), systemImage: "checkmark.circle").font(.subheadline)
                }
                if !model.entitlement.purchasedPro {
                    Button {
                        Task { await model.purchase(MoodModel.proID) }
                    } label: {
                        Text(model.products[MoodModel.proID].map { L.f("store.buyPrice", $0.displayPrice) }
                             ?? (Launch.has("-paywall") ? L.f("store.buyPrice", "US$2.99") : L.t("store.buy")))
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("store.buy")
                    if model.trialActive && model.entitlement.trialClaimedAt == nil {
                        Button { Task { await model.purchase(MoodModel.trialID) } } label: {
                            Text(L.t("store.claim")).frame(minHeight: 44).contentShape(Rectangle())
                        }
                            .accessibilityIdentifier("store.claim")
                    }
                }
                Button { Task { await model.restorePurchases() } } label: {
                    Text(L.t("store.restore")).frame(minHeight: 44).contentShape(Rectangle())
                }
                    .accessibilityIdentifier("store.restore")
                if let status = model.purchaseStatus { Text(L.t(status)).font(.footnote).accessibilityIdentifier("store.status") }
                Text(L.t("store.noRenewal")).font(.footnote).foregroundStyle(Paper.muted)
            }.padding(20).disabled(model.storeBusy)
        }.background(Paper.background.ignoresSafeArea()).foregroundStyle(Paper.ink).tint(Paper.green)
            .task { await model.loadProducts() }
    }
}
