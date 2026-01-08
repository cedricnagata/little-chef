//
//  AIEditSheet.swift
//  little-chef
//
//  Modal sheet for AI-powered recipe editing with voice/text input
//

import SwiftUI

struct AIEditSheet: View {
    let currentRecipe: RecipeBase
    let onSubmit: (String) -> Void

    @State private var editInstructions = ""
    @EnvironmentObject var voiceAssistant: VoiceAssistant
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                // Recipe context
                VStack(alignment: .leading, spacing: 8) {
                    Text("Editing: \(currentRecipe.title)")
                        .font(.headline)
                    Text("\(currentRecipe.ingredients.count) ingredients, \(currentRecipe.instructions.count) steps")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)

                // Instructions input
                VStack(alignment: .leading, spacing: 12) {
                    Text("What would you like to change?")
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    TextEditor(text: $editInstructions)
                        .frame(height: 120)
                        .padding(8)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                        )

                    // Voice button
                    Button(action: {
                        if voiceAssistant.isListening {
                            // Stop listening and populate text
                            if !voiceAssistant.recognizedText.isEmpty {
                                editInstructions = voiceAssistant.recognizedText
                            }
                            voiceAssistant.stopListening()
                        } else {
                            // Clear previous text and start listening
                            voiceAssistant.clearRecognizedText()
                            voiceAssistant.startListening()
                        }
                    }) {
                        HStack {
                            Image(systemName: voiceAssistant.isListening ? "mic.fill" : "mic")
                                .font(.title3)
                            Text(voiceAssistant.isListening ? "Stop Recording" : "Record Voice")
                                .font(.subheadline)
                        }
                        .foregroundColor(voiceAssistant.isListening ? .red : .purple)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                    }
                    .disabled(!voiceAssistant.isAvailable)

                    // Example suggestions
                    Text("Examples:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        ExampleButton(text: "Make this recipe vegan", onTap: {
                            editInstructions = "Make this recipe vegan"
                        })
                        ExampleButton(text: "Use olive oil instead of butter", onTap: {
                            editInstructions = "Use olive oil instead of butter"
                        })
                        ExampleButton(text: "Reduce servings to 2", onTap: {
                            editInstructions = "Reduce servings to 2"
                        })
                        ExampleButton(text: "Make it gluten-free", onTap: {
                            editInstructions = "Make it gluten-free"
                        })
                    }
                }

                // Voice listening indicator
                if voiceAssistant.isListening {
                    VStack(spacing: 8) {
                        HStack {
                            Image(systemName: "waveform")
                                .foregroundColor(.red)
                            Text("Listening...")
                                .font(.subheadline)
                                .foregroundColor(.red)
                        }
                        if !voiceAssistant.recognizedText.isEmpty {
                            Text(voiceAssistant.recognizedText)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding()
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(8)
                }

                Spacer()

                // Generate button
                Button(action: {
                    onSubmit(editInstructions)
                    dismiss()
                }) {
                    HStack {
                        Image(systemName: "wand.and.stars")
                        Text("Generate Suggestions")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(editInstructions.isEmpty ? Color.gray : Color.purple)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .disabled(editInstructions.isEmpty)
            }
            .padding()
            .navigationTitle("AI Recipe Editor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        .onDisappear {
            if voiceAssistant.isListening {
                voiceAssistant.stopListening()
            }
        }
    }
}

// MARK: - Example Button

struct ExampleButton: View {
    let text: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                Image(systemName: "lightbulb.fill")
                    .font(.caption2)
                Text(text)
                    .font(.caption)
            }
            .foregroundColor(.purple)
        }
    }
}

// MARK: - Preview

#Preview {
    AIEditSheet(
        currentRecipe: RecipeBase(
            title: "Chocolate Chip Cookies",
            description: nil,
            servings: 24,
            prepTime: 15,
            cookTime: 12,
            ingredients: ["2 cups flour", "1 cup butter"],
            instructions: ["Mix ingredients", "Bake at 350°F"],
            tags: [],
            sourceUrl: nil,
            cuisineType: nil,
            difficulty: nil
        ),
        onSubmit: { _ in }
    )
    .environmentObject(VoiceAssistant())
}
