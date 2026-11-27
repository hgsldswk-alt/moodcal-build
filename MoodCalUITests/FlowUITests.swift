import XCTest

final class FlowUITests: XCTestCase {
    private let app = XCUIApplication()
    private let today = "2026-11-20"
    private let yesterday = "2026-11-19"

    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ args: [String] = [], language: String = "zh-Hans", reset: Bool = true, values: [String: String] = [:]) {
        if app.state != .notRunning { app.terminate() }
        let locale = ["en": "en_US", "zh-Hans": "zh_CN", "zh-Hant": "zh_TW", "ja": "ja_JP"][language] ?? "zh_CN"
        app.launchArguments = ["-ui-testing", "-demo", "-AppleLanguages", "(\(language))", "-AppleLocale", locale]
            + (reset ? ["-reset"] : []) + args
        app.launchEnvironment = values
        app.launch()
        if !args.contains("-paywall") {
            let button = app.buttons["mood.3"]
            expectation(for: NSPredicate(format: "exists == true AND enabled == true"), evaluatedWith: button)
            waitForExpectations(timeout: 8)
        }
    }

    @discardableResult
    private func tap(_ id: String, scroll: Bool = false) -> XCUIElement {
        tap(app.buttons.matching(identifier: id), named: id, scroll: scroll)
    }

    @discardableResult
    private func tap(_ matches: XCUIElementQuery, named name: String, scroll: Bool) -> XCUIElement {
        if scroll {
            for _ in 0..<5 {
                if matches.allElementsBoundByIndex.contains(where: { $0.isHittable }) { break }
                app.swipeUp(velocity: .slow)
            }
        }
        let button = matches.allElementsBoundByIndex.first(where: { $0.isHittable }) ?? matches.firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Missing button: \(name)")
        XCTAssertTrue(button.isHittable, "Button is outside the visible area: \(name)")
        button.tap()
        return button
    }

    private func check(_ id: String, timeout: TimeInterval = 5) {
        XCTAssertTrue(app.staticTexts[id].waitForExistence(timeout: timeout), "Missing text: \(id)")
    }

    private func waitForMood(_ level: Int) {
        let button = app.buttons["mood.\(level)"]
        expectation(for: NSPredicate(format: "exists == true AND enabled == true"), evaluatedWith: button)
        waitForExpectations(timeout: 5)
    }

    private func checkSavedNote(_ expected: String, message: String) {
        let note = app.staticTexts["edit.note.content"]
        XCTAssertTrue(note.waitForExistence(timeout: 5), message)
        let collapseWhitespace: (String) -> String = { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        XCTAssertEqual(collapseWhitespace(note.label), collapseWhitespace(expected), message)
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["SHOTS_DIR"] ?? ProcessInfo.processInfo.environment["TEST_RUNNER_SHOTS_DIR"] {
            let url = URL(fileURLWithPath: folder, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url.appendingPathComponent(name + ".png"))
        }
    }

    func testRecordAppendUndoNoteMoveAndRelaunch() {
        let firstLine = "Walk after work"
        let noteText = firstLine + "\nWindy today"
        launch(["-hold-undo"])
        tap("mood.3")
        check("home.saved")
        tap("mood.5")
        waitForMood(5)
        tap("home.undo")
        waitForMood(3)
        XCTAssertEqual(app.buttons["day.\(today)"].value as? String, "平静，共 1 条记录")
        tap("mood.4")
        check("home.saved")
        tap("home.note")
        let note = app.textViews["note.input"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        note.typeText(noteText)
        let counter = app.staticTexts["note.count"]
        let updated = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND label == %@", "\(noteText.count) / 280 字"), object: counter
        )
        XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 5), .completed, "The app should receive the full note before saving")
        tap("note.done", scroll: true)
        let notedEntry = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "entry.", firstLine
        ))
        tap(notedEntry, named: "record with the saved note", scroll: true)
        checkSavedNote(noteText, message: "The record should contain both lines immediately after saving")
        tap("edit.date")
        let destination = tap("move.day.\(yesterday)", scroll: true)
        let moveCompleted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: destination)
        XCTAssertEqual(XCTWaiter.wait(for: [moveCompleted], timeout: 5), .completed, "The date editor should close after saving the move")
        launch(reset: false)
        XCTAssertEqual(app.buttons["day.\(today)"].value as? String, "平静，共 1 条记录")
        XCTAssertEqual(app.buttons["day.\(yesterday)"].value as? String, "不错，共 1 条记录")
        tap("day.\(yesterday)")
        tap("entry.0", scroll: true)
        checkSavedNote(noteText, message: "The moved record should still have both lines after relaunch")
        tap("edit.mood.2")
        waitForMood(2)
        XCTAssertEqual(app.buttons["day.\(yesterday)"].value as? String, "低落，共 1 条记录")
        tap("entry.0", scroll: true)
        tap("edit.delete")
        let confirmation = app.alerts.buttons["删除"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.tap()
    }

    func testBackfillNewDayAndDeniedNotifications() {
        launch(["-clock-controls", "-deny-notifications"])
        tap("day.\(yesterday)")
        let date = app.staticTexts["home.target"].label
        tap("mood.2")
        check("home.saved")
        tap("test.nextDay", scroll: true)
        app.swipeDown()
        XCTAssertEqual(app.staticTexts["home.target"].label, date)
        tap("home.today")
        XCTAssertNotEqual(app.staticTexts["home.target"].label, date)
        tap("mood.5")
        check("home.saved")
        tap("home.settings")
        let reminder = app.switches["settings.reminder"]
        for _ in 0..<5 where !reminder.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(reminder.isHittable, "The reminder switch should be visible in Settings")
        reminder.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let isOn = NSPredicate(format: "exists == true AND value == %@", "1")
        let enabled = XCTNSPredicateExpectation(predicate: isOn, object: reminder)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed, "The reminder switch should turn on")

        let status = app.staticTexts["reminder.status"]
        for _ in 0..<5 where !status.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(status.isHittable, "The denied notification message should be visible below the reminder controls")
        XCTAssertEqual(status.label, "通知未开启，不影响记录。可在系统设置中允许通知。")
        tap("sheet.close")
        tap("mood.3")
        check("home.saved")
    }

    func testBackupPaletteAndExpiredStillFree() {
        let backup = """
        {"version":1,"entries":[{"id":"00000000-0000-0000-0000-000000001230","dayKey":"2026-10-31","minuteOfDay":600,"timeZone":"GMT","level":4,"createdAt":0,"updatedAt":0}],"preferences":{"palettes":[],"milestones":[],"reminder":false,"reminderMinute":1260}}
        """
        let palette = Data(#"{"version":1,"name":"Autumn","colors":["111111","444444","777777","AAAAAA","FFFFFF"]}"#.utf8)
            .base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        launch(["-expired", "-fixture-import"], values: ["MOOD_BACKUP": backup, "MOOD_PALETTE": "A friend's palette\nMC1-" + palette])
        tap("mood.3")
        check("home.saved")
        tap("entry.0", scroll: true)
        tap("edit.mood.4")
        app.swipeDown()
        tap("home.settings")
        tap("settings.export")
        check("share.requested")
        tap("settings.restore")
        let merge = app.alerts.buttons["合并备份"]
        XCTAssertTrue(merge.waitForExistence(timeout: 5))
        merge.tap()
        check("restore.status")
        tap("settings.importPalette")
        tap("palette.paste")
        check("palette.preview")
        tap("palette.apply")
        tap("store.restore", scroll: true)
        check("store.status")
    }

    func testHomeBackupRestorePreviewsAndMerges() {
        let backup = """
        {"version":1,"entries":[{"id":"00000000-0000-0000-0000-000000001230","dayKey":"2026-11-20","minuteOfDay":600,"timeZone":"GMT","level":4,"createdAt":0,"updatedAt":0}],"preferences":{"palettes":[],"milestones":[],"reminder":false,"reminderMinute":1260}}
        """
        launch(["-fixture-import"], values: ["MOOD_BACKUP": backup])
        tap("home.restore")
        let merge = app.alerts.buttons["合并备份"]
        XCTAssertTrue(merge.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["entry.0"].exists)
        merge.tap()
        check("restore.status")
        XCTAssertTrue(app.buttons["entry.0"].waitForExistence(timeout: 5))
        launch(reset: false)
        XCTAssertTrue(app.buttons["entry.0"].waitForExistence(timeout: 5))
    }

    func testPaletteImportCanActivateWithinTrial() {
        let payload = Data(#"{"version":1,"name":"Rain","colors":["111111","444444","777777","AAAAAA","FFFFFF"]}"#.utf8)
            .base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        launch(["-fixture-import"], values: ["MOOD_PALETTE": "MC1-" + payload])
        tap("home.importPalette")
        tap("palette.paste")
        check("palette.preview")
        tap("palette.apply")
        tap("home.settings")
        tap("settings.palettes")
        let fileShare = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "palette.share.")).firstMatch
        XCTAssertTrue(fileShare.waitForExistence(timeout: 5))
        fileShare.tap()
        tap("palette.copy")
        tap("palette.file")
        check("share.requested")
    }

    func testMilestoneAndSharePrivacyControls() {
        launch(["-demo-store"])
        for day in 13...19 {
            app.swipeDown()
            tap("day.2026-11-\(day)")
            tap("mood.3")
            check("home.saved")
        }
        tap("home.milestone")
        let dates = app.switches["share.dates"]
        let code = app.switches["share.download"]
        XCTAssertTrue(dates.waitForExistence(timeout: 5))
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        XCTAssertEqual(dates.value as? String, "0")
        XCTAssertEqual(code.value as? String, "1")
        let artwork = app.descendants(matching: .any)
        let qrArtwork = artwork.matching(identifier: "share.artwork.qr").firstMatch
        XCTAssertTrue(qrArtwork.waitForExistence(timeout: 15), "The preview should show the demo download QR by default")
        XCTAssertEqual(qrArtwork.label, "我记了 7 天的心情")
        for (control, value) in [(dates, "1"), (code, "0")] {
            for _ in 0..<5 where !control.isHittable { app.swipeUp(velocity: .slow) }
            XCTAssertTrue(control.isHittable, "The switch should be visible: \(control.identifier)")
            control.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            let toggled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: control)
            XCTAssertEqual(XCTWaiter.wait(for: [toggled], timeout: 5), .completed, "The switch should change: \(control.identifier)")
        }
        app.swipeDown(velocity: .slow)
        XCTAssertTrue(artwork.matching(identifier: "share.artwork").firstMatch.waitForExistence(timeout: 5),
                      "The preview should still be present with the download code turned off")
        XCTAssertFalse(qrArtwork.exists, "Disabling the download code should remove the QR from the preview")
        tap("share.send", scroll: true)
        let terminalStatus = NSPredicate(format: "identifier == %@ OR identifier == %@", "share.requested", "share.failed")
        let outcome = app.staticTexts.matching(terminalStatus).firstMatch
        XCTAssertTrue(outcome.waitForExistence(timeout: 15), "Card export should report either success or failure")
        XCTAssertEqual(outcome.identifier, "share.requested", "Card export failed: \(outcome.label)")
    }

    func testPreviousMonthAndLongCard() {
        launch(["-seed"])
        tap("calendar.previous")
        tap("day.2026-10-31", scroll: true)
        app.swipeDown()
        tap("mood.2")
        check("home.saved")
        tap("home.share", scroll: true)
        tap("share.template", scroll: true)
        XCTAssertTrue(app.descendants(matching: .any)["share.artwork.long"].firstMatch.waitForExistence(timeout: 5))
    }

    func testStoreSimplifiedChinese() { store("zh-Hans") }
    func testStoreEnglish() { store("en") }
    func testStoreTraditionalChinese() { store("zh-Hant") }
    func testStoreJapanese() { store("ja") }

    private func store(_ language: String) {
        launch(["-seed", "-demo-store"], language: language)
        tap("mood.3")
        check("home.saved")
        shot("store-\(language)-01-today")
        launch(["-seed", "-demo-store"], language: language, reset: false)
        check("calendar.count")
        shot("store-\(language)-02-month")
        tap("day.\(yesterday)")
        tap("mood.4")
        check("home.saved")
        shot("store-\(language)-03-backfill")
        tap("home.settings")
        XCTAssertTrue(app.buttons["settings.export"].exists)
        shot("store-\(language)-04-export")
        tap("sheet.close")
        tap("home.share", scroll: true)
        XCTAssertTrue(app.switches["share.download"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["share.artwork.qr"].firstMatch.waitForExistence(timeout: 5))
        shot("store-\(language)-05-card")
    }

    func testPaywallScreenshot() {
        launch(["-paid-mode", "-paywall"])
        XCTAssertTrue(app.buttons["store.claim"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["store.buy"].exists)
        shot("paid-01-paywall")
    }
}
