//
//  ModelPreparationView.swift
//  little-chef
//
//  The getting-ready screen: shown while a task waits for the model it needs.
//

import SwiftUI

/// Covers the screen while ``LLMService/preparation`` is set for `purpose`: what's happening, a
/// progress bar where there is a fraction to show and a spinner where there isn't, and Cancel.
///
/// An overlay rather than a sheet or a full-screen cover: it appears as a chooser sheet is
/// closing (Choose Recipe) and over a sheet that is open (Add Recipe), and presenting from
/// either moment fails or waits. Each screen that starts a model task applies it.
struct ModelPreparationOverlay: ViewModifier {
    @EnvironmentObject var llmService: LLMService
    let purpose: ModelPreparation.Purpose

    func body(content: Content) -> some View {
        content.overlay {
            if let preparation = llmService.preparation, preparation.purpose == purpose {
                ModelPreparationView(preparation: preparation, title: title) {
                    llmService.cancelPreparation()
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: llmService.preparation?.id)
    }

    private var title: String {
        switch purpose {
        case .cooking: return "Getting Your Cook Ready"
        case .recipeImport: return "Getting the AI Ready"
        }
    }
}

struct ModelPreparationView: View {
    let preparation: ModelPreparation
    let title: String
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text(title)
                .font(.title2.weight(.semibold))
            VStack(spacing: 10) {
                if let progress = preparation.progress {
                    ProgressView(value: progress)
                        .frame(maxWidth: 260)
                } else {
                    ProgressView()
                        .controlSize(.large)
                }
                Text(preparation.step)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text("This only happens when the AI is needed, and it's put away again afterwards.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
            Button("Cancel", role: .cancel, action: onCancel)
                .buttonStyle(.bordered)
                .controlSize(.large)
                .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
    }
}

extension View {
    /// The getting-ready screen for model tasks started from this screen.
    func modelPreparationOverlay(_ purpose: ModelPreparation.Purpose) -> some View {
        modifier(ModelPreparationOverlay(purpose: purpose))
    }
}
