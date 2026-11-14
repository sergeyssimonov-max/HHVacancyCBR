import XCTest

final class HHVacancyCBRUITests: XCTestCase {
    private func launch(scenario: String = "default") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HHVACANCYCBR_UI_TEST_MODE"] = "1"
        app.launchEnvironment["HHVACANCYCBR_UI_TEST_SCENARIO"] = scenario
        app.launch()
        return app
    }

    func testOptInInstalledTrudLiveRefreshButton() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["HHVACANCYCBR_RUN_INSTALLED_TRUD_LIVE_UI"] == "1",
            "Opt-in UI check of /Applications/ЦБВакансии.app using real API and its normal snapshot.")
        let installedURL = URL(fileURLWithPath: "/Applications/ЦБВакансии.app", isDirectory: true)
        let installed = try XCTUnwrap(Bundle(url: installedURL))
        XCTAssertEqual(installed.bundleIdentifier, "local.sergey.HHVacancyCBR")
        XCTAssertEqual(installed.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, "1.3.4")
        XCTAssertEqual(installed.object(forInfoDictionaryKey: "CFBundleVersion") as? String, "15")
        let snapshotPath = try XCTUnwrap(environment["HHVACANCYCBR_LIVE_SNAPSHOT_PATH"])
        let snapshotURL = URL(fileURLWithPath: snapshotPath)
        func readSnapshot() throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: snapshotURL)) as? [String: Any])
        }
        let beforeDate: Double?
        if FileManager.default.fileExists(atPath: snapshotPath) {
            beforeDate = try XCTUnwrap(readSnapshot()["updatedAt"] as? Double)
        } else {
            beforeDate = nil
        }
        let app = XCUIApplication()
        // The xctestrun target is the installed Release app; explicitly disable fixtures as well.
        app.launchEnvironment["HHVACANCYCBR_UI_TEST_MODE"] = "0"
        app.launchEnvironment["HHVACANCYCBR_UI_TEST_SCENARIO"] = ""
        app.launch()
        let source = app.radioButtons["trudvsem.ru"]
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        source.click()
        let refresh = app.buttons["refreshTrudvsemButton"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForLabel("Обновить", of: refresh))
        let timestamp = app.staticTexts["vacancyUpdateStatus"]
        if beforeDate != nil {
            XCTAssertTrue(timestamp.exists)
        } else {
            XCTAssertFalse(timestamp.exists, "A clean install must not show a saved update date")
            XCTAssertEqual(app.staticTexts["displayedVacancyCount"].value as? String, "Вакансий: 0")
        }
        print("INSTALLED LIVE UI before=\(timestamp.exists ? String(describing: timestamp.value) : "no saved snapshot") count=\(app.staticTexts["displayedVacancyCount"].value ?? "")")
        let initial = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        initial.name = "Installed trudvsem before refresh"; initial.lifetime = .keepAlways; add(initial)
        let clickedAt = Date().timeIntervalSinceReferenceDate
        refresh.click()
        XCTAssertTrue(waitForLabel("Отменить", of: refresh, timeout: 10), "The real toolbar action must start a refresh")
        XCTAssertTrue(app.staticTexts["vacancyExtractionStatus"].exists)
        let loading = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        loading.name = "Installed trudvsem loading after button click"; loading.lifetime = .keepAlways; add(loading)
        XCTAssertTrue(waitForLabel("Обновить", of: refresh, timeout: 180), "The refresh must finish")
        let finished = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        finished.name = "Installed trudvsem successful live refresh"; finished.lifetime = .keepAlways; add(finished)
        let error = app.staticTexts["trudRefreshError"]
        XCTAssertFalse(error.exists, error.exists ? String(describing: error.value) : "")
        XCTAssertFalse(app.staticTexts["vacancyExtractionStatus"].exists)
        let after = try readSnapshot()
        let afterDate = try XCTUnwrap(after["updatedAt"] as? Double)
        let vacancies = try XCTUnwrap(after["vacancies"] as? [[String: Any]])
        let metrics = try XCTUnwrap(after["metrics"] as? [[String: Any]])
        if let beforeDate { XCTAssertGreaterThan(afterDate, beforeDate) }
        XCTAssertGreaterThanOrEqual(afterDate, clickedAt)
        XCTAssertFalse(vacancies.isEmpty)
        XCTAssertEqual(Set(metrics.compactMap { $0["organizationKey"] as? String }),
            Set(["bank_of_russia", "rosinkas", "nspk", "rnpk", "nsis", "uk_fkbs"]))
        XCTAssertTrue(metrics.allSatisfy { ($0["declared"] as? Int) == ($0["unique"] as? Int) })
        XCTAssertEqual(metrics.compactMap { $0["unique"] as? Int }.reduce(0, +), vacancies.count)
        XCTAssertEqual(app.staticTexts["displayedVacancyCount"].value as? String, "Вакансий: \(vacancies.count)")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "dd.MM.yyyy, HH:mm"
        let expectedTimestamp = "Обновлено: " + formatter.string(from: Date(timeIntervalSinceReferenceDate: afterDate))
        XCTAssertEqual(timestamp.value as? String, expectedTimestamp)
        XCTAssertTrue(app.buttons["exportBulkPDFButton"].isEnabled)
        XCTAssertTrue(refresh.isEnabled)
        print("INSTALLED LIVE UI success count=\(vacancies.count) timestamp=\(expectedTimestamp) persistedAfterClick=true employers=\(metrics.count)")

        app.terminate()
        app.launch()
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        source.click()
        XCTAssertTrue(refresh.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForLabel("Обновить", of: refresh))
        XCTAssertEqual(app.staticTexts["displayedVacancyCount"].value as? String, "Вакансий: \(vacancies.count)")
        XCTAssertEqual(timestamp.value as? String, expectedTimestamp)
        XCTAssertFalse(error.exists)
        XCTAssertEqual(try readSnapshot()["updatedAt"] as? Double, afterDate,
            "Relaunch must read the saved snapshot without inventing a new update")
        let reopened = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        reopened.name = "Installed trudvsem persisted after relaunch"; reopened.lifetime = .keepAlways; add(reopened)
        print("INSTALLED LIVE UI relaunch success count=\(vacancies.count) unchangedTimestamp=true")
    }

    func testOptInInstalledHHLiveRefreshAndBothSourcesPersist() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["HHVACANCYCBR_RUN_INSTALLED_HH_LIVE_UI"] == "1",
            "Opt-in real hh.ru refresh in the installed app; verifies both normal snapshots after relaunch.")
        continueAfterFailure = false
        let installed = try XCTUnwrap(Bundle(url: URL(fileURLWithPath: "/Applications/ЦБВакансии.app")))
        XCTAssertEqual(installed.bundleIdentifier, "local.sergey.HHVacancyCBR")
        XCTAssertEqual(installed.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, "1.3.4")
        XCTAssertEqual(installed.object(forInfoDictionaryKey: "CFBundleVersion") as? String, "15")
        let root = URL(fileURLWithPath: try XCTUnwrap(environment["HHVACANCYCBR_LIVE_DATA_PATH"]))
        let hhURL = root.appendingPathComponent("vacancies.json")
        let trudURL = root.appendingPathComponent("vacancies-trudvsem.json")
        func object(_ data: Data) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let trudBefore = try Data(contentsOf: trudURL)
        let trud = try object(trudBefore)
        let trudCount = try XCTUnwrap(trud["vacancies"] as? [[String: Any]]).count
        XCTAssertGreaterThan(trudCount, 0)
        let trudDate = Date(timeIntervalSinceReferenceDate: try XCTUnwrap(trud["updatedAt"] as? Double))
        let hhBefore = FileManager.default.fileExists(atPath: hhURL.path) ? try Data(contentsOf: hhURL) : nil
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "dd.MM.yyyy, HH:mm"
        func timestamp(_ date: Date) -> String { "Обновлено: " + formatter.string(from: date) }
        let app = XCUIApplication()
        app.launchEnvironment["HHVACANCYCBR_UI_TEST_MODE"] = "0"
        app.launchEnvironment["HHVACANCYCBR_UI_TEST_SCENARIO"] = ""
        func screenshot(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        func checkVisibleSnapshot(count: Int, date: Date, refreshIdentifier: String) {
            let refresh = app.buttons[refreshIdentifier]
            XCTAssertTrue(refresh.waitForExistence(timeout: 10))
            XCTAssertTrue(waitForLabel("Обновить", of: refresh))
            let expectedDate = timestamp(date)
            let loaded = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", expectedDate),
                object: app.staticTexts["vacancyUpdateStatus"])
            XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 10), .completed)
            XCTAssertEqual(app.staticTexts["displayedVacancyCount"].value as? String, "Вакансий: \(count)")
            XCTAssertFalse(app.staticTexts["vacancyExtractionStatus"].exists)
            XCTAssertFalse(app.descendants(matching: .any)["collectionWarning"].exists)
            XCTAssertFalse(app.staticTexts["trudRefreshError"].exists)
            XCTAssertTrue(app.buttons["exportBulkPDFButton"].isEnabled)
            XCTAssertTrue(refresh.isEnabled)
        }

        app.launch()
        XCTAssertTrue(app.radioButtons["trudvsem.ru"].waitForExistence(timeout: 10))
        app.radioButtons["trudvsem.ru"].click()
        checkVisibleSnapshot(count: trudCount, date: trudDate, refreshIdentifier: "refreshTrudvsemButton")
        screenshot("Installed trudvsem before HH refresh")
        app.radioButtons["hh.ru"].click()
        let refresh = app.buttons["searchVacanciesButton"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForLabel("Обновить", of: refresh))
        if hhBefore == nil {
            XCTAssertEqual(app.staticTexts["displayedVacancyCount"].value as? String, "Вакансий: 0")
            XCTAssertFalse(app.staticTexts["vacancyUpdateStatus"].exists)
        }
        screenshot("Installed HH before refresh")
        let clickedAt = Date()
        print("INSTALLED HH LIVE click=\(ISO8601DateFormatter().string(from: clickedAt)) trudCount=\(trudCount) hadHHSnapshot=\(hhBefore != nil)")
        refresh.click()
        XCTAssertTrue(waitForLabel("Отменить", of: refresh, timeout: 10))
        screenshot("Installed HH loading after button click")
        let finished = waitForLabel("Обновить", of: refresh, timeout: 600)
        screenshot("Installed HH live refresh result")
        XCTAssertTrue(finished, "The real hh.ru refresh must finish")
        XCTAssertFalse(app.descendants(matching: .any)["collectionWarning"].exists)
        XCTAssertFalse(app.staticTexts["Не удалось загрузить вакансии"].exists)
        let hhAfter = try Data(contentsOf: hhURL)
        let hh = try object(hhAfter)
        let vacancies = try XCTUnwrap(hh["vacancies"] as? [[String: Any]])
        let issues = try XCTUnwrap(hh["issues"] as? [[String: Any]])
        let savedDate = try XCTUnwrap(ISO8601DateFormatter().date(from: try XCTUnwrap(hh["updatedAt"] as? String)))
        XCTAssertGreaterThanOrEqual(savedDate.timeIntervalSince1970, floor(clickedAt.timeIntervalSince1970))
        XCTAssertFalse(vacancies.isEmpty)
        XCTAssertTrue(issues.isEmpty, "The hh.ru collection must be complete")
        let ids = vacancies.compactMap { ($0["summary"] as? [String: Any])?["id"] as? String }
        XCTAssertEqual(Set(ids).count, vacancies.count)
        if let hhBefore { XCTAssertNotEqual(hhAfter, hhBefore) }
        checkVisibleSnapshot(count: vacancies.count, date: savedDate, refreshIdentifier: "searchVacanciesButton")
        XCTAssertEqual(try Data(contentsOf: trudURL), trudBefore, "hh.ru refresh must preserve the entire trudvsem snapshot")
        print("INSTALLED HH LIVE success count=\(vacancies.count) timestamp=\(timestamp(savedDate)) issues=0 trudUnchanged=true")

        app.terminate()
        app.launch()
        XCTAssertTrue(app.radioButtons["hh.ru"].waitForExistence(timeout: 10))
        app.radioButtons["hh.ru"].click()
        checkVisibleSnapshot(count: vacancies.count, date: savedDate, refreshIdentifier: "searchVacanciesButton")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "vacancyTitle.")).firstMatch.exists)
        screenshot("Installed HH persisted after relaunch")
        app.radioButtons["trudvsem.ru"].click()
        checkVisibleSnapshot(count: trudCount, date: trudDate, refreshIdentifier: "refreshTrudvsemButton")
        screenshot("Installed trudvsem persisted after HH relaunch")
        app.radioButtons["hh.ru"].click()
        checkVisibleSnapshot(count: vacancies.count, date: savedDate, refreshIdentifier: "searchVacanciesButton")
        XCTAssertEqual(try Data(contentsOf: hhURL), hhAfter, "Relaunch must preserve hh.ru snapshot bytes")
        XCTAssertEqual(try Data(contentsOf: trudURL), trudBefore, "Relaunch must preserve trudvsem snapshot bytes")
        print("INSTALLED BOTH SOURCES relaunch success hh=\(vacancies.count) trud=\(trudCount) bothSnapshotsByteIdentical=true")
    }

    func testSourcesHaveIndependentRefreshAndPreserveHHRows() {
        let app = launch()
        let refresh = app.buttons["searchVacanciesButton"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 5))
        refresh.click()
        XCTAssertTrue(app.staticTexts["vacancyTitle.ui-1"].waitForExistence(timeout: 8))
        let refreshSize = refresh.frame.size
        app.radioButtons["trudvsem.ru"].click()
        XCTAssertTrue(app.buttons["refreshTrudvsemButton"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["refreshTrudvsemButton"].frame.width, refreshSize.width, accuracy: 1)
        XCTAssertEqual(app.buttons["refreshTrudvsemButton"].frame.height, refreshSize.height, accuracy: 1)
        XCTAssertFalse(app.buttons["searchVacanciesButton"].exists)
        app.buttons["refreshTrudvsemButton"].click()
        XCTAssertTrue(app.staticTexts["Администратор баз данных"].waitForExistence(timeout: 8))
        let refreshFinished = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Обновить"),
            object: app.buttons["refreshTrudvsemButton"])
        XCTAssertEqual(XCTWaiter.wait(for: [refreshFinished], timeout: 8), .completed)
        XCTAssertFalse(app.staticTexts["vacancyExtractionStatus"].exists)
        XCTAssertFalse(app.staticTexts["PDF сохранён."].exists)
        choose("НСИС", from: "employerFilterPicker", in: app)
        app.radioButtons["hh.ru"].click()
        XCTAssertTrue(app.staticTexts["vacancyTitle.ui-1"].exists)
        app.radioButtons["trudvsem.ru"].click()
        XCTAssertTrue(app.staticTexts["Администратор баз данных"].exists)
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Independent trudvsem source"; screenshot.lifetime = .keepAlways; add(screenshot)

    }

    func testSearchShowsConfiguredVacanciesAndLazyDetails() {
        let app = launch()
        let search = app.buttons["searchVacanciesButton"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        XCTAssertTrue(app.staticTexts["vacancyTitle.ui-1"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Банк России"].exists)
        app.buttons["expandVacancy.ui-1"].click()
        XCTAssertTrue(app.staticTexts["Полное описание вакансии."].waitForExistence(timeout: 5))
    }

    @MainActor
    func testFieldFilterBelongsOnlyToBankOfRussiaOnBothSources() {
        let app = launch()
        app.buttons["searchVacanciesButton"].click()
        XCTAssertTrue(app.staticTexts["vacancyTitle.ui-1"].waitForExistence(timeout: 8))
        choose("Полевые учреждения", from: "categoryFilterPicker", in: app)
        choose("НСПК", from: "employerFilterPicker", in: app)
        let category = app.descendants(matching: .any)["categoryFilterPicker"]
        XCTAssertFalse(category.isEnabled)
        XCTAssertTrue(app.staticTexts["vacancyTitle.ui-3"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["fieldInstitutionCount"].exists)

        app.radioButtons["trudvsem.ru"].click()
        XCTAssertTrue(app.buttons["refreshTrudvsemButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(category.isEnabled)
        app.buttons["refreshTrudvsemButton"].click()
        XCTAssertTrue(app.staticTexts["Администратор баз данных"].waitForExistence(timeout: 8))
        XCTAssertTrue(waitForLabel("Обновить", of: app.buttons["refreshTrudvsemButton"]))
        choose("Полевые учреждения", from: "categoryFilterPicker", in: app)
        choose("НСИС", from: "employerFilterPicker", in: app)
        XCTAssertFalse(category.isEnabled)
        XCTAssertTrue(app.staticTexts["Администратор баз данных"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["fieldInstitutionCount"].exists)
        choose("Банк России", from: "employerFilterPicker", in: app)
        XCTAssertTrue(category.isEnabled)
        XCTAssertTrue(app.staticTexts["fieldInstitutionCount"].exists)
        choose("Полевые учреждения", from: "categoryFilterPicker", in: app)

        app.radioButtons["hh.ru"].click()
        XCTAssertFalse(category.isEnabled, "The other tab keeps its own employer and category state")
        XCTAssertTrue(app.staticTexts["vacancyTitle.ui-3"].exists)
        choose("Все работодатели", from: "employerFilterPicker", in: app)
        XCTAssertTrue(category.isEnabled)
        XCTAssertTrue(app.staticTexts["fieldInstitutionCount"].exists)
        XCTAssertEqual(app.staticTexts["displayedVacancyCount"].value as? String, "Вакансий: 3")
    }

    func testTrudTimeoutKeepsRowsAndTimestampThenRecovers() throws {
        let app = launch(scenario: "trud-timeout-recovery")
        app.radioButtons["trudvsem.ru"].click()
        let refresh = app.buttons["refreshTrudvsemButton"]
        refresh.click()
        let title = app.staticTexts["Администратор баз данных"]
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        XCTAssertTrue(waitForLabel("Обновить", of: refresh))
        let updatedAt = app.staticTexts["vacancyUpdateStatus"]
        XCTAssertTrue(updatedAt.exists)
        let timestamp = try XCTUnwrap(updatedAt.value as? String)
        XCTAssertTrue(timestamp.hasPrefix("Обновлено:"))
        refresh.click()
        let error = app.staticTexts["trudRefreshError"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForLabel("Обновить", of: refresh))
        XCTAssertTrue(title.exists)
        let message = try XCTUnwrap(error.value as? String)
        XCTAssertTrue(message.contains("не ответил вовремя"))
        XCTAssertTrue(message.contains("дата обновления не изменилась"))
        XCTAssertFalse(message.contains("The request timed out"))
        XCTAssertFalse(message.contains("РОСИНКАС:"))
        XCTAssertEqual(updatedAt.value as? String, timestamp)
        XCTAssertTrue(app.buttons["exportBulkPDFButton"].isEnabled)
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "trudvsem timeout preserves saved vacancies"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.radioButtons["hh.ru"].click()
        XCTAssertFalse(error.exists)
        XCTAssertTrue(app.buttons["searchVacanciesButton"].isEnabled)
        app.radioButtons["trudvsem.ru"].click()
        XCTAssertTrue(error.exists)
        refresh.click()
        XCTAssertTrue(waitForDisappearance(of: error))
        XCTAssertTrue(waitForLabel("Обновить", of: refresh))
        XCTAssertTrue(title.exists)
    }

    func testTrudFirstRunOfflineHasOneClearErrorAndNoFakeSnapshot() throws {
        let app = launch(scenario: "trud-offline")
        app.radioButtons["trudvsem.ru"].click()
        let refresh = app.buttons["refreshTrudvsemButton"]
        refresh.click()
        let error = app.staticTexts["trudRefreshError"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        let message = try XCTUnwrap(error.value as? String)
        XCTAssertTrue(message.contains("Нет подключения к интернету"))
        XCTAssertTrue(message.contains("Полная выборка ещё не загружена"))
        XCTAssertFalse(message.contains("сохранённая"))
        XCTAssertTrue(app.staticTexts["Не удалось загрузить вакансии."].exists)
        XCTAssertFalse(app.staticTexts["vacancyUpdateStatus"].exists)
        XCTAssertFalse(app.buttons["exportBulkPDFButton"].isEnabled)
        XCTAssertTrue(waitForLabel("Обновить", of: refresh))
    }

    func testTrudCancelStalledRefreshAndStartAgain() {
        let app = launch(scenario: "trud-cancel")
        app.radioButtons["trudvsem.ru"].click()
        let refresh = app.buttons["refreshTrudvsemButton"]
        refresh.click()
        XCTAssertTrue(waitForLabel("Отменить", of: refresh))
        refresh.click()
        XCTAssertTrue(waitForLabel("Обновить", of: refresh))
        XCTAssertFalse(app.staticTexts["trudRefreshError"].exists)
        refresh.click()
        XCTAssertTrue(app.staticTexts["Администратор баз данных"].waitForExistence(timeout: 8))
        XCTAssertTrue(waitForLabel("Обновить", of: refresh))
        XCTAssertFalse(app.staticTexts["trudRefreshError"].exists)
    }

    func testFilteringExpandedVacancyHidesDetailsAndAllowsReopening() {
        let app = launch()
        app.buttons["searchVacanciesButton"].click()
        XCTAssertTrue(app.staticTexts["vacancyTitle.ui-1"].waitForExistence(timeout: 8))
        app.buttons["expandVacancy.ui-1"].click()
        XCTAssertTrue(app.staticTexts["Полное описание вакансии."].waitForExistence(timeout: 5))

        choose("НСПК", from: "employerFilterPicker", in: app)
        XCTAssertTrue(app.staticTexts["vacancyTitle.ui-3"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["expandVacancy.ui-1"].exists)
        XCTAssertFalse(app.staticTexts["Полное описание вакансии."].exists)
        let hidden = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        hidden.name = "Expanded vacancy hidden by employer filter"
        hidden.lifetime = .keepAlways
        add(hidden)

        choose("Все работодатели", from: "employerFilterPicker", in: app)
        let details = app.buttons["expandVacancy.ui-1"]
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        XCTAssertEqual(details.label, "Подробнее")
        details.click()
        XCTAssertTrue(app.staticTexts["Полное описание вакансии."].waitForExistence(timeout: 5))
        let reopened = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        reopened.name = "Vacancy details reopened after clearing filter"
        reopened.lifetime = .keepAlways
        add(reopened)
    }

    func testInitialScreensUseToolbarRefreshOnly() {
        let app = launch()
        let toolbarButton = app.buttons["searchVacanciesButton"]
        let emptyButton = app.buttons["emptyRefreshVacanciesButton"]
        XCTAssertTrue(toolbarButton.waitForExistence(timeout: 5))
        XCTAssertFalse(emptyButton.exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "Обновить")).count, 1)
        XCTAssertTrue(app.staticTexts["Загрузите вакансии hh.ru кнопкой «Обновить»."].exists)
        app.radioButtons["trudvsem.ru"].click()
        XCTAssertTrue(app.buttons["refreshTrudvsemButton"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "Обновить")).count, 1)
        XCTAssertTrue(app.staticTexts["Загрузите вакансии trudvsem.ru кнопкой «Обновить»."].exists)
    }

    func testSearchButtonAlignsWithRefreshOnBothSources() {
        let app = launch()
        for (source, refreshID) in [("hh.ru", "searchVacanciesButton"), ("trudvsem.ru", "refreshTrudvsemButton")] {
            if source == "trudvsem.ru" { app.radioButtons[source].click() }
            let refresh = app.buttons[refreshID]
            let search = app.buttons["submitVacancySearch"]
            XCTAssertTrue(refresh.waitForExistence(timeout: 5))
            XCTAssertTrue(search.exists)
            XCTAssertEqual(search.frame.minX, refresh.frame.minX, accuracy: 1)
            XCTAssertEqual(search.frame.maxX, refresh.frame.maxX, accuracy: 1)
            XCTAssertEqual(search.frame.height, refresh.frame.height, accuracy: 1)
            let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            shot.name = "alignment-" + source; shot.lifetime = .keepAlways; add(shot)
            let field = app.descendants(matching: .any)["vacancySearchBox"]
            let firstSegment = app.radioButtons["hh.ru"]
            XCTAssertTrue(field.exists)
            XCTAssertTrue(firstSegment.exists)
            XCTAssertEqual(field.frame.minX, firstSegment.frame.minX, accuracy: 6)
            XCTAssertEqual(field.frame.maxX + (refresh.frame.minX - app.descendants(matching: .any)["regionFilterPicker"].frame.maxX), search.frame.minX, accuracy: 6)
            XCTAssertEqual(field.frame.height, 29, accuracy: 1)
            let input = app.textFields["vacancySearchField"]
            XCTAssertTrue(input.exists)
            input.click()
            input.typeText("тест")
            let clear = app.buttons["clearVacancySearch"]
            XCTAssertTrue(clear.waitForExistence(timeout: 3))
            clear.click()
            let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: clear)
            XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 3), .completed)
        }
    }

    func testToolbarUsesOneAlignedRowWithoutExternalFilterLabels() {
        let app = launch()
        let mode = app.descendants(matching: .any)["vacancyListModePicker"]
        let category = app.descendants(matching: .any)["categoryFilterPicker"]
        let employer = app.descendants(matching: .any)["employerFilterPicker"]
        let region = app.descendants(matching: .any)["regionFilterPicker"]
        let refresh = app.buttons["searchVacanciesButton"]

        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        XCTAssertTrue(category.exists)
        XCTAssertTrue(employer.exists)
        XCTAssertTrue(region.exists)
        XCTAssertTrue(refresh.exists)
        XCTAssertFalse(app.staticTexts["Работодатель"].exists)
        XCTAssertFalse(app.staticTexts["Субъект"].exists)
        XCTAssertEqual(mode.frame.midY, category.frame.midY, accuracy: 6)
        XCTAssertEqual(category.frame.midY, employer.frame.midY, accuracy: 6)
        XCTAssertEqual(employer.frame.midY, region.frame.midY, accuracy: 6)
        XCTAssertEqual(region.frame.midY, refresh.frame.midY, accuracy: 6)
        XCTAssertLessThan(mode.frame.maxX, category.frame.minX)
        XCTAssertLessThan(category.frame.maxX, employer.frame.minX)
        XCTAssertLessThan(employer.frame.maxX, region.frame.minX)
        XCTAssertLessThan(region.frame.maxX, refresh.frame.minX)

        refresh.click()
        let status = app.descendants(matching: .any)["vacancyUpdateStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 8))
        XCTAssertLessThan(status.frame.maxX, refresh.frame.minX)
        XCTAssertGreaterThan(status.frame.minY, refresh.frame.maxY)
        let fieldCount = app.staticTexts["fieldInstitutionCount"]
        let vacancyCount = app.staticTexts["displayedVacancyCount"]
        XCTAssertTrue(fieldCount.exists)
        XCTAssertEqual(vacancyCount.frame.midY, fieldCount.frame.midY, accuracy: 2)
        XCTAssertEqual(fieldCount.frame.midY, status.frame.midY, accuracy: 2)
        XCTAssertLessThan(fieldCount.frame.maxX, status.frame.minX)
        XCTAssertFalse(app.popUpButtons["Сортировка"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "уникальных вакансий")).firstMatch.exists)
    }

    func testEmployerDropdownListsOptionsAndFiltersResults() {
        let app = launch()
        app.buttons["searchVacanciesButton"].click()
        XCTAssertTrue(app.staticTexts["vacancyTitle.ui-1"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.staticTexts["displayedVacancyCount"].value as? String, "Вакансий: 3")

        choose("НСПК", from: "employerFilterPicker", in: app)

        XCTAssertTrue(app.staticTexts["vacancyTitle.ui-3"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["displayedVacancyCount"].value as? String, "Вакансий: 1")
        XCTAssertFalse(app.staticTexts["vacancyTitle.ui-1"].exists)
        XCTAssertFalse(app.staticTexts["vacancyTitle.ui-2"].exists)

        choose("Все работодатели", from: "employerFilterPicker", in: app)
        XCTAssertTrue(app.staticTexts["vacancyTitle.ui-1"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["displayedVacancyCount"].value as? String, "Вакансий: 3")
    }

    func testRegionDropdownCombinesWithEmployerAndCanShowNoMatches() {
        let app = launch()
        app.buttons["searchVacanciesButton"].click()
        XCTAssertTrue(app.staticTexts["vacancyTitle.ui-1"].waitForExistence(timeout: 8))

        choose("Банк России", from: "employerFilterPicker", in: app)
        choose("Москва", from: "regionFilterPicker", in: app)
        XCTAssertTrue(app.staticTexts["vacancyTitle.ui-1"].exists)
        XCTAssertEqual(app.staticTexts["displayedVacancyCount"].value as? String, "Вакансий: 1")
        XCTAssertFalse(app.staticTexts["vacancyTitle.ui-2"].exists)
        XCTAssertFalse(app.staticTexts["vacancyTitle.ui-3"].exists)

        choose("Свердловская область", from: "regionFilterPicker", in: app)
        XCTAssertTrue(app.staticTexts["vacancyTitle.ui-2"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["vacancyTitle.ui-1"].exists)

        choose("Удалённо", from: "regionFilterPicker", in: app)
        XCTAssertTrue(app.staticTexts["Вакансий не найдено"].waitForExistence(timeout: 5))
    }

    func testEmptyResponseIsExplicit() {
        let app = launch(scenario: "empty")
        app.buttons["searchVacanciesButton"].click()
        XCTAssertTrue(app.staticTexts["Вакансий не найдено"].waitForExistence(timeout: 8))
    }

    func testSearchFailureIsExplicit() {
        let app = launch(scenario: "searchError")
        app.buttons["searchVacanciesButton"].click()
        XCTAssertTrue(app.staticTexts["Не удалось загрузить вакансии"].waitForExistence(timeout: 8))
    }

    func testStatisticsPDFButtonIsAlignedAndAvailableForFilteredRows() {
        let app = launch()
        let report = app.buttons["exportStatisticsPDFButton"]
        let refresh = app.buttons["searchVacanciesButton"]
        XCTAssertTrue(report.waitForExistence(timeout: 5))
        XCTAssertFalse(report.isEnabled)
        // Native bordered buttons expose different AX insets across macOS releases.
        // Check the actual shared 28-point content margin instead of the native label bounds.
        XCTAssertEqual(report.frame.maxX, app.windows.firstMatch.frame.maxX - 28, accuracy: 2)
        refresh.click()
        XCTAssertTrue(app.staticTexts["vacancyTitle.ui-1"].waitForExistence(timeout: 8))
        XCTAssertTrue(report.isEnabled)
        XCTAssertEqual(report.frame.maxX, app.buttons["Экспорт в PDF"].firstMatch.frame.maxX, accuracy: 2)
        XCTAssertEqual(report.label, "Статистика в PDF")
        XCTAssertEqual(report.images.count, 0)
        XCTAssertEqual(report.frame.height, 32, accuracy: 2)
        XCTAssertEqual(report.frame.height, app.buttons["Экспорт в PDF"].firstMatch.frame.height, accuracy: 1)
        choose("Банк России", from: "employerFilterPicker", in: app)
        choose("Москва", from: "regionFilterPicker", in: app)
        XCTAssertEqual(app.staticTexts["displayedVacancyCount"].value as? String, "Вакансий: 1")
        XCTAssertTrue(report.isEnabled)
        XCTAssertEqual(report.frame.maxX, app.windows.firstMatch.frame.maxX - 28, accuracy: 2)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "Statistics PDF borderless command"
        attachment.lifetime = .keepAlways
        add(attachment)
    }


    func testStatisticsCommandDisabledForEmptyCombinedFilter() {
        let app = launch()
        app.buttons["searchVacanciesButton"].click()
        XCTAssertTrue(app.staticTexts["vacancyTitle.ui-1"].waitForExistence(timeout: 8))
        choose("Банк России", from: "employerFilterPicker", in: app)
        choose("Удалённо", from: "regionFilterPicker", in: app)
        XCTAssertTrue(app.staticTexts["Вакансий не найдено"].waitForExistence(timeout: 5))
        let report = app.buttons["exportStatisticsPDFButton"]
        XCTAssertFalse(report.isEnabled)
        XCTAssertEqual(report.label, "Статистика в PDF")
        XCTAssertEqual(report.frame.height, 32, accuracy: 2)
        XCTAssertEqual(app.staticTexts["displayedVacancyCount"].value as? String, "Вакансий: 0")
    }

    func testCancellingRefreshKeepsPreviousResults() {
        let app = launch(scenario: "slowRefresh")
        let button = app.buttons["searchVacanciesButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.click()
        XCTAssertTrue(app.staticTexts["vacancyTitle.ui-1"].waitForExistence(timeout: 8))

        button.click()
        XCTAssertTrue(waitForLabel("Отменить", of: button), "Refresh must turn the button into a cancel command")
        XCTAssertTrue(button.isEnabled)
        let loading = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        loading.name = "Refresh in progress with cancel command"
        loading.lifetime = .keepAlways
        add(loading)

        button.click()
        XCTAssertTrue(waitForLabel("Обновить", of: button, timeout: 10), "Cancelled refresh must end promptly")
        XCTAssertTrue(app.staticTexts["vacancyTitle.ui-1"].exists, "Previous results stay after cancellation")
        XCTAssertFalse(app.descendants(matching: .any)["collectionWarning"].exists)
    }

    func testCancellingFirstSearchReturnsToInitialScreen() {
        let app = launch(scenario: "slowSearch")
        let button = app.buttons["searchVacanciesButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.click()
        XCTAssertTrue(waitForLabel("Отменить", of: button))
        XCTAssertTrue(app.staticTexts["Загружаем вакансии всех настроенных работодателей…"].exists)

        button.click()
        XCTAssertTrue(waitForLabel("Обновить", of: button, timeout: 10))
        let emptyButton = app.buttons["emptyRefreshVacanciesButton"]
        XCTAssertTrue(app.staticTexts["Загрузите вакансии hh.ru кнопкой «Обновить»."].waitForExistence(timeout: 5))
        XCTAssertFalse(emptyButton.exists)
        XCTAssertFalse(app.staticTexts["Вакансий не найдено"].exists)
    }

    func testPartialSearchKeepsSnapshotUnpublished() {
        let app = launch(scenario: "partial")
        app.buttons["searchVacanciesButton"].click()
        XCTAssertTrue(app.descendants(matching: .any)["collectionWarning"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["vacancyTitle.ui-1"].exists)
        app.radioButtons["trudvsem.ru"].click()
        XCTAssertFalse(app.descendants(matching: .any)["collectionWarning"].exists)
    }

    private func waitForLabel(_ label: String, of element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func choose(_ option: String, from pickerIdentifier: String, in app: XCUIApplication) {
        let picker = app.descendants(matching: .any)[pickerIdentifier]
        guard picker.waitForExistence(timeout: 5) else {
            XCTFail("Missing picker \(pickerIdentifier)")
            return
        }
        let hittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"),
            object: picker
        )
        guard XCTWaiter.wait(for: [hittable], timeout: 5) == .completed else {
            XCTFail("Picker \(pickerIdentifier) is not ready for interaction")
            return
        }
        picker.click()
        let item = app.menuItems[option]
        guard item.waitForExistence(timeout: 5) else {
            XCTFail("Missing \(option) in \(pickerIdentifier)")
            return
        }
        item.click()
    }
}
