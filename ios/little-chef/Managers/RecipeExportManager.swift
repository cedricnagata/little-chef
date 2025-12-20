//
//  RecipeExportManager.swift
//  little-chef
//
//  Recipe export/import manager for sharing recipes via .littlechef files
//

import Foundation

@MainActor
class RecipeExportManager: ObservableObject {

    // MARK: - Export

    /// Export a recipe to a .littlechef file
    /// - Parameter recipe: The recipe to export
    /// - Returns: URL of the temporary file
    func exportRecipe(_ recipe: Recipe) throws -> URL {
        // Convert Recipe to RecipeBase (without id/timestamps)
        let recipeBase = RecipeBase(from: recipe)

        // Create export format with metadata
        let exportData = RecipeExportFormat(
            version: RecipeExportFormat.currentVersion,
            exportedAt: Date(),
            recipe: recipeBase
        )

        // Encode to JSON
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let jsonData = try encoder.encode(exportData)

        // Create filename from recipe title
        let filename = recipe.title.sanitizedFilename() + ".littlechef"

        // Write to temporary directory
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(filename)

        try jsonData.write(to: tempURL)

        return tempURL
    }

    // MARK: - Import

    /// Import a recipe from a .littlechef file
    /// - Parameter url: URL of the .littlechef file
    /// - Returns: RecipeBase that can be used to create a new Recipe
    func importRecipe(from url: URL) throws -> RecipeBase {
        // Read file data
        let data = try Data(contentsOf: url)

        // Decode JSON
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let exportFormat: RecipeExportFormat
        do {
            exportFormat = try decoder.decode(RecipeExportFormat.self, from: data)
        } catch {
            throw RecipeImportError.invalidFileFormat
        }

        // Validate version
        guard exportFormat.version <= RecipeExportFormat.currentVersion else {
            throw RecipeImportError.unsupportedVersion
        }

        // Validate required fields
        let recipe = exportFormat.recipe
        guard !recipe.title.isEmpty else {
            throw RecipeImportError.missingRequiredFields
        }

        guard !recipe.ingredients.isEmpty else {
            throw RecipeImportError.missingRequiredFields
        }

        guard !recipe.instructions.isEmpty else {
            throw RecipeImportError.missingRequiredFields
        }

        return recipe
    }
}

// MARK: - Export Format

struct RecipeExportFormat: Codable {
    static let currentVersion = 1

    let version: Int
    let exportedAt: Date
    let recipe: RecipeBase

    enum CodingKeys: String, CodingKey {
        case version
        case exportedAt = "exported_at"
        case recipe
    }
}

// MARK: - Import Errors

enum RecipeImportError: LocalizedError {
    case invalidFileFormat
    case unsupportedVersion
    case corruptedData
    case missingRequiredFields

    var errorDescription: String? {
        switch self {
        case .invalidFileFormat:
            return "This file is not a valid LittleChef recipe"
        case .unsupportedVersion:
            return "This recipe was created with a newer version of LittleChef"
        case .corruptedData:
            return "The recipe file is corrupted"
        case .missingRequiredFields:
            return "The recipe is missing required information"
        }
    }
}

// MARK: - String Extensions

extension String {
    /// Sanitize a string for use as a filename
    func sanitizedFilename() -> String {
        // Remove invalid filesystem characters
        let invalidChars = CharacterSet(charactersIn: ":/\\?%*|\"<>")

        let sanitized = self.components(separatedBy: invalidChars)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)

        // Limit length to 100 characters
        if sanitized.count > 100 {
            return String(sanitized.prefix(100))
        }

        return sanitized.isEmpty ? "recipe" : sanitized
    }
}
