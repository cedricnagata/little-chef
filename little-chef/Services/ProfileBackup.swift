//
//  ProfileBackup.swift
//  little-chef
//
//  Settings → Export Profile and Import Profile: everything the user keeps in the app, as one
//  JSON file. Data lives on the device only, so this is how it moves to a new phone or survives
//  deleting the app. Foundation only, so the format and the merge are tested on Linux.
//

import Foundation

/// A whole profile: recipes, inventory, shopping list and settings.
///
/// Not in it: downloaded models (gigabytes, and downloadable again), paired Macs (a pairing
/// belongs to one device), and the timers and conversation of a cook in progress.
struct ProfileBackup: Codable {
    static let formatName = "littlechef-profile"
    static let currentVersion = 1

    /// Always `formatName`, so a stray JSON file is refused rather than read as an empty profile.
    var format: String = ProfileBackup.formatName
    var version: Int = ProfileBackup.currentVersion
    var exportedAt: Date
    var recipes: [Recipe]
    var pantry: [PantryEntry]
    var shoppingList: [ShoppingEntry]
    var settings: Settings

    struct PantryEntry: Codable, Equatable {
        var name: String
        var note: String?
        var isStaple: Bool
        var createdAt: Date
    }

    struct ShoppingEntry: Codable, Equatable {
        var name: String
        var note: String?
        var isChecked: Bool
        var recipeTitle: String?
        var createdAt: Date
    }

    struct Settings: Codable, Equatable {
        var voiceSettings: LocalVoiceSettings
        var llmProvider: LLMProvider
        /// The on-device model picked on the exporting device. Restored only where this device
        /// can run it.
        var onDeviceModel: CookingModelChoice?
    }

    // MARK: - File

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> ProfileBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // The header first, so a file from a newer app says so instead of failing on whatever
        // field it added.
        struct Header: Decodable { var format: String?; var version: Int? }
        guard let header = try? decoder.decode(Header.self, from: data),
              header.format == formatName, let version = header.version else {
            throw ProfileBackupError.notAProfile
        }
        guard version <= currentVersion else { throw ProfileBackupError.newerVersion }

        do {
            return try decoder.decode(ProfileBackup.self, from: data)
        } catch {
            throw ProfileBackupError.damaged
        }
    }

    /// A file name for the export, such as "LittleChef Profile 2026-11-09".
    static func suggestedFileName(on date: Date = Date()) -> String {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        return "LittleChef Profile \(day.string(from: date))"
    }

    // MARK: - Merging into what's already here

    /// What importing adds to the store. Importing merges rather than replaces, so nothing
    /// already on this device is lost:
    ///
    /// - A recipe is matched by its id. It's added when new here, and replaces this device's copy
    ///   only when the file's was edited more recently.
    /// - Inventory and shopping items are matched by name, as adding one by hand is
    ///   (`IngredientMatcher.sameItem`). Only names not already here are added.
    /// - Settings are replaced by the file's.
    struct ImportPlan {
        var recipesToAdd: [Recipe] = []
        var recipesToUpdate: [Recipe] = []
        var pantryToAdd: [PantryEntry] = []
        var shoppingToAdd: [ShoppingEntry] = []

        var isEmpty: Bool {
            recipesToAdd.isEmpty && recipesToUpdate.isEmpty && pantryToAdd.isEmpty && shoppingToAdd.isEmpty
        }
    }

    func importPlan(
        existingRecipes: [UUID: Date],
        existingPantryNames: [String],
        existingShoppingNames: [String]
    ) -> ImportPlan {
        var plan = ImportPlan()

        var seenRecipes = Set<UUID>()
        for recipe in recipes where seenRecipes.insert(recipe.id).inserted {
            if let updatedHere = existingRecipes[recipe.id] {
                if recipe.updatedAt > updatedHere { plan.recipesToUpdate.append(recipe) }
            } else {
                plan.recipesToAdd.append(recipe)
            }
        }

        var pantryNames = existingPantryNames
        for item in pantry where !pantryNames.contains(where: { IngredientMatcher.sameItem($0, item.name) }) {
            plan.pantryToAdd.append(item)
            pantryNames.append(item.name)
        }

        var shoppingNames = existingShoppingNames
        for item in shoppingList where !shoppingNames.contains(where: { IngredientMatcher.sameItem($0, item.name) }) {
            plan.shoppingToAdd.append(item)
            shoppingNames.append(item.name)
        }

        return plan
    }
}

/// What an import did, for the message Settings shows afterwards.
struct ProfileImportSummary: Equatable {
    var recipesAdded = 0
    var recipesUpdated = 0
    var pantryAdded = 0
    var shoppingAdded = 0

    var message: String {
        var parts: [String] = []
        if recipesAdded > 0 { parts.append(Self.count(recipesAdded, "new recipe", "new recipes")) }
        if recipesUpdated > 0 { parts.append(Self.count(recipesUpdated, "updated recipe", "updated recipes")) }
        if pantryAdded > 0 { parts.append(Self.count(pantryAdded, "inventory item", "inventory items")) }
        if shoppingAdded > 0 { parts.append(Self.count(shoppingAdded, "shopping list item", "shopping list items")) }
        guard !parts.isEmpty else { return "Settings restored. Everything else in the file was already here." }
        let joined = parts.count == 1
            ? parts[0]
            : parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        return "Added \(joined). Settings restored."
    }

    private static func count(_ n: Int, _ one: String, _ many: String) -> String {
        "\(n) \(n == 1 ? one : many)"
    }
}

enum ProfileBackupError: LocalizedError {
    case notAProfile
    case newerVersion
    case damaged

    var errorDescription: String? {
        switch self {
        case .notAProfile:
            return "That file isn't a LittleChef profile. Choose a file made with Export Profile."
        case .newerVersion:
            return "That profile was exported by a newer version of LittleChef. Update the app, then import it again."
        case .damaged:
            return "That profile couldn't be read. It may be incomplete or damaged."
        }
    }
}
