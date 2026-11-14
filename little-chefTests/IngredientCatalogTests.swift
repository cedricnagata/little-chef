//
//  IngredientCatalogTests.swift
//  little-chefTests
//
//  The inventory's sections, and the add field's suggestions.
//

import Foundation
import Testing
@testable import little_chef

struct IngredientCatalogTests {
    @Test func catalogItemsGoInTheirSection() {
        #expect(IngredientCatalog.category(of: "Chicken breast") == .proteins)
        #expect(IngredientCatalog.category(of: "Eggs") == .dairy)
        #expect(IngredientCatalog.category(of: "Spaghetti") == .grains)
        #expect(IngredientCatalog.category(of: "Smoked paprika") == .spices)
        #expect(IngredientCatalog.category(of: "Olive oil") == .oils)
        #expect(IngredientCatalog.category(of: "Basil") == .herbs)
        #expect(IngredientCatalog.category(of: "Garlic") == .produce)
    }

    @Test func sectionIgnoresCaseAndPlurals() {
        #expect(IngredientCatalog.category(of: "tomatoes") == .produce)
        #expect(IngredientCatalog.category(of: "BLACK BEANS") == .legumes)
    }

    @Test func theFormDecidesWhereItLives() {
        #expect(IngredientCatalog.category(of: "Frozen peas") == .frozen)
        #expect(IngredientCatalog.category(of: "Peas") == .produce)
        #expect(IngredientCatalog.category(of: "Crushed tomatoes") == .canned)
        #expect(IngredientCatalog.category(of: "Chicken stock") == .canned)
        #expect(IngredientCatalog.category(of: "Coconut milk") == .dairy)
        #expect(IngredientCatalog.category(of: "Peanut butter") == .nuts)
    }

    @Test func unknownNamesFallBackOnTheirWords() {
        #expect(IngredientCatalog.category(of: "Free-range chicken legs") == .proteins)
        #expect(IngredientCatalog.category(of: "Aged gouda cheese") == .dairy)
        #expect(IngredientCatalog.category(of: "Garlic salt") == .spices)
        #expect(IngredientCatalog.category(of: "Kombucha") == .other)
        #expect(IngredientCatalog.category(of: "") == .other)
    }

    @Test func everyCatalogItemHasASection() {
        #expect(IngredientCatalog.all.count > 300)
        #expect(Set(IngredientCatalog.all.map { $0.lowercased() }).count == IngredientCatalog.all.count)
        for name in IngredientCatalog.all {
            #expect(IngredientCatalog.category(of: name) != .other, "\(name)")
        }
    }

    @Test func suggestsWhatWasTyped() {
        let found = IngredientCatalog.suggestions(for: "chick", excluding: [])
        #expect(found.first == "Chicken")
        #expect(found.contains("Chickpeas"))
        #expect(found.contains("Chicken breast"))
        #expect(found.count <= 5)
        // A word inside the name counts too.
        #expect(IngredientCatalog.suggestions(for: "paprika", excluding: []).contains("Smoked paprika"))
    }

    @Test func leavesOutWhatYouHave() {
        let found = IngredientCatalog.suggestions(for: "chick", excluding: ["chickpea", "Chicken Breasts"])
        #expect(!found.contains("Chickpeas"))
        #expect(!found.contains("Chicken breast"))
        #expect(found.contains("Chicken thighs"))
    }

    @Test func needsTwoLetters() {
        #expect(IngredientCatalog.suggestions(for: "c", excluding: []).isEmpty)
        #expect(IngredientCatalog.suggestions(for: "  ", excluding: []).isEmpty)
    }
}
