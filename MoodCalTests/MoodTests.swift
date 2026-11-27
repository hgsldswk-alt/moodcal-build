import XCTest
import Foundation
import CoreImage
import ImageIO

final class MoodTests: XCTestCase {
    private let day = "2026-11-20"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ level: Int = 3, day: String = "2026-11-20") -> MoodEntry {
        MoodEntry(dayKey: day, level: level, now: now, zone: TimeZone(secondsFromGMT: 0)!)
    }

    func testCalendarLeapMonthDSTAndFixedTimeZone() throws {
        XCTAssertNotNil(Days.date("2024-02-29"))
        XCTAssertNil(Days.date("2026-02-29"))
        XCTAssertEqual(Days.slots("2026-11").prefix(6).compactMap { $0 }.count, 0)
        XCTAssertEqual(Days.slots("2024-02").compactMap { $0 }.count, 29)
        XCTAssertEqual(Days.shift("2026-01", -1), "2025-12")
        let losAngeles = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-08T09:59:00Z"))
        let saved = MoodEntry(dayKey: Days.key(instant, zone: losAngeles), level: 3, now: instant, zone: losAngeles)
        XCTAssertEqual(saved.minuteOfDay, 119)
        XCTAssertEqual(Days.calendar(losAngeles).component(.hour, from: instant.addingTimeInterval(60)), 3)
        XCTAssertNotEqual(Days.key(instant.addingTimeInterval(23 * 3600), zone: tokyo), saved.dayKey)
        XCTAssertEqual(saved.dayKey, "2026-03-08")
    }

    func testAppendTieEditUndoAndMove() {
        var first = entry()
        first.id = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        var next = entry(5)
        next.id = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        var history = MoodHistory(entries: [next, first])
        XCTAssertEqual(history.latest[day]?.level, 5)
        XCTAssertEqual(history.dayCounts[day], 2)
        history.entries.removeAll { $0.id == next.id }
        XCTAssertEqual(history.latest[day]?.level, 3)
        history.entries.append(next)
        next.level = 2
        next.updatedAt = now.addingTimeInterval(3600)
        history.entries[1] = next
        XCTAssertEqual(history.latest[day]?.level, 2)
        next.dayKey = "2026-10-31"
        history.entries[1] = next
        XCTAssertEqual(history.latest[day]?.level, 3)
        XCTAssertEqual(history.days(in: "2026-10").first?.minuteOfDay, first.minuteOfDay)
        XCTAssertEqual(history.latest.count, 2)
    }

    func testBackupRoundTripConflictIdempotenceAndInvalidFiles() throws {
        var original = entry()
        original.note = " =1\n\"quoted\", calm"
        let history = MoodHistory(entries: [original])
        let encoded = try JSONEncoder().encode(MoodBackup(history))
        let backup = try MoodBackup.read(encoded)
        XCTAssertEqual(backup.entries, history.entries)
        var local = MoodHistory()
        XCTAssertEqual(local.preview(backup).new, 1)
        local.merge(backup)
        local.merge(backup)
        XCTAssertEqual(local, history)
        local.entries[0].level = 1
        XCTAssertEqual(local.preview(backup).conflicts, 1)
        local.merge(backup)
        XCTAssertEqual(local.entries[0].level, 1)
        XCTAssertThrowsError(try MoodBackup.read(Data("{}".utf8)))
        XCTAssertThrowsError(try MoodBackup.read(Data("{\"version\":2}".utf8))) { XCTAssertEqual($0 as? MoodFailure, .version) }
        XCTAssertThrowsError(try MoodBackup.read(JSONEncoder().encode(MoodBackup(MoodHistory(entries: [original, original])))))
        XCTAssertThrowsError(try Transfer.validateSize(Data(count: 2), max: 1))
        XCTAssertTrue(Transfer.csv([original]).contains("\"' =1\n\"\"quoted\"\", calm\""))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("purchasedPro"))
    }

    func testPaletteRoundTripAndNoPrivateFields() throws {
        let palette = MoodPalette(name: "Evening", colors: MoodPalette.standard.colors)
        let data = try Transfer.paletteData(palette)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), ["colors", "name", "version"])
        let parsed = try Transfer.readCode("Share it!\n" + Transfer.code(data))
        XCTAssertEqual(parsed.name, palette.name)
        XCTAssertEqual(parsed.colors, palette.colors)
        XCTAssertEqual(try Transfer.readPalette(data).colors, parsed.colors)
        XCTAssertThrowsError(try Transfer.readCode("MC1-**"))
        XCTAssertTrue(MoodPalette.lightText(on: "000000"))
        XCTAssertFalse(MoodPalette.lightText(on: "FFFFFF"))
    }

    func testSQLiteRollbackReopenAndRetry() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Mood.sqlite")
        let store = MoodStore(url: url)
        let initial = try await store.load()
        let saved = MoodHistory(entries: [entry()])
        try await store.save(from: initial, to: saved)
        var invalid = saved
        invalid.entries += [entry(4), entry(6)]
        do { try await store.save(from: saved, to: invalid); XCTFail("Invalid batch should fail") } catch {}
        let afterFailure = try await store.load()
        XCTAssertEqual(afterFailure, saved)
        invalid.entries.removeLast()
        try await store.save(from: afterFailure, to: invalid)
        let reopened = try await MoodStore(url: url).load()
        XCTAssertEqual(Set(reopened.entries.map(\.id)), Set(invalid.entries.map(\.id)))
    }

    func testMovedNotePreservesExactLineBreakOnReopen() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Mood.sqlite")
        let store = MoodStore(url: url)
        let initial = try await store.load()
        var record = entry()
        let original = MoodHistory(entries: [record])
        try await store.save(from: initial, to: original)
        let noteText = "Walk after work\nWindy today"
        record.note = noteText
        let withNote = MoodHistory(entries: [record])
        try await store.save(from: original, to: withNote)
        record.dayKey = "2026-11-19"
        try await store.save(from: withNote, to: MoodHistory(entries: [record]))
        let reopened = try await MoodStore(url: url).load()
        XCTAssertEqual(reopened.entries, [record])
        XCTAssertEqual(reopened.entries.first?.note, noteText)
    }

    func testTrialUpgradeBoundaryOfflineRevocationAndClockRollback() {
        var entitlement = Entitlement(firstOpen: now.addingTimeInterval(-300 * 86400))
        XCTAssertTrue(entitlement.hasPro(at: now, free: true))
        entitlement.observe(now, free: false)
        XCTAssertEqual(entitlement.trialStart, now)
        XCTAssertTrue(entitlement.hasPro(at: entitlement.trialEnd.addingTimeInterval(-1), free: false))
        XCTAssertFalse(entitlement.hasPro(at: entitlement.trialEnd, free: false))
        entitlement.observe(entitlement.trialEnd, free: false)
        XCTAssertFalse(entitlement.hasPro(at: now, free: false))
        entitlement.verifyPurchase(revoked: false)
        XCTAssertTrue(entitlement.hasPro(at: now, free: false))
        entitlement.verifyPurchase(revoked: true)
        XCTAssertFalse(entitlement.hasPro(at: now, free: false))
        entitlement.verifyTrial(now.addingTimeInterval(3600), revoked: false)
        XCTAssertEqual(entitlement.trialStart, now)
        let legacy = now.addingTimeInterval(-86400)
        entitlement.verifyTrial(legacy, revoked: false)
        XCTAssertEqual(entitlement.trialStart, legacy)
        var reinstalled = Entitlement(firstOpen: now.addingTimeInterval(40 * 86400))
        reinstalled.mergeClock(entitlement)
        XCTAssertFalse(reinstalled.hasPro(at: now, free: false))
    }

    func testShareDefaultsDownloadQRAndDatesIndependence() throws {
        let segment = ShareContent.Segment(month: "2026-11", entries: [entry()])
        var content = ShareContent(segments: [segment], storeID: "123456789")
        XCTAssertFalse(content.dates)
        XCTAssertTrue(content.download)
        XCTAssertEqual(content.tiles(segment).count, 1)
        XCTAssertEqual(content.pixelHeight, 1350)
        XCTAssertEqual(content.hashtags, L.t("share.caption").components(separatedBy: "\n").last)
        XCTAssertEqual(content.hashtags.split(separator: " ").filter { $0.hasPrefix("#") }.count, 2)
        let qr = try XCTUnwrap(content.qr)
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext(), options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let features = detector.features(in: CIImage(cgImage: qr).clampedToWhiteMargin())
        XCTAssertEqual((features.first as? CIQRCodeFeature)?.messageString, "https://apps.apple.com/app/id123456789")
        content.dates = true
        content.download = false
        XCTAssertGreaterThan(content.tiles(segment).count, 1)
        XCTAssertNil(content.qr)
        content.storeID = ""
        content.download = true
        XCTAssertNil(content.downloadURL)
        XCTAssertNil(content.qr)
    }

    func testCoreReviewRequiresThreeActionsOnTwoLocalDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let firstDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 23)))
        let nextDay = firstDay.addingTimeInterval(2 * 3600)
        let empty = try JSONDecoder().decode(CoreReviewProgress.self, from: Data("{}".utf8))
        XCTAssertFalse(empty.isEligible)
        var progress = CoreReviewProgress.recording(empty, at: firstDay, calendar: calendar)
        var twoDays = progress
        twoDays.record(at: nextDay, calendar: calendar)
        XCTAssertFalse(twoDays.isEligible)
        progress.record(at: firstDay, calendar: calendar)
        XCTAssertFalse(progress.isEligible)

        var sameDay = progress
        sameDay.record(at: firstDay, calendar: calendar)
        XCTAssertFalse(sameDay.isEligible)

        let data = try JSONEncoder().encode(progress)
        progress = try JSONDecoder().decode(CoreReviewProgress.self, from: data)
        progress.record(at: nextDay, calendar: calendar)
        XCTAssertTrue(progress.isEligible)
    }

    func testMilestonesAndRatingThrottle() {
        var history = MoodHistory(entries: (1...7).map { entry(day: String(format: "2026-11-%02d", $0)) })
        XCTAssertEqual(history.nextMilestones(), [7])
        history.preferences.milestones.insert(7)
        XCTAssertTrue(history.nextMilestones().isEmpty)
        XCTAssertFalse(history.shouldRate(now: now, version: "1", priorDays: 6))
        XCTAssertTrue(history.shouldRate(now: now, version: "1", priorDays: 7))
        history.preferences.ratedAt = now
        history.preferences.ratedVersion = "1"
        XCTAssertFalse(history.shouldRate(now: now.addingTimeInterval(100 * 86400), version: "1", priorDays: 7))
        XCTAssertFalse(history.shouldRate(now: now.addingTimeInterval(89 * 86400), version: "2", priorDays: 7))
        XCTAssertTrue(history.shouldRate(now: now.addingTimeInterval(90 * 86400), version: "2", priorDays: 7))
        XCTAssertNotEqual(L.t("app.name"), "app.name")
    }

    func testPNGDimensionsAndPrivateMetadata() throws {
        let image = try XCTUnwrap(ShareContent.qr(for: "https://apps.apple.com/app/id123456789"))
        for height in [1350, 2160] {
            let data = try SharePNG.encode(image, height: height)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
            XCTAssertEqual(properties[kCGImagePropertyPixelWidth as String] as? Int, 1080)
            XCTAssertEqual(properties[kCGImagePropertyPixelHeight as String] as? Int, height)
            XCTAssertNil(properties[kCGImagePropertyGPSDictionary as String])
            XCTAssertNil(properties[kCGImagePropertyIPTCDictionary as String])
            let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
            XCTAssertNil(exif?[kCGImagePropertyExifDateTimeOriginal as String])
            XCTAssertNil(exif?[kCGImagePropertyExifLensModel as String])
            let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
            XCTAssertNil(tiff?[kCGImagePropertyTIFFModel as String])
        }
    }
}

private extension CIImage {
    func clampedToWhiteMargin() -> CIImage {
        let area = extent.insetBy(dx: -40, dy: -40)
        return composited(over: CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: area)).cropped(to: area)
    }
}
