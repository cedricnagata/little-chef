//
//  ScreenshotFixtures.swift
//  little-chef
//
//  Sample content for the App Store screenshots, which the UI tests take
//  (`testScreenshots`). Only a Debug build launched with `-ui-screenshots` uses it, and then the
//  store is in memory: the Simulator's own recipes and iCloud are never touched.
//

#if DEBUG
import Foundation

enum ScreenshotFixtures {
    static var isActive: Bool { ProcessInfo.processInfo.arguments.contains("-ui-screenshots") }

    /// The recipe the cooking screenshot follows.
    static let cookedRecipeTitle = "Creamy Tuscan Chicken"

    static let recipes: [RecipeData] = [
        RecipeData(
            title: cookedRecipeTitle,
            description: "Seared chicken in a garlic, sun-dried tomato and spinach cream sauce. One pan, about 35 minutes.",
            servings: 4, prepTime: 10, cookTime: 25,
            ingredients: [
                "4 boneless chicken thighs", "1 tsp salt", "1/2 tsp black pepper", "2 tbsp olive oil",
                "4 cloves garlic, minced", "1/2 cup sun-dried tomatoes, chopped", "1 cup heavy cream",
                "1/2 cup chicken stock", "1/2 cup grated parmesan", "2 cups baby spinach",
                "1 tsp Italian seasoning",
            ],
            instructions: [
                "Season the chicken on both sides with the salt and pepper.",
                "Heat the olive oil in a large skillet over medium-high heat. Sear the chicken 5–6 minutes a side until golden and cooked through, then set it aside.",
                "Lower the heat to medium. Add the garlic and sun-dried tomatoes and cook for 1 minute.",
                "Pour in the cream and stock, add the Italian seasoning, and bring to a gentle simmer.",
                "Stir in the parmesan until melted, then the spinach until it wilts.",
                "Return the chicken to the pan and simmer 5 minutes, spooning the sauce over it.",
            ],
            tags: ["dinner", "one pan"], sourceUrl: nil, cuisineType: "Italian", difficulty: "Easy"),
        RecipeData(
            title: "Lemon Herb Salmon",
            description: "Roasted salmon with lemon, dill and garlic butter.",
            servings: 2, prepTime: 10, cookTime: 15,
            ingredients: ["2 salmon fillets", "2 tbsp butter, melted", "1 lemon", "2 cloves garlic, minced",
                          "1 tbsp fresh dill", "1/2 tsp salt"],
            instructions: ["Heat the oven to 400°F.", "Mix the butter, garlic, dill and the lemon's zest.",
                           "Brush it over the salmon and roast 12–15 minutes.", "Squeeze the lemon over to serve."],
            tags: ["dinner", "quick"], sourceUrl: nil, cuisineType: "American", difficulty: "Easy"),
        RecipeData(
            title: "Fluffy Buttermilk Pancakes",
            description: "Tall, tender pancakes for a weekend breakfast.",
            servings: 4, prepTime: 10, cookTime: 15,
            ingredients: ["2 cups flour", "2 tbsp sugar", "2 tsp baking powder", "1/2 tsp baking soda",
                          "2 cups buttermilk", "2 eggs", "3 tbsp butter, melted"],
            instructions: ["Whisk the dry ingredients.", "Whisk the buttermilk, eggs and butter, then fold into the dry.",
                           "Rest 5 minutes.", "Cook 1/4 cup at a time on a buttered griddle, 2 minutes a side."],
            tags: ["breakfast"], sourceUrl: nil, cuisineType: "American", difficulty: "Easy"),
        RecipeData(
            title: "Thai Green Curry",
            description: "Fragrant coconut curry with vegetables, ready in half an hour.",
            servings: 4, prepTime: 15, cookTime: 20,
            ingredients: ["2 tbsp green curry paste", "1 can coconut milk", "1 lb chicken breast, sliced",
                          "1 red bell pepper", "1 cup green beans", "1 tbsp fish sauce", "1 tsp brown sugar",
                          "Thai basil"],
            instructions: ["Fry the curry paste in a splash of coconut milk for 1 minute.",
                           "Add the chicken and cook until no longer pink.",
                           "Pour in the rest of the coconut milk with the vegetables; simmer 10 minutes.",
                           "Season with the fish sauce and sugar, and finish with basil."],
            tags: ["dinner"], sourceUrl: nil, cuisineType: "Thai", difficulty: "Medium"),
        RecipeData(
            title: "Classic Margherita Pizza",
            description: "Crisp homemade pizza with tomato, mozzarella and basil.",
            servings: 2, prepTime: 20, cookTime: 12,
            ingredients: ["1 lb pizza dough", "1/2 cup tomato sauce", "8 oz fresh mozzarella", "Fresh basil",
                          "1 tbsp olive oil"],
            instructions: ["Heat the oven as hot as it goes, with a stone or tray inside.",
                           "Stretch the dough and spread the sauce.", "Top with torn mozzarella.",
                           "Bake 10–12 minutes; finish with basil and olive oil."],
            tags: ["dinner"], sourceUrl: nil, cuisineType: "Italian", difficulty: "Medium"),
    ]

    /// What's in the kitchen: enough for the Tuscan chicken, one or two short for some others.
    static let pantry: [(name: String, isStaple: Bool)] = [
        ("Salt", true), ("Black pepper", true), ("Olive oil", true), ("Flour", true), ("Sugar", true),
        ("Butter", true), ("Chicken thighs", false), ("Garlic", false), ("Sun-dried tomatoes", false),
        ("Heavy cream", false), ("Chicken stock", false), ("Parmesan", false), ("Baby spinach", false),
        ("Italian seasoning", false), ("Eggs", false), ("Lemon", false), ("Coconut milk", false),
        ("Green curry paste", false),
    ]

    static let shoppingList: [(name: String, recipeTitle: String?)] = [
        ("2 salmon fillets", "Lemon Herb Salmon"), ("Fresh dill", "Lemon Herb Salmon"),
        ("2 cups buttermilk", "Fluffy Buttermilk Pancakes"), ("Fresh mozzarella", "Classic Margherita Pizza"),
        ("Fresh basil", "Classic Margherita Pizza"), ("Bananas", nil), ("Coffee beans", nil),
    ]

    /// The conversation the cooking screenshot shows, oldest first.
    static let conversation: [(role: String, text: String)] = [
        ("user", "Can I use half-and-half instead of heavy cream?"),
        ("assistant", "Yes. Use the same cup, but keep it at a gentle simmer rather than a boil so it doesn't split, and stir in a teaspoon of flour first if you'd like it as thick."),
        ("user", "Set a timer for the chicken, 6 minutes."),
        ("assistant", "Your \"Sear chicken\" timer is set for 6 minutes. Say go when the chicken is in the pan."),
        ("user", "Go"),
        ("assistant", "Started. Flip the thighs when it ends, then sear the other side the same way."),
    ]

    static let timer = (name: "Sear chicken", seconds: 6 * 60)
}
#endif
