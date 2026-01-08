//
//  InlineModificationReview.swift
//  little-chef
//
//  Inline diff view with visual indicators in the recipe itself
//

import SwiftUI

/// Represents a single recipe item (ingredient or instruction) with its diff status
struct DiffItem: Identifiable {
    let id = UUID()
    let index: Int
    let type: ItemType
    let status: DiffStatus
    let modification: RecipeModification?

    enum ItemType {
        case ingredient
        case instruction
    }

    enum DiffStatus {
        case unchanged(value: String)
        case removed(oldValue: String)
        case added(newValue: String)
        case modified(oldValue: String, newValue: String)
    }

    var displayValue: String {
        switch status {
        case .unchanged(let value):
            return value
        case .removed(let oldValue):
            return oldValue
        case .added(let newValue):
            return newValue
        case .modified(_, let newValue):
            return newValue
        }
    }
}

struct InlineModificationReview: View {
    @State var reviewState: ModificationReviewState
    let onComplete: (RecipeBase) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Title section
                    titleSection

                    // Info cards
                    infoCardsSection

                    Divider()

                    // Ingredients section
                    ingredientsSection

                    Divider()

                    // Instructions section
                    instructionsSection
                }
                .padding()
            }
            .navigationTitle("Review \(reviewState.currentDiff.count) Change\(reviewState.currentDiff.count == 1 ? "" : "s")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 12) {
                        // Undo button
                        Button(action: {
                            withAnimation {
                                reviewState.undo()
                            }
                        }) {
                            Label("Undo", systemImage: "arrow.uturn.backward")
                        }
                        .disabled(reviewState.actionHistory.isEmpty)

                        // Accept All
                        Button("Accept All") {
                            withAnimation {
                                reviewState.acceptAll()
                            }
                        }
                        .disabled(reviewState.currentDiff.isEmpty)

                        // Reject All
                        Button("Reject All") {
                            withAnimation {
                                reviewState.rejectAll()
                            }
                        }
                        .tint(.red)
                        .disabled(reviewState.currentDiff.isEmpty)
                    }
                }
            }
            .onChange(of: reviewState.currentDiff.isEmpty) { _, isEmpty in
                if isEmpty {
                    // All changes resolved - apply and close
                    onComplete(reviewState.workingRecipe)
                    dismiss()
                }
            }
        }
    }

    // MARK: - Title Section

    @ViewBuilder
    private var titleSection: some View {
        if let titleMod = reviewState.currentDiff.first(where: { $0.field == "title" }) {
            VStack(alignment: .leading, spacing: 8) {
                // Old title (strikethrough)
                if let oldValue = titleMod.oldValue {
                    Text(oldValue)
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .strikethrough()
                        .foregroundColor(.red.opacity(0.6))
                }

                // New title (highlighted)
                if let newValue = titleMod.newValue {
                    Text(newValue)
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundColor(.green)
                }

                // Accept/Reject buttons
                HStack(spacing: 8) {
                    Button(action: {
                        withAnimation {
                            reviewState.rejectChange(titleMod)
                        }
                    }) {
                        Label("Reject", systemImage: "xmark.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)

                    Button(action: {
                        withAnimation {
                            reviewState.acceptChange(titleMod)
                        }
                    }) {
                        Label("Accept", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(.green)
                }
            }
        } else {
            Text(reviewState.workingRecipe.title)
                .font(.largeTitle)
                .fontWeight(.bold)
        }
    }

    // MARK: - Info Cards

    @ViewBuilder
    private var infoCardsSection: some View {
        HStack(spacing: 12) {
            InfoCardInline(
                title: "Servings",
                value: "\(reviewState.workingRecipe.servings)",
                icon: "person.2.fill",
                isModified: reviewState.currentDiff.contains(where: { $0.field == "servings" })
            )

            if let prepTime = reviewState.workingRecipe.prepTime {
                InfoCardInline(
                    title: "Prep",
                    value: "\(prepTime)m",
                    icon: "clock.fill",
                    isModified: reviewState.currentDiff.contains(where: { $0.field == "prepTime" })
                )
            }

            if let cookTime = reviewState.workingRecipe.cookTime {
                InfoCardInline(
                    title: "Cook",
                    value: "\(cookTime)m",
                    icon: "flame.fill",
                    isModified: reviewState.currentDiff.contains(where: { $0.field == "cookTime" })
                )
            }
        }
    }

    // MARK: - Ingredients Section

    @ViewBuilder
    private var ingredientsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ingredients")
                .font(.title2)
                .fontWeight(.bold)

            let items = buildIngredientDiffItems()
            ForEach(items) { item in
                ingredientRow(item)
            }
        }
    }

    @ViewBuilder
    private func ingredientRow(_ item: DiffItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "circle.fill")
                .font(.system(size: 6))
                .foregroundColor(dotColor(for: item.status))
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 4) {
                switch item.status {
                case .unchanged(let value):
                    Text(value)
                        .font(.body)

                case .removed(let oldValue):
                    HStack(spacing: 8) {
                        Text(oldValue)
                            .font(.body)
                            .strikethrough()
                            .foregroundColor(.red.opacity(0.7))

                        Spacer()

                        if let mod = item.modification {
                            Button(action: {
                                withAnimation {
                                    reviewState.rejectChange(mod)
                                }
                            }) {
                                Label("Keep", systemImage: "arrow.uturn.left")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                        }
                    }
                    .padding(8)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(8)

                case .added(let newValue):
                    HStack(spacing: 8) {
                        Text(newValue)
                            .font(.body)
                            .fontWeight(.medium)

                        Spacer()

                        if let mod = item.modification {
                            HStack(spacing: 4) {
                                Button(action: {
                                    withAnimation {
                                        reviewState.rejectChange(mod)
                                    }
                                }) {
                                    Label("Reject", systemImage: "xmark.circle")
                                        .font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .tint(.red)

                                Button(action: {
                                    withAnimation {
                                        reviewState.acceptChange(mod)
                                    }
                                }) {
                                    Label("Accept", systemImage: "checkmark.circle.fill")
                                        .font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .tint(.green)
                            }
                        }
                    }
                    .padding(8)
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(8)

                case .modified(let oldValue, let newValue):
                    VStack(alignment: .leading, spacing: 4) {
                        // Old value (strikethrough)
                        Text(oldValue)
                            .font(.body)
                            .strikethrough()
                            .foregroundColor(.red.opacity(0.7))

                        // New value (highlighted)
                        Text(newValue)
                            .font(.body)
                            .fontWeight(.medium)
                            .foregroundColor(.green)

                        // Buttons
                        if let mod = item.modification {
                            HStack(spacing: 4) {
                                Button(action: {
                                    withAnimation {
                                        reviewState.rejectChange(mod)
                                    }
                                }) {
                                    Label("Reject", systemImage: "xmark.circle")
                                        .font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .tint(.red)

                                Button(action: {
                                    withAnimation {
                                        reviewState.acceptChange(mod)
                                    }
                                }) {
                                    Label("Accept", systemImage: "checkmark.circle.fill")
                                        .font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .tint(.green)
                            }
                        }
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(8)
                }
            }
        }
    }

    // MARK: - Instructions Section

    @ViewBuilder
    private var instructionsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Instructions")
                .font(.title2)
                .fontWeight(.bold)

            let items = buildInstructionDiffItems()
            ForEach(items) { item in
                instructionRow(item)
            }
        }
    }

    @ViewBuilder
    private func instructionRow(_ item: DiffItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // Step number badge
            Text("\(item.index + 1)")
                .font(.headline)
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .background(badgeColor(for: item.status))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                switch item.status {
                case .unchanged(let value):
                    Text(value)
                        .font(.body)

                case .removed(let oldValue):
                    HStack(alignment: .top, spacing: 8) {
                        Text(oldValue)
                            .font(.body)
                            .strikethrough()
                            .foregroundColor(.red.opacity(0.7))

                        Spacer()

                        if let mod = item.modification {
                            Button(action: {
                                withAnimation {
                                    reviewState.rejectChange(mod)
                                }
                            }) {
                                Label("Keep", systemImage: "arrow.uturn.left")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                        }
                    }
                    .padding(8)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(8)

                case .added(let newValue):
                    HStack(alignment: .top, spacing: 8) {
                        Text(newValue)
                            .font(.body)
                            .fontWeight(.medium)

                        Spacer()

                        if let mod = item.modification {
                            HStack(spacing: 4) {
                                Button(action: {
                                    withAnimation {
                                        reviewState.rejectChange(mod)
                                    }
                                }) {
                                    Label("Reject", systemImage: "xmark.circle")
                                        .font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .tint(.red)

                                Button(action: {
                                    withAnimation {
                                        reviewState.acceptChange(mod)
                                    }
                                }) {
                                    Label("Accept", systemImage: "checkmark.circle.fill")
                                        .font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .tint(.green)
                            }
                        }
                    }
                    .padding(8)
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(8)

                case .modified(let oldValue, let newValue):
                    VStack(alignment: .leading, spacing: 4) {
                        // Old value
                        Text(oldValue)
                            .font(.body)
                            .strikethrough()
                            .foregroundColor(.red.opacity(0.7))

                        // New value
                        Text(newValue)
                            .font(.body)
                            .fontWeight(.medium)
                            .foregroundColor(.green)

                        // Buttons
                        if let mod = item.modification {
                            HStack(spacing: 4) {
                                Button(action: {
                                    withAnimation {
                                        reviewState.rejectChange(mod)
                                    }
                                }) {
                                    Label("Reject", systemImage: "xmark.circle")
                                        .font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .tint(.red)

                                Button(action: {
                                    withAnimation {
                                        reviewState.acceptChange(mod)
                                    }
                                }) {
                                    Label("Accept", systemImage: "checkmark.circle.fill")
                                        .font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .tint(.green)
                            }
                        }
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(8)
                }
            }
        }
    }

    // MARK: - Diff Item Builders

    private func buildIngredientDiffItems() -> [DiffItem] {
        let oldIngredients = reviewState.oldRecipe.ingredients
        let newIngredients = reviewState.newRecipe.ingredients
        var items: [DiffItem] = []

        // Create a map of modifications by index
        var modsByIndex: [Int: RecipeModification] = [:]
        for mod in reviewState.currentDiff where mod.field == "ingredients" {
            if let idx = mod.targetIndex {
                modsByIndex[idx] = mod
            }
        }

        // Build items from oldRecipe (what we're displaying)
        for (index, ingredient) in oldIngredients.enumerated() {
            if let mod = modsByIndex[index] {
                switch mod.modificationType {
                case .ingredientRemove:
                    items.append(DiffItem(
                        index: index,
                        type: .ingredient,
                        status: .removed(oldValue: ingredient),
                        modification: mod
                    ))
                case .ingredientSubstitute, .ingredientQuantity:
                    items.append(DiffItem(
                        index: index,
                        type: .ingredient,
                        status: .modified(oldValue: ingredient, newValue: mod.newValue ?? ingredient),
                        modification: mod
                    ))
                default:
                    items.append(DiffItem(
                        index: index,
                        type: .ingredient,
                        status: .unchanged(value: ingredient),
                        modification: nil
                    ))
                }
            } else {
                items.append(DiffItem(
                    index: index,
                    type: .ingredient,
                    status: .unchanged(value: ingredient),
                    modification: nil
                ))
            }
        }

        // Add any "add" modifications (items in new but not in old)
        for mod in reviewState.currentDiff where mod.field == "ingredients" && mod.modificationType == .ingredientAdd {
            if let newValue = mod.newValue, let targetIdx = mod.targetIndex {
                items.insert(DiffItem(
                    index: targetIdx,
                    type: .ingredient,
                    status: .added(newValue: newValue),
                    modification: mod
                ), at: min(targetIdx, items.count))
            }
        }

        return items
    }

    private func buildInstructionDiffItems() -> [DiffItem] {
        let oldInstructions = reviewState.oldRecipe.instructions
        var items: [DiffItem] = []

        // Create a map of modifications by index
        var modsByIndex: [Int: RecipeModification] = [:]
        for mod in reviewState.currentDiff where mod.field == "instructions" {
            if let idx = mod.targetIndex {
                modsByIndex[idx] = mod
            }
        }

        // Build items from oldRecipe
        for (index, instruction) in oldInstructions.enumerated() {
            if let mod = modsByIndex[index] {
                switch mod.modificationType {
                case .instructionRemove:
                    items.append(DiffItem(
                        index: index,
                        type: .instruction,
                        status: .removed(oldValue: instruction),
                        modification: mod
                    ))
                case .instructionModify:
                    items.append(DiffItem(
                        index: index,
                        type: .instruction,
                        status: .modified(oldValue: instruction, newValue: mod.newValue ?? instruction),
                        modification: mod
                    ))
                default:
                    items.append(DiffItem(
                        index: index,
                        type: .instruction,
                        status: .unchanged(value: instruction),
                        modification: nil
                    ))
                }
            } else {
                items.append(DiffItem(
                    index: index,
                    type: .instruction,
                    status: .unchanged(value: instruction),
                    modification: nil
                ))
            }
        }

        // Add any "add" modifications
        for mod in reviewState.currentDiff where mod.field == "instructions" && mod.modificationType == .instructionAdd {
            if let newValue = mod.newValue, let targetIdx = mod.targetIndex {
                items.insert(DiffItem(
                    index: targetIdx,
                    type: .instruction,
                    status: .added(newValue: newValue),
                    modification: mod
                ), at: min(targetIdx, items.count))
            }
        }

        return items
    }

    // MARK: - Helpers

    private func dotColor(for status: DiffItem.DiffStatus) -> Color {
        switch status {
        case .unchanged:
            return .orange
        case .removed:
            return .red
        case .added:
            return .green
        case .modified:
            return .orange
        }
    }

    private func badgeColor(for status: DiffItem.DiffStatus) -> Color {
        switch status {
        case .unchanged:
            return .orange
        case .removed:
            return .red.opacity(0.7)
        case .added:
            return .green
        case .modified:
            return .orange
        }
    }
}

// MARK: - Info Card with Modification Indicator

struct InfoCardInline: View {
    let title: String
    let value: String
    let icon: String
    let isModified: Bool

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(isModified ? .green : .orange)

            Text(value)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(isModified ? .green : .primary)

            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(isModified ? Color.green.opacity(0.1) : Color(.systemGray6))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isModified ? Color.green : Color.clear, lineWidth: 2)
        )
    }
}

// MARK: - Preview

#Preview {
    let originalRecipe = RecipeBase(
        title: "Chocolate Chip Cookies",
        description: "Classic cookies",
        servings: 24,
        prepTime: 15,
        cookTime: 12,
        ingredients: ["2 cups flour", "1 cup butter", "1 cup sugar"],
        instructions: ["Mix dry ingredients", "Bake at 350°F"],
        tags: [],
        sourceUrl: nil,
        cuisineType: nil,
        difficulty: nil
    )

    let modifiedRecipe = RecipeBase(
        title: "Chocolate Chip Cookies",
        description: "Classic cookies",
        servings: 24,
        prepTime: 15,
        cookTime: 12,
        ingredients: ["2 cups flour", "1 cup olive oil", "1 cup brown sugar", "2 eggs"],
        instructions: ["Mix dry ingredients", "Add wet ingredients", "Bake at 350°F for 12 minutes"],
        tags: [],
        sourceUrl: nil,
        cuisineType: nil,
        difficulty: nil
    )

    let reviewState = ModificationReviewState(
        original: originalRecipe,
        target: modifiedRecipe
    )

    return InlineModificationReview(
        reviewState: reviewState,
        onComplete: { _ in },
        onCancel: { }
    )
}
