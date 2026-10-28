import XCTest

final class HHVacancyCBRUITests: XCTestCase {
    private func launch(scenario: String = "default") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HHVACANCYCBR_UI_TEST_MODE"] = "1"
        app.launchEnvironment["HHVACANCYCBR_UI_TEST_SCENARIO"] = scenario
        app.launch()
        return app
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
