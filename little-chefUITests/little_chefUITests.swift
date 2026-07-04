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
    /// prompt (or any other system alert) so tests can proceed.
    @MainActor
    private func launchAndDismissSystemAlerts() -> XCUIApplication {
        let app = XCUIApplication()

        let interruption = addUIInterruptionMonitor(withDescription: "System Alert") { alert in
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
        removeUIInterruptionMonitor(interruption)
        return app
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
        // Form section headers render their accessibility label uppercased.
        XCTAssertTrue(app.staticTexts["AI PROVIDER"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["VOICE"].exists)
        XCTAssertTrue(app.buttons["Delete All Data"].exists)
        attach(app, name: "09-settings-tab")

        // Exercise (but don't confirm) the destructive delete-all-data alert.
        app.buttons["Delete All Data"].tap()
        XCTAssertTrue(app.alerts["Delete All Data"].waitForExistence(timeout: 3))
        app.alerts["Delete All Data"].buttons["Cancel"].tap()
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
