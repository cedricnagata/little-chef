//
//  little_chefUITests.swift
//  little-chefUITests
//
//  End-to-end smoke tests exercising the main app flows ahead of App Store
//  submission: recipe CRUD via URL import, tab navigation, and Settings.
//

import XCTest

final class little_chefUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Helpers

    /// Launches the app and dismisses the first-run notification permission
    /// prompt (or any other system alert) so tests can proceed. The monitor stays
    /// in place for the whole test (XCTest removes it at teardown): the prompt can
    /// appear after the first tap, and only a later interaction dismisses it.
    @MainActor
    private func launchAndDismissSystemAlerts(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        // Lets the URL import take the offline data: fixture (see fixtureRecipeURL()).
        app.launchArguments.append("-ui-testing")
        app.launchArguments += arguments

        _ = addUIInterruptionMonitor(withDescription: "System Alert") { alert in
            let allow = alert.buttons["Allow"]
            if allow.exists {
                allow.tap()
                return true
            }
            let ok = alert.buttons["OK"]
            if ok.exists {
                ok.tap()
                return true
            }
            return false
        }

        app.launch()
        // Interruption monitors only fire on a subsequent interaction with the app.
        app.tap()
        return app
    }

    /// A Form section header, whatever capitals the iOS version renders it in.
    private func sectionHeader(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", title)).firstMatch
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A self-contained `data:` URL embedding a complete schema.org Recipe as
    /// JSON-LD. WKWebView loads this with no network I/O, so the recipe-import
    /// flow can be tested deterministically and offline — instead of depending on
    /// a live third-party page, whose load time and content are outside this
    /// repo's control and vary widely under test-runner load.
    ///
    /// Percent-encodes *every* non-alphanumeric character (not just the minimal
    /// set required for URL validity): typing this string goes through the
    /// on-screen keyboard one synthesized keystroke at a time, and literal
    /// punctuation (`:`, `/`, `,`, `.`) forces slow page-switches between the
    /// letters and symbols keyboards. An all-alphanumeric-plus-`%` string only
    /// ever needs one keyboard page.
    private func fixtureRecipeURL() -> String {
        let html = """
        <html><script type="application/ld+json">\
        {"@type":"Recipe","name":"Test Fixture Cookies",\
        "prepTime":"PT10M","cookTime":"PT15M",\
        "recipeIngredient":["Flour","Sugar","Butter"],\
        "recipeInstructions":["Mix","Bake"]}\
        </script></html>
        """
        let encoded = html.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? html
        return "data:text/html," + encoded
    }

    // MARK: - Launch

    @MainActor
    func testA_LaunchShowsRecipesTab() throws {
        let app = launchAndDismissSystemAlerts()

        XCTAssertTrue(app.staticTexts["My Recipes"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Recipes"].exists)
        XCTAssertTrue(app.tabBars.buttons["Cook"].exists)
        XCTAssertTrue(app.tabBars.buttons["Settings"].exists)
        attach(app, name: "01-launch-recipes-tab")
    }

    // MARK: - Recipe import (URL), detail, edit, delete — one continuous flow.
    //
    // Combined into a single test (rather than split across testB/testC) because
    // the scheme runs UI tests in parallel across separate simulator clones —
    // each test method gets an independent app instance, so a recipe added in one
    // test method would not be visible from another.

    @MainActor
    func testB_AddRecipeFromURL_EndToEnd() throws {
        let app = launchAndDismissSystemAlerts()
        XCTAssertTrue(app.staticTexts["My Recipes"].waitForExistence(timeout: 10))

        // Open Add Recipe — either the empty-state button or the toolbar "+".
        if app.buttons["Add Recipe"].waitForExistence(timeout: 3) {
            app.buttons["Add Recipe"].tap()
        } else {
            app.navigationBars.buttons.element(boundBy: app.navigationBars.buttons.count - 1).tap()
        }

        XCTAssertTrue(app.navigationBars["Add Recipe"].waitForExistence(timeout: 5))
        attach(app, name: "02-add-recipe-sheet")

        // URL is the default selected input type — enter our offline fixture URL.
        let urlField = app.textFields["https://example.com/recipe"]
        XCTAssertTrue(urlField.waitForExistence(timeout: 5))
        urlField.tap()
        urlField.typeText(fixtureRecipeURL())

        let parseButton = app.buttons["Parse Recipe"]
        XCTAssertTrue(parseButton.exists)
        parseButton.tap()

        // The fixture is a data: URL (no network I/O) so this resolves quickly.
        //
        // NB: XCTWaiter.wait(for: [a, b], timeout:) waits for ALL expectations in
        // the array, not "any of these" — passing [parsedHeader, errorAlert]
        // separately would never succeed, since only one of them is ever true.
        // A single expectation with a block predicate is the correct "wait until
        // either becomes true" construct.
        let parsedHeader = app.staticTexts["Recipe Parsed!"]
        let errorAlert = app.alerts["Error"]
        let eitherAppeared = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in parsedHeader.exists || errorAlert.exists },
            object: nil
        )
        let sawResult = XCTWaiter.wait(for: [eitherAppeared], timeout: 20)
        attach(app, name: "03-parse-result")

        if errorAlert.exists {
            let message = errorAlert.staticTexts.element(boundBy: 1).label
            XCTFail("Recipe parsing surfaced an error alert instead of a parsed recipe: \(message)")
            return
        }
        XCTAssertEqual(sawResult, .completed)
        XCTAssertTrue(parsedHeader.exists, "Expected a parsed recipe preview after submitting the fixture recipe URL")

        // Save it into the library.
        let editAndSave = app.buttons["Edit & Save"]
        XCTAssertTrue(editAndSave.exists)
        editAndSave.tap()

        XCTAssertTrue(app.navigationBars["Edit Recipe"].waitForExistence(timeout: 5))
        attach(app, name: "04-edit-recipe-sheet")

        let saveButton = app.buttons["Save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 3))
        saveButton.tap()

        // Back on the recipe list — the new recipe should appear.
        XCTAssertTrue(app.staticTexts["My Recipes"].waitForExistence(timeout: 10))
        let fixtureCell = app.staticTexts["Test Fixture Cookies"]
        XCTAssertTrue(
            fixtureCell.waitForExistence(timeout: 5) || app.cells.count > 0,
            "Expected the newly imported recipe to appear in the list"
        )
        attach(app, name: "05-recipe-in-list")

        // Continue straight into detail view + delete, using the recipe just added.
        app.cells.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Recipe"].waitForExistence(timeout: 5))
        attach(app, name: "06-recipe-detail")

        // Overflow menu is the sole trailing nav bar button in display mode.
        let menuButton = app.navigationBars.buttons.element(boundBy: app.navigationBars.buttons.count - 1)
        menuButton.tap()

        XCTAssertTrue(app.buttons["Delete Recipe"].waitForExistence(timeout: 3))
        app.buttons["Delete Recipe"].tap()

        XCTAssertTrue(app.alerts["Delete Recipe"].waitForExistence(timeout: 3))
        app.alerts["Delete Recipe"].buttons["Delete"].tap()

        // Deleting dismisses back to the list.
        XCTAssertTrue(app.staticTexts["My Recipes"].waitForExistence(timeout: 10))
        attach(app, name: "07-after-delete")
    }

    // MARK: - Cook tab (no active session)

    @MainActor
    func testD_CookTabShowsStartCooking() throws {
        let app = launchAndDismissSystemAlerts()
        XCTAssertTrue(app.staticTexts["My Recipes"].waitForExistence(timeout: 10))

        app.tabBars.buttons["Cook"].tap()
        XCTAssertTrue(app.staticTexts["Start Cooking"].waitForExistence(timeout: 10))
        attach(app, name: "08-cook-tab-empty-state")
    }

    // MARK: - Settings tab

    @MainActor
    func testE_SettingsTabRenders() throws {
        let app = launchAndDismissSystemAlerts()
        XCTAssertTrue(app.staticTexts["My Recipes"].waitForExistence(timeout: 10))

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        // Older iOS upper-cases Form section headers ("AI PROVIDER"); iOS 26 shows them as
        // written ("AI Provider"). Match either.
        XCTAssertTrue(sectionHeader("AI Provider", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(sectionHeader("Voice", in: app).exists)
        // The Form is lazy: Delete All Data, in the last section, is not in the
        // accessibility tree until it is scrolled into view.
        let deleteAll = app.buttons["Delete All Data"]
        for _ in 0..<6 where !(deleteAll.exists && deleteAll.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(deleteAll.exists && deleteAll.isHittable)
        attach(app, name: "09-settings-tab")

        // Exercise (but don't confirm) the destructive delete-all-data dialog. It is a
        // confirmationDialog, so XCUITest sees a Sheet titled with its question. Older iOS
        // shows an action sheet with Cancel; iOS 26 a popover with no Cancel, which a tap
        // outside it dismisses.
        deleteAll.tap()
        let dialog = app.sheets["Delete all data?"]
        XCTAssertTrue(dialog.waitForExistence(timeout: 3))
        XCTAssertTrue(dialog.buttons["Delete All Data"].exists)
        let cancel = dialog.buttons["Cancel"]
        if cancel.exists {
            cancel.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).tap()
        }
        XCTAssertTrue(dialog.waitForNonExistence(timeout: 3))
    }

    // MARK: - App Store screenshots

    /// The App Store screenshots, from sample content (ScreenshotFixtures) in an in-memory store.
    /// Each is an attachment named `appstore-NN-…`; run on a 6.9" iPhone and a 13" iPad
    /// Simulator for Apple's required sizes. Skipped unless SCREENSHOTS=1, so ordinary runs
    /// don't spend time on it.
    @MainActor
    func testScreenshots() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SCREENSHOTS"] == "1",
                          "set SCREENSHOTS=1 to take the App Store screenshots")
        let app = launchAndDismissSystemAlerts(arguments: ["-ui-screenshots"])
        let title = "Creamy Tuscan Chicken"
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10))
        storeShot(app, "01-recipes")

        app.staticTexts[title].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Recipe"].waitForExistence(timeout: 5))
        storeShot(app, "02-recipe")

        // Start Cooking is in the detail view's ••• menu.
        let more = app.navigationBars["Recipe"].buttons.matching(
            NSPredicate(format: "label IN {'More', 'ellipsis.circle'} OR identifier == 'ellipsis.circle'")).firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap()
        app.buttons["Start Cooking"].firstMatch.tap()
        let cookAnyway = app.buttons["Cook Anyway"]
        if cookAnyway.waitForExistence(timeout: 2) { cookAnyway.tap() }
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Can I use half-and-half'"))
            .firstMatch.waitForExistence(timeout: 10))
        storeShot(app, "03-cooking")

        app.tabBars.buttons["Kitchen"].tap()
        XCTAssertTrue(app.navigationBars["Kitchen"].waitForExistence(timeout: 5))
        storeShot(app, "04-inventory")

        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Shopping List'")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Bananas"].waitForExistence(timeout: 5))
        storeShot(app, "05-shopping")
    }

    /// A full-resolution screenshot of the whole screen, kept with the result bundle.
    private func storeShot(_ app: XCUIApplication, _ name: String) {
        sleep(1)  // let animations settle
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "appstore-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
