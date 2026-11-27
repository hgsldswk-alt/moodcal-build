import SwiftUI
import StoreKit
import UserNotifications

enum ShareRoute: Equatable { case card, history, palette }

struct ShareRequest: Equatable {
    let files: [URL]
    let route: ShareRoute
}

@MainActor
final class MoodModel: ObservableObject {
    static let proID = "com.hgsldswk.moodcal.pro"
    static let trialID = "com.hgsldswk.moodcal.trial"

    @Published private(set) var history = MoodHistory()
    @Published private var index = MoodIndex()
    @Published private(set) var ready = false
    @Published private(set) var working = false
    @Published private(set) var today = Days.key(Launch.now)
    @Published var selected: String?
    @Published var browseMonth: String?
    @Published var error: String?
    @Published private(set) var saved: MoodEntry?
    @Published private(set) var canUndo = false
    @Published var milestone: Int?
    @Published private(set) var entitlement = Entitlement()
    @Published private(set) var entitlementReady = false
    @Published var products = [String: Product]()
    @Published var storeBusy = false
    @Published var purchaseStatus: String?
    @Published var reminderStatus: String?
    @Published var shareRequested = false
    @Published var shareRequest: ShareRequest?

    private let store = MoodStore(url: MoodStore.location(testing: Launch.testing))
    private let vault = EntitlementVault()
    private var undoTask: Task<Void, Never>?
    private var transactionTask: Task<Void, Never>?
    private var resetProcessed = false
    private var retry: (() async -> Void)?
    private var priorDays = 0
    private var ratingAsked = false
    private var demoOffset = 0

    var now: Date { Launch.now.addingTimeInterval(Double(demoOffset) * 86_400) }
    var target: String { selected ?? today }
    var month: String { browseMonth ?? Days.month(target) }
    var hasPro: Bool { Launch.isFree || (entitlementReady && !Launch.has("-expired") && entitlement.hasPro(at: now)) }
    var proWaiting: Bool { !Launch.isFree && !entitlementReady }
    var showPlans: Bool { !Launch.isFree && !Launch.has("-demo-store") }
    var canRetry: Bool { retry != nil }
    var palette: MoodPalette { history.preferences.palette }
    var trialActive: Bool { hasPro && !entitlement.purchasedPro }
    var daily: [String: MoodEntry] { index.latest }
    var counts: [String: Int] { index.counts }
    var recordedMonths: [String] { index.byMonth.keys.sorted() }

    func start() async {
        if !ready && !working {
            working = true
            defer { working = false }
            do {
                if Launch.has("-reset") && !resetProcessed {
                    let url = MoodStore.location(testing: true).deletingLastPathComponent()
                    try await Task.detached {
                        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                    }.value
                    resetProcessed = true
                }
                var loaded = try await store.load()
                if Launch.has("-seed") && loaded.entries.isEmpty {
                    let seed = Self.demo()
                    try await store.save(from: loaded, to: seed)
                    loaded = seed
                }
                let snapshot = loaded
                index = await Task.detached { MoodIndex(snapshot) }.value
                history = loaded
                priorDays = daily.count
                ready = true
                error = nil
                retry = nil
            } catch {
                self.error = "error.open"
                retry = { [weak self] in await self?.start() }
            }
        }
    }

    func startEntitlements() async {
        guard !entitlementReady else { return }
        let launchedAt = now
        let stored = Launch.testing ? nil : await vault.load()
        entitlement = stored ?? Entitlement(firstOpen: launchedAt)
        entitlement.observe(launchedAt, free: Launch.isFree)
        await persistEntitlement()
        entitlementReady = true
        guard !Launch.isFree && !Launch.testing else { return }
        transactionTask = Task { [weak self] in
            for await result in StoreKit.Transaction.updates { await self?.apply(result, finish: true) }
        }
        await refreshPurchases()
    }

    private func persistEntitlement() async {
        guard !Launch.testing else { return }
        await vault.save(entitlement)
    }

    func clockChanged() async {
        today = Days.key(now)
        if entitlementReady {
            var updated = entitlement
            updated.observe(now, free: Launch.isFree)
            if updated != entitlement { entitlement = updated; await persistEntitlement() }
        }
    }

    func startClock() async {
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            let prior = today
            await clockChanged()
            if prior != today { await scheduleReminder() }
        }
    }

    func advanceDemoDay() async {
        guard Launch.has("-clock-controls") else { return }
        demoOffset += 1
        await clockChanged()
    }

    private static func demo() -> MoodHistory {
        let month = Days.month(Days.key(Launch.now))
        let sample = [1: 3, 2: 4, 3: 2, 4: 3, 5: 4, 7: 5, 8: 3, 9: 2, 10: 4, 12: 2, 13: 1, 14: 4, 16: 3, 17: 5, 18: 4]
        let entries = sample.map { day, level in
            MoodEntry(dayKey: month + String(format: "-%02d", day), level: level, now: Launch.now)
        }
        var preferences = Preferences()
        preferences.milestones = [7]
        return MoodHistory(entries: entries, preferences: preferences)
    }

    @discardableResult
    private func commit(_ next: MoodHistory, celebrate: Bool = false, retryAction: (() async -> Void)? = nil) async -> Bool {
        guard ready && !working else { return false }
        working = true
        defer { working = false }
        var proposed = next
        let snapshot = proposed
        let index = await Task.detached { MoodIndex(snapshot) }.value
        let hits = celebrate ? [7, 30].filter { index.latest.count >= $0 && !proposed.preferences.milestones.contains($0) } : []
        proposed.preferences.milestones.formUnion(hits)
        do {
            try await store.save(from: history, to: proposed)
            history = proposed
            self.index = index
            if let hit = hits.last { milestone = hit }
            retry = nil
            error = nil
            return true
        } catch {
            self.error = "error.write"
            retry = retryAction
            return false
        }
    }

    func retryWrite() async { await retry?() }
    func dismissError() { error = nil; retry = nil }

    func entries(for day: String) -> [MoodEntry] {
        index.byDay[day] ?? []
    }

    func entries(in month: String) -> [MoodEntry] {
        index.byMonth[month] ?? []
    }

    func record(_ level: Int) async {
        let timestamp = now
        let date = selected ?? Days.key(timestamp)
        guard date <= Days.key(timestamp) else { return }
        await add(MoodEntry(dayKey: date, level: level, now: timestamp))
    }

    private func add(_ entry: MoodEntry) async {
        var next = history
        next.entries.append(entry)
        guard await commit(next, celebrate: true, retryAction: { [weak self] in await self?.add(entry) }) else { return }
        if selected == nil { browseMonth = nil; today = Days.key(now) }
        saved = entry
        CoreReview.shared.record()
        canUndo = true
        undoTask?.cancel()
        undoTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(Launch.has("-hold-undo") ? 15 : 3)) } catch { return }
            self?.canUndo = false
        }
    }

    func undo() async {
        guard canUndo, let saved else { return }
        await delete(saved)
    }

    func goToday() { selected = nil; browseMonth = nil; saved = nil; canUndo = false }
    func select(_ day: String) {
        if day == today { goToday(); return }
        selected = day
        browseMonth = Days.month(day)
        saved = nil
        canUndo = false
    }

    func edit(_ entry: MoodEntry) async -> Bool {
        guard entry.dayKey <= Days.key(now), let index = history.entries.firstIndex(where: { $0.id == entry.id }) else { return false }
        var entry = entry
        entry.updatedAt = now
        let edited = entry
        var next = history
        next.entries[index] = edited
        let success = await commit(next, celebrate: true, retryAction: { [weak self] in _ = await self?.edit(edited) })
        if success && saved?.id == edited.id { saved = edited }
        return success
    }

    func delete(_ entry: MoodEntry) async {
        var next = history
        next.entries.removeAll { $0.id == entry.id }
        if await commit(next, retryAction: { [weak self] in await self?.delete(entry) }), saved?.id == entry.id {
            saved = nil
            canUndo = false
        }
    }

    func restore(_ backup: MoodBackup) async -> Bool {
        let current = history
        let next = await Task.detached {
            var result = current
            result.merge(backup)
            return result
        }.value
        guard history == current else { return await restore(backup) }
        let success = await commit(next, retryAction: { [weak self] in _ = await self?.restore(backup) })
        if success { await scheduleReminder() }
        return success
    }

    func setPalette(_ palette: MoodPalette?) async -> Bool {
        guard palette == nil || hasPro else { return false }
        var next = history
        if let palette {
            guard palette.valid else { error = "error.invalid"; return false }
            if let existing = next.preferences.palettes.firstIndex(where: { $0.id == palette.id }) { next.preferences.palettes[existing] = palette }
            else { next.preferences.palettes.append(palette) }
        }
        next.preferences.active = palette?.id
        return await commit(next, retryAction: { [weak self] in _ = await self?.setPalette(palette) })
    }

    var reviewVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1" }
    var legacyReviewVersion: String { String(reviewVersion.split(separator: ".").first ?? "1") }
    var reviewedThisVersion: Bool {
        let recorded = history.preferences.ratedVersion
        return recorded == reviewVersion || recorded == legacyReviewVersion
    }

    func requestCalendarReview(_ request: () -> Void) {
        guard !Launch.testing, !ratingAsked, !working, error == nil, saved == nil, milestone == nil, shareRequest == nil,
              !reviewedThisVersion, daily.count >= 7, priorDays >= 7,
              history.preferences.canRequestRating(now: now, version: legacyReviewVersion),
              CoreReview.shared.attempt(request) else { return }
        markReviewRequested()
    }

    func markReviewRequested() {
        ratingAsked = true
        var next = history
        next.preferences.ratedAt = now
        next.preferences.ratedVersion = reviewVersion
        Task { _ = await commit(next) }
    }

    func setReminder(_ enabled: Bool, minute: Int) async {
        var next = history
        next.preferences.reminder = enabled
        next.preferences.reminderMinute = minute
        if await commit(next) { await scheduleReminder(prompt: enabled) }
    }

    func scheduleReminder(prompt: Bool = false) async {
        if Launch.has("-deny-notifications") {
            reminderStatus = history.preferences.reminder ? "reminder.denied" : nil
            return
        }
        guard !Launch.testing else { return }
        let center = UNUserNotificationCenter.current()
        let preferences = history.preferences
        center.removePendingNotificationRequests(withIdentifiers: ["mood.daily"])
        reminderStatus = nil
        guard preferences.reminder else { return }
        do {
            let settings = await center.notificationSettings()
            let allowed: Bool
            switch settings.authorizationStatus {
            case .notDetermined: allowed = prompt ? try await center.requestAuthorization(options: [.alert, .sound]) : false
            case .denied: allowed = false
            default: allowed = true
            }
            guard history.preferences.reminder == preferences.reminder,
                  history.preferences.reminderMinute == preferences.reminderMinute else { return }
            guard allowed else { reminderStatus = "reminder.denied"; return }
            let content = UNMutableNotificationContent()
            content.body = L.t("reminder.body")
            let parts = DateComponents(hour: preferences.reminderMinute / 60, minute: preferences.reminderMinute % 60)
            try await center.add(UNNotificationRequest(identifier: "mood.daily", content: content,
                                                       trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: true)))
        } catch { reminderStatus = "reminder.error" }
    }

    func requestShare(_ files: [URL], route: ShareRoute) {
        if Launch.testing {
            shareRequested = true
            Task.detached {
                for folder in Set(files.map { $0.deletingLastPathComponent() }) { try? FileManager.default.removeItem(at: folder) }
            }
        } else { shareRequest = ShareRequest(files: files, route: route) }
    }

    func loadProducts() async {
        guard !Launch.isFree && !Launch.testing else { return }
        let missing = [Self.proID, Self.trialID].filter { products[$0] == nil }
        guard !missing.isEmpty else { return }
        do {
            for product in try await Product.products(for: missing) { products[product.id] = product }
        }
        catch { purchaseStatus = "store.unavailable" }
    }

    private func apply(_ result: VerificationResult<StoreKit.Transaction>, finish: Bool = false) async {
        guard case .verified(let transaction) = result, transaction.productType == .nonConsumable else { return }
        let before = entitlement
        switch transaction.productID {
        case Self.proID: entitlement.verifyPurchase(revoked: transaction.revocationDate != nil)
        case Self.trialID: entitlement.verifyTrial(transaction.originalPurchaseDate, revoked: transaction.revocationDate != nil)
        default: return
        }
        if before != entitlement { await persistEntitlement() }
        if finish { await transaction.finish() }
    }

    private func refreshPurchases(authoritative: Bool = false) async {
        if let pro = await StoreKit.Transaction.latest(for: Self.proID) { await apply(pro) }
        else if authoritative { entitlement.purchasedPro = false; await persistEntitlement() }
        if let trial = await StoreKit.Transaction.latest(for: Self.trialID) { await apply(trial) }
    }

    func purchase(_ id: String) async {
        guard !storeBusy && !Launch.isFree else { return }
        storeBusy = true
        purchaseStatus = nil
        defer { storeBusy = false }
        if products[id] == nil { await loadProducts() }
        guard let product = products[id] else { purchaseStatus = "store.unavailable"; return }
        do {
            switch try await product.purchase() {
            case .success(let result):
                guard case .verified = result else { purchaseStatus = "store.failed"; return }
                await apply(result, finish: true)
                purchaseStatus = id == Self.proID ? "store.unlocked" : "store.claimed"
            case .pending: purchaseStatus = "store.pending"
            case .userCancelled: break
            @unknown default: purchaseStatus = "store.failed"
            }
        } catch { purchaseStatus = "store.failed" }
    }

    func restorePurchases() async {
        guard !storeBusy && !Launch.isFree else { return }
        if Launch.testing { purchaseStatus = "store.restoreEmpty"; return }
        storeBusy = true
        defer { storeBusy = false }
        do {
            try await AppStore.sync()
            await refreshPurchases(authoritative: true)
            purchaseStatus = entitlement.purchasedPro ? "store.unlocked" : (entitlement.trialClaimedAt == nil ? "store.restoreEmpty" : "store.claimed")
        } catch { purchaseStatus = "store.failed" }
    }
}
