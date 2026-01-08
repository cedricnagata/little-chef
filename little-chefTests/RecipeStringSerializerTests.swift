//
//  RecipeStringSerializerTests.swift
//  little-chefTests
//
//  Unit tests for RecipeStringSerializer
//

import XCTest
@testable import little_chef

final class RecipeStringSerializerTests: XCTestCase {

    // MARK: - Round-Trip Tests

    func testRoundTripSerializationComplete() throws {
        // Test recipe with all fields populated
        let original = RecipeBase(
            title: "Chocolate Chip Cookies",
            description: "Classic homemade cookies",
            servings: 24,
            prepTime: 15,
            cookTime: 12,
            ingredients: [
                "2 cups all-purpose flour",
                "1 cup granulated sugar",
                "1/2 cup butter, softened",
                "2 large eggs",
                "1 tsp vanilla extract",
                "1 cup chocolate chips"
            ],
            instructions: [
                "Preheat oven to 350°F",
                "Mix dry ingredients in a bowl",
                "Cream butter and sugar",
                "Add eggs and vanilla",
                "Combine wet and dry ingredients",
                "Fold in chocolate chips",
                "Drop spoonfuls onto baking sheet",
                "Bake for 10-12 minutes"
            ],
            tags: ["dessert", "baking", "cookies"],
            sourceUrl: "https://example.com/cookies",
            cuisineType: "American",
            difficulty: "easy"
        )

        // Serialize
        let serialized = RecipeStringSerializer.serialize(original)

        // Deserialize
        let deserialized = try RecipeStringSerializer.deserialize(serialized)

        // Verify all fields match
        XCTAssertEqual(deserialized.title, original.title)
        XCTAssertEqual(deserialized.description, original.description)
        XCTAssertEqual(deserialized.servings, original.servings)
        XCTAssertEqual(deserialized.prepTime, original.prepTime)
        XCTAssertEqual(deserialized.cookTime, original.cookTime)
        XCTAssertEqual(deserialized.ingredients, original.ingredients)
        XCTAssertEqual(deserialized.instructions, original.instructions)
        XCTAssertEqual(deserialized.tags, original.tags)
        XCTAssertEqual(deserialized.sourceUrl, original.sourceUrl)
        XCTAssertEqual(deserialized.cuisineType, original.cuisineType)
        XCTAssertEqual(deserialized.difficulty, original.difficulty)
    }

    func testRoundTripSerializationMinimal() throws {
        // Test recipe with only required fields
        let original = RecipeBase(
            title: "Simple Pasta",
            description: nil,
            servings: 2,
            prepTime: nil,
            cookTime: nil,
            ingredients: ["1 lb pasta", "2 cups sauce"],
            instructions: ["Boil pasta", "Add sauce"],
            tags: [],
            sourceUrl: nil,
            cuisineType: nil,
            difficulty: nil
        )

        let serialized = RecipeStringSerializer.serialize(original)
        let deserialized = try RecipeStringSerializer.deserialize(serialized)

        XCTAssertEqual(deserialized.title, original.title)
        XCTAssertNil(deserialized.description)
        XCTAssertEqual(deserialized.servings, original.servings)
        XCTAssertNil(deserialized.prepTime)
        XCTAssertNil(deserialized.cookTime)
        XCTAssertEqual(deserialized.ingredients, original.ingredients)
        XCTAssertEqual(deserialized.instructions, original.instructions)
        XCTAssertEqual(deserialized.tags, [])
        XCTAssertNil(deserialized.sourceUrl)
        XCTAssertNil(deserialized.cuisineType)
        XCTAssertNil(deserialized.difficulty)
    }

    // MARK: - Edge Case Tests

    func testSerializeWithSpecialCharacters() throws {
        let original = RecipeBase(
            title: "Mom's \"Famous\" Recipe: Coq au Vin",
            description: "A recipe with special chars: & < > ' \"",
            servings: 4,
            prepTime: nil,
            cookTime: nil,
            ingredients: ["1/2 cup wine", "Salt & pepper to taste"],
            instructions: ["Cook @ 350°F", "Let it \"rest\" for 5 min"],
            tags: ["french", "coq-au-vin"],
            sourceUrl: "https://example.com/recipe?id=123&lang=en",
            cuisineType: "French",
            difficulty: "medium"
        )

        let serialized = RecipeStringSerializer.serialize(original)
        let deserialized = try RecipeStringSerializer.deserialize(serialized)

        XCTAssertEqual(deserialized.title, original.title)
        XCTAssertEqual(deserialized.description, original.description)
        XCTAssertEqual(deserialized.ingredients, original.ingredients)
        XCTAssertEqual(deserialized.instructions, original.instructions)
        XCTAssertEqual(deserialized.sourceUrl, original.sourceUrl)
    }

    func testSerializeWithEmptyStrings() throws {
        let original = RecipeBase(
            title: "Simple Recipe",
            description: "",
            servings: 1,
            prepTime: nil,
            cookTime: nil,
            ingredients: ["Ingredient 1"],
            instructions: ["Step 1"],
            tags: [],
            sourceUrl: "",
            cuisineType: "",
            difficulty: ""
        )

        let serialized = RecipeStringSerializer.serialize(original)
        let deserialized = try RecipeStringSerializer.deserialize(serialized)

        // Empty strings should not be included in serialized output
        XCTAssertFalse(serialized.contains("description:"))
        XCTAssertFalse(serialized.contains("source_url:"))
        XCTAssertFalse(serialized.contains("cuisine_type:"))
        XCTAssertFalse(serialized.contains("difficulty:"))
    }

    func testSerializeWithLongText() throws {
        let longDescription = String(repeating: "This is a long description. ", count: 50)
        let longIngredient = String(repeating: "A very detailed ingredient description ", count: 20)
        let longInstruction = String(repeating: "An extremely detailed cooking instruction ", count: 30)

        let original = RecipeBase(
            title: "Complex Recipe",
            description: longDescription,
            servings: 10,
            prepTime: 60,
            cookTime: 120,
            ingredients: [longIngredient],
            instructions: [longInstruction],
            tags: ["complex"],
            sourceUrl: nil,
            cuisineType: nil,
            difficulty: nil
        )

        let serialized = RecipeStringSerializer.serialize(original)
        let deserialized = try RecipeStringSerializer.deserialize(serialized)

        XCTAssertEqual(deserialized.description, original.description)
        XCTAssertEqual(deserialized.ingredients, original.ingredients)
        XCTAssertEqual(deserialized.instructions, original.instructions)
    }

    func testSerializeWithManyItems() throws {
        // Test with large number of ingredients and instructions
        let ingredients = (1...50).map { "Ingredient \($0)" }
        let instructions = (1...30).map { "Step \($0): Do something detailed" }
        let tags = (1...20).map { "tag\($0)" }

        let original = RecipeBase(
            title: "Complex Multi-Step Recipe",
            description: "A recipe with many items",
            servings: 100,
            prepTime: 120,
            cookTime: 180,
            ingredients: ingredients,
            instructions: instructions,
            tags: tags,
            sourceUrl: nil,
            cuisineType: nil,
            difficulty: nil
        )

        let serialized = RecipeStringSerializer.serialize(original)
        let deserialized = try RecipeStringSerializer.deserialize(serialized)

        XCTAssertEqual(deserialized.ingredients.count, 50)
        XCTAssertEqual(deserialized.instructions.count, 30)
        XCTAssertEqual(deserialized.tags.count, 20)
        XCTAssertEqual(deserialized.ingredients, original.ingredients)
        XCTAssertEqual(deserialized.instructions, original.instructions)
        XCTAssertEqual(deserialized.tags, original.tags)
    }

    // MARK: - Format Verification Tests

    func testSerializedFormatStructure() {
        let recipe = RecipeBase(
            title: "Test Recipe",
            description: "Test description",
            servings: 4,
            prepTime: 10,
            cookTime: 20,
            ingredients: ["Ingredient 1"],
            instructions: ["Step 1"],
            tags: ["tag1"],
            sourceUrl: "https://example.com",
            cuisineType: "Italian",
            difficulty: "easy"
        )

        let serialized = RecipeStringSerializer.serialize(recipe)

        // Verify section markers exist
        XCTAssertTrue(serialized.contains("=== RECIPE ==="))
        XCTAssertTrue(serialized.contains("=== TAGS ==="))
        XCTAssertTrue(serialized.contains("=== INGREDIENTS ==="))
        XCTAssertTrue(serialized.contains("=== INSTRUCTIONS ==="))

        // Verify field format
        XCTAssertTrue(serialized.contains("title: Test Recipe"))
        XCTAssertTrue(serialized.contains("description: Test description"))
        XCTAssertTrue(serialized.contains("servings: 4"))
        XCTAssertTrue(serialized.contains("prep_time: 10"))
        XCTAssertTrue(serialized.contains("cook_time: 20"))
        XCTAssertTrue(serialized.contains("cuisine_type: Italian"))
        XCTAssertTrue(serialized.contains("difficulty: easy"))
        XCTAssertTrue(serialized.contains("source_url: https://example.com"))
    }

    // MARK: - Error Handling Tests

    func testDeserializeInvalidFormat() {
        let invalidString = "This is not a valid recipe format"

        XCTAssertThrowsError(try RecipeStringSerializer.deserialize(invalidString)) { error in
            XCTAssertTrue(error is SerializationError)
            if case SerializationError.missingTitle = error {
                // Expected error
            } else {
                XCTFail("Expected SerializationError.missingTitle")
            }
        }
    }

    func testDeserializeMissingTitle() {
        let noTitleString = """
        === RECIPE ===
        servings: 4

        === INGREDIENTS ===
        Ingredient 1

        === INSTRUCTIONS ===
        Step 1
        """

        XCTAssertThrowsError(try RecipeStringSerializer.deserialize(noTitleString)) { error in
            XCTAssertTrue(error is SerializationError)
            if case SerializationError.missingTitle = error {
                // Expected error
            } else {
                XCTFail("Expected SerializationError.missingTitle")
            }
        }
    }

    // MARK: - Consistency Tests

    func testMultipleRoundTrips() throws {
        // Verify that multiple serialize/deserialize cycles produce same result
        let original = RecipeBase(
            title: "Test Recipe",
            description: "Description",
            servings: 4,
            prepTime: 15,
            cookTime: 30,
            ingredients: ["A", "B", "C"],
            instructions: ["1", "2", "3"],
            tags: ["tag1", "tag2"],
            sourceUrl: nil,
            cuisineType: "Test",
            difficulty: "medium"
        )

        let serialized1 = RecipeStringSerializer.serialize(original)
        let deserialized1 = try RecipeStringSerializer.deserialize(serialized1)
        let serialized2 = RecipeStringSerializer.serialize(deserialized1)
        let deserialized2 = try RecipeStringSerializer.deserialize(serialized2)
        let serialized3 = RecipeStringSerializer.serialize(deserialized2)

        // All serialized versions should be identical
        XCTAssertEqual(serialized1, serialized2)
        XCTAssertEqual(serialized2, serialized3)
    }
}
