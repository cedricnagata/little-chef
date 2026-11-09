//
//  ProfileBackupTests.swift
//  little-chefTests
//
//  The profile file Settings exports and imports, and how an import merges into what's there.
//

import Foundation
import Testing
@testable import little_chef

private let day: TimeInterval = 86_400
private let base = Date(timeIntervalSince1970: 1_780_000_000)

private func recipe(_ title: String, id: UUID = UUID(), updated: Date = base) -> Recipe {
    Recipe(id: id, title: title, description: "A dish", servings: 2, prepTime: 5, cookTime: 10,
           ingredients: ["1 egg"], instructions: ["Cook it."], tags: ["quick"], sourceUrl: nil,
           cuisineType: nil, difficulty: "Easy", createdAt: base, updatedAt: updated)
}

private func backup(recipes: [Recipe] = [], pantry: [String] = [], shopping: [String] = []) -> ProfileBackup {
    ProfileBackup(
        exportedAt: base,
        recipes: recipes,
        pantry: pantry.map { .init(name: $0, note: nil, isStaple: false, createdAt: base) },
        shoppingList: shopping.map { .init(name: $0, note: "x", isChecked: true, recipeTitle: nil, createdAt: base) },
        settings: .init(voiceSettings: .defaultSettings, llmProvider: .bigBro, onDeviceModel: .bonsai2_4B)
    )
}

// MARK: - The file

@Test func aProfileSurvivesTheRoundTrip() throws {
    let original = backup(recipes: [recipe("Pancakes")], pantry: ["Eggs"], shopping: ["Milk"])
    let decoded = try ProfileBackup.decode(original.encoded())
    #expect(decoded.format == "littlechef-profile")
    #expect(decoded.version == ProfileBackup.currentVersion)
    #expect(decoded.exportedAt == base)
    #expect(decoded.recipes.map(\.id) == original.recipes.map(\.id))
    #expect(decoded.recipes.first?.ingredients == ["1 egg"])
    #expect(decoded.recipes.first?.updatedAt == base)
    #expect(decoded.pantry == original.pantry)
    #expect(decoded.shoppingList == original.shoppingList)
    #expect(decoded.settings == original.settings)
}

@Test func otherJSONIsNotAProfile() {
    for json in [#"{"recipes": []}"#, #"[1, 2]"#, "not json", #"{"format": "something-else", "version": 1}"#] {
        #expect(throws: ProfileBackupError.self) { try ProfileBackup.decode(Data(json.utf8)) }
        do { _ = try ProfileBackup.decode(Data(json.utf8)) } catch {
            #expect(error as? ProfileBackupError == .notAProfile)
        }
    }
}

@Test func aNewerFileSaysSo() {
    let json = #"{"format": "littlechef-profile", "version": 99, "whatever": true}"#
    do {
        _ = try ProfileBackup.decode(Data(json.utf8))
        Issue.record("decoded a file from a newer version")
    } catch {
        #expect(error as? ProfileBackupError == .newerVersion)
    }
}

@Test func anIncompleteFileIsDamaged() {
    let json = #"{"format": "littlechef-profile", "version": 1, "recipes": []}"#
    do {
        _ = try ProfileBackup.decode(Data(json.utf8))
        Issue.record("decoded an incomplete file")
    } catch {
        #expect(error as? ProfileBackupError == .damaged)
    }
}

@Test func theFileNameCarriesTheDate() {
    #expect(ProfileBackup.suggestedFileName(on: Date(timeIntervalSince1970: 1_794_182_400)).hasPrefix("LittleChef Profile 2026-11-"))
}

// MARK: - Merging

@Test func newRecipesAreAddedAndNewerOnesReplaceOlder() {
    let same = UUID(), newerThere = UUID(), olderThere = UUID()
    let file = backup(recipes: [
        recipe("Already here", id: same, updated: base),
        recipe("Edited since", id: newerThere, updated: base + day),
        recipe("Stale copy", id: olderThere, updated: base),
        recipe("Brand new"),
    ])
    let plan = file.importPlan(
        existingRecipes: [same: base, newerThere: base, olderThere: base + day],
        existingPantryNames: [], existingShoppingNames: [])
    #expect(plan.recipesToAdd.map(\.title) == ["Brand new"])
    #expect(plan.recipesToUpdate.map(\.title) == ["Edited since"])
}

@Test func itemsAreMatchedByNameAsAddingOneIs() {
    let file = backup(pantry: ["Eggs", "Garlic", "garlic", "Butter"], shopping: ["Milk", "Bananas"])
    let plan = file.importPlan(existingRecipes: [:], existingPantryNames: ["egg", "Butter"], existingShoppingNames: ["milk"])
    #expect(plan.pantryToAdd.map(\.name) == ["Garlic"])
    #expect(plan.shoppingToAdd.map(\.name) == ["Bananas"])
    #expect(plan.shoppingToAdd.first?.isChecked == true)
}

@Test func importingTheSameFileTwiceAddsNothing() throws {
    let file = backup(recipes: [recipe("Pancakes")], pantry: ["Eggs"], shopping: ["Milk"])
    let first = file.importPlan(existingRecipes: [:], existingPantryNames: [], existingShoppingNames: [])
    let decoded = try ProfileBackup.decode(file.encoded())
    let second = decoded.importPlan(
        existingRecipes: Dictionary(uniqueKeysWithValues: first.recipesToAdd.map { ($0.id, $0.updatedAt) }),
        existingPantryNames: first.pantryToAdd.map(\.name),
        existingShoppingNames: first.shoppingToAdd.map(\.name))
    #expect(second.isEmpty)
}

@Test func theSummaryNamesWhatChanged() {
    #expect(ProfileImportSummary().message == "Settings restored. Everything else in the file was already here.")
    #expect(ProfileImportSummary(recipesAdded: 1).message == "Added 1 new recipe. Settings restored.")
    #expect(ProfileImportSummary(recipesAdded: 3, recipesUpdated: 1, pantryAdded: 2, shoppingAdded: 1).message
            == "Added 3 new recipes, 1 updated recipe, 2 inventory items and 1 shopping list item. Settings restored.")
}

@Test func aProfileFromTheFirstBonsaiFamilyStillImports() throws {
    var json = String(decoding: try backup().encoded(), as: UTF8.self)
    json = json.replacingOccurrences(of: "\"bonsai2_4b\"", with: "\"bonsai8b\"")
    #expect(try ProfileBackup.decode(Data(json.utf8)).settings.onDeviceModel == .bonsai2_9B)
    json = json.replacingOccurrences(of: "\"bonsai8b\"", with: "\"some-future-model\"")
    #expect(try ProfileBackup.decode(Data(json.utf8)).settings.onDeviceModel == nil)
}
