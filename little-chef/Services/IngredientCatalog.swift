//
//  IngredientCatalog.swift
//  little-chef
//
//  Kinds of ingredient, and a catalog of common ones: what the inventory is grouped by and
//  what the add field suggests. Foundation only, so the Linux tests cover it.
//

import Foundation

/// The sections of the inventory, in the order they are shown.
enum IngredientCategory: String, CaseIterable, Identifiable {
    case produce = "Produce"
    case herbs = "Fresh Herbs"
    case proteins = "Proteins"
    case dairy = "Dairy & Eggs"
    case grains = "Grains, Pasta & Bread"
    case legumes = "Beans & Legumes"
    case nuts = "Nuts & Seeds"
    case baking = "Baking"
    case spices = "Seasonings & Spices"
    case oils = "Oils & Vinegars"
    case condiments = "Sauces & Condiments"
    case canned = "Canned & Jarred"
    case frozen = "Frozen"
    case drinks = "Drinks"
    case other = "Other"

    var id: String { rawValue }
}

enum IngredientCatalog {
    /// The category of an inventory item: its catalog entry when it has one, then the kind
    /// its words point to ("chicken thighs" → Proteins), then Other.
    static func category(of name: String) -> IngredientCategory {
        let words = categoryWords(of: name)
        guard let last = words.last else { return .other }
        let tokens = Set(words)
        if let exact = byTokens[tokens] { return exact }
        // The longest catalog entry the name contains: "smoked paprika" before "paprika". On a
        // tie, the one with the name's last word, which in English is what the thing is:
        // "garlic salt" is a salt.
        var best: (category: IngredientCategory, score: (Int, Int, Int))?
        for (entry, category) in byTokens where entry.isSubset(of: tokens) {
            let order = IngredientCategory.allCases.firstIndex(of: category) ?? 0
            let score = (entry.count, entry.contains(last) ? 1 : 0, -order)
            if best.map({ score > $0.score }) ?? true { best = (category, score) }
        }
        return best?.category ?? .other
    }

    /// The words that say what kind of thing an item is, singularized. Unlike
    /// ``IngredientMatcher/normalizedTokens(of:)`` this keeps "frozen", "dried" and "crushed",
    /// which don't change whether you have an ingredient but do change where it lives.
    static func categoryWords(of name: String) -> [String] {
        name.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map { IngredientMatcher.singular(String($0)) }
            .filter { !$0.isEmpty }
    }

    /// Catalog ingredients to offer for what has been typed, leaving out what the inventory
    /// already has. A word of the ingredient starting with the query ranks first, then one
    /// containing it; shorter names first within each.
    static func suggestions(for query: String, excluding inventory: [String], limit: Int = 5) -> [String] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard query.count >= 2 else { return [] }
        let owned = inventory.map(IngredientMatcher.normalizedTokens(of:))
        var ranked: [(name: String, rank: Int)] = []
        for name in all {
            let lower = name.lowercased()
            let rank: Int
            if lower.hasPrefix(query) {
                rank = 0
            } else if lower.split(separator: " ").contains(where: { $0.hasPrefix(query) }) {
                rank = 1
            } else if lower.contains(query) {
                rank = 2
            } else {
                continue
            }
            let tokens = IngredientMatcher.normalizedTokens(of: name)
            guard !owned.contains(tokens) else { continue }
            ranked.append((name, rank))
        }
        return ranked
            .sorted { ($0.rank, $0.name.count, $0.name) < ($1.rank, $1.name.count, $1.name) }
            .prefix(limit)
            .map(\.name)
    }

    /// Every catalog ingredient, in category order.
    static let all: [String] = IngredientCategory.allCases.flatMap { entries[$0] ?? [] }

    private static let byTokens: [Set<String>: IngredientCategory] = {
        var map: [Set<String>: IngredientCategory] = [:]
        for category in IngredientCategory.allCases {
            for name in entries[category] ?? [] {
                let tokens = Set(categoryWords(of: name))
                if !tokens.isEmpty, map[tokens] == nil { map[tokens] = category }
            }
        }
        for (word, category) in keywords where map[[word]] == nil {
            map[[word]] = category
        }
        return map
    }()

    /// Single words that settle a kind on their own, for names the catalog doesn't carry:
    /// "free-range chicken legs", "aged gouda".
    private static let keywords: [String: IngredientCategory] = [
        "chicken": .proteins, "beef": .proteins, "pork": .proteins, "lamb": .proteins, "turkey": .proteins,
        "fish": .proteins, "steak": .proteins, "sausage": .proteins, "bacon": .proteins, "ham": .proteins,
        "shrimp": .proteins, "prawn": .proteins, "tofu": .proteins, "mince": .proteins,
        "cheese": .dairy, "milk": .dairy, "cream": .dairy, "yogurt": .dairy, "egg": .dairy,
        "pasta": .grains, "rice": .grains, "bread": .grains, "noodle": .grains, "tortilla": .grains,
        "bean": .legumes, "lentil": .legumes, "chickpea": .legumes,
        "nut": .nuts, "seed": .nuts,
        "flour": .baking, "sugar": .baking,
        "spice": .spices, "seasoning": .spices, "pepper": .spices, "salt": .spices,
        "oil": .oils, "vinegar": .oils,
        "sauce": .condiments, "ketchup": .condiments, "mustard": .condiments, "dressing": .condiments,
        "stock": .canned, "broth": .canned, "canned": .canned,
        "frozen": .frozen,
        "juice": .drinks, "wine": .drinks, "beer": .drinks, "coffee": .drinks, "tea": .drinks,
    ]

    private static let entries: [IngredientCategory: [String]] = [
        .produce: [
            "Onion", "Red onion", "Shallot", "Garlic", "Ginger", "Scallion", "Leek", "Potato", "Sweet potato",
            "Carrot", "Celery", "Tomato", "Cherry tomatoes", "Bell pepper", "Jalapeño", "Chili pepper",
            "Cucumber", "Zucchini", "Eggplant", "Broccoli", "Cauliflower", "Cabbage", "Red cabbage",
            "Brussels sprouts", "Spinach", "Kale", "Lettuce", "Romaine lettuce", "Arugula", "Bok choy",
            "Mushrooms", "Asparagus", "Green beans", "Peas", "Corn", "Butternut squash", "Pumpkin",
            "Beetroot", "Radish", "Turnip", "Parsnip", "Fennel", "Avocado", "Lemon", "Lime", "Orange",
            "Apple", "Banana", "Pear", "Peach", "Mango", "Pineapple", "Strawberries", "Blueberries",
            "Raspberries", "Grapes", "Watermelon", "Cranberries", "Pomegranate", "Coconut",
        ],
        .herbs: [
            "Parsley", "Cilantro", "Basil", "Mint", "Dill", "Chives", "Rosemary", "Thyme", "Sage",
            "Oregano", "Tarragon", "Lemongrass", "Bay leaves",
        ],
        .proteins: [
            "Chicken breast", "Chicken thighs", "Whole chicken", "Chicken wings", "Ground beef", "Steak",
            "Beef chuck", "Pork chops", "Pork shoulder", "Pork belly", "Ground pork", "Bacon", "Ham",
            "Sausage", "Chorizo", "Prosciutto", "Lamb", "Ground lamb", "Ground turkey", "Turkey", "Duck",
            "Salmon", "Tuna", "Cod", "Tilapia", "White fish", "Shrimp", "Scallops", "Mussels", "Clams",
            "Crab", "Anchovies", "Tofu", "Tempeh", "Seitan",
        ],
        .dairy: [
            "Eggs", "Milk", "Butter", "Heavy cream", "Sour cream", "Cream cheese", "Greek yogurt",
            "Yogurt", "Buttermilk", "Half and half", "Cheddar", "Parmesan", "Mozzarella", "Feta",
            "Goat cheese", "Ricotta", "Swiss cheese", "Gruyère", "Monterey Jack", "Blue cheese",
            "Halloumi", "Ghee", "Oat milk", "Almond milk", "Coconut milk",
        ],
        .grains: [
            "Rice", "Brown rice", "Basmati rice", "Jasmine rice", "Arborio rice", "Quinoa", "Couscous",
            "Bulgur", "Oats", "Barley", "Spaghetti", "Penne", "Macaroni", "Fettuccine", "Lasagna sheets",
            "Egg noodles", "Rice noodles", "Ramen noodles", "Udon noodles", "Bread", "Sourdough",
            "Baguette", "Pita", "Naan", "Tortillas", "Corn tortillas", "Breadcrumbs", "Panko",
            "Crackers", "Cornmeal", "Polenta",
        ],
        .legumes: [
            "Black beans", "Kidney beans", "Pinto beans", "Cannellini beans", "Chickpeas", "Lentils",
            "Red lentils", "Split peas", "Edamame",
        ],
        .nuts: [
            "Almonds", "Walnuts", "Pecans", "Cashews", "Peanuts", "Pistachios", "Pine nuts", "Hazelnuts",
            "Sesame seeds", "Sunflower seeds", "Pumpkin seeds", "Chia seeds", "Flaxseed",
            "Peanut butter", "Almond butter", "Tahini",
        ],
        .baking: [
            "All-purpose flour", "Bread flour", "Whole wheat flour", "Cornstarch", "Sugar", "Brown sugar",
            "Powdered sugar", "Honey", "Maple syrup", "Molasses", "Baking soda", "Baking powder",
            "Yeast", "Vanilla extract", "Cocoa powder", "Chocolate chips", "Dark chocolate", "Raisins",
            "Dried cranberries", "Shredded coconut", "Gelatin",
        ],
        .spices: [
            "Salt", "Kosher salt", "Sea salt", "Black pepper", "Red pepper flakes", "Paprika",
            "Smoked paprika", "Cayenne pepper", "Chili powder", "Cumin", "Ground coriander",
            "Turmeric", "Cinnamon", "Nutmeg", "Cloves", "Allspice", "Cardamom", "Ginger powder",
            "Garlic powder", "Onion powder", "Dried oregano", "Dried thyme", "Dried basil",
            "Italian seasoning", "Curry powder", "Garam masala", "Five spice", "Mustard seeds",
            "Fennel seeds", "Star anise", "Saffron", "Everything bagel seasoning", "Taco seasoning",
        ],
        .oils: [
            "Olive oil", "Extra virgin olive oil", "Vegetable oil", "Canola oil", "Sesame oil",
            "Coconut oil", "Avocado oil", "Cooking spray", "Balsamic vinegar", "Red wine vinegar",
            "White wine vinegar", "Apple cider vinegar", "Rice vinegar", "White vinegar",
        ],
        .condiments: [
            "Soy sauce", "Tamari", "Fish sauce", "Oyster sauce", "Hoisin sauce", "Worcestershire sauce",
            "Hot sauce", "Sriracha", "Chili garlic sauce", "Gochujang", "Miso paste", "Ketchup",
            "Mustard", "Dijon mustard", "Mayonnaise", "Barbecue sauce", "Salsa", "Pesto", "Teriyaki sauce",
            "Ranch dressing", "Jam", "Capers", "Olives", "Pickles",
        ],
        .canned: [
            "Canned tomatoes", "Crushed tomatoes", "Tomato paste", "Tomato sauce", "Passata",
            "Chicken stock", "Beef stock", "Vegetable stock", "Coconut cream", "Canned tuna",
            "Canned corn", "Roasted red peppers", "Sun-dried tomatoes", "Artichoke hearts",
            "Curry paste", "Bouillon cubes",
        ],
        .frozen: [
            "Frozen peas", "Frozen corn", "Frozen spinach", "Frozen berries", "Frozen mixed vegetables",
            "Puff pastry", "Pie crust", "Ice cream",
        ],
        .drinks: [
            "White wine", "Red wine", "Beer", "Orange juice", "Coffee", "Tea",
        ],
    ]
}
