//
//  KitchenEntities.swift
//  little-chef
//
//  SwiftData models for the ingredient inventory and the shopping list. Mirrored to iCloud
//  with the recipes, so every property has a default and nothing is `@Attribute(.unique)`:
//  CloudKit mirroring refuses both.
//

import Foundation
import SwiftData

/// An ingredient the user has in.
@Model
final class PantryItemEntity {
    var id: UUID = UUID()
    var name: String = ""
    /// Free text, e.g. "half a bag". Never parsed.
    var note: String?
    /// Counts as always on hand: salt, oil and the like. Shown in its own section.
    var isStaple: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(name: String, note: String? = nil, isStaple: Bool = false) {
        self.name = name
        self.note = note
        self.isStaple = isStaple
    }

    func toItem() -> PantryItem {
        PantryItem(id: id, name: name, note: note, isStaple: isStaple, createdAt: createdAt)
    }
}

/// Something to buy.
@Model
final class ShoppingItemEntity {
    var id: UUID = UUID()
    var name: String = ""
    var note: String?
    /// Bought, but not yet moved into the inventory.
    var isChecked: Bool = false
    /// The recipe it was added for, if any, so the list can say why it's there.
    var recipeTitle: String?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(name: String, note: String? = nil, recipeTitle: String? = nil) {
        self.name = name
        self.note = note
        self.recipeTitle = recipeTitle
    }

    func toItem() -> ShoppingItem {
        ShoppingItem(id: id, name: name, note: note, isChecked: isChecked, recipeTitle: recipeTitle, createdAt: createdAt)
    }
}

struct PantryItem: Identifiable, Equatable {
    let id: UUID
    let name: String
    let note: String?
    let isStaple: Bool
    let createdAt: Date
}

struct ShoppingItem: Identifiable, Equatable {
    let id: UUID
    let name: String
    let note: String?
    let isChecked: Bool
    let recipeTitle: String?
    let createdAt: Date
}
