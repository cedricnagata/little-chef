//
//  ModelLoadingOverlay.swift
//  little-chef
//

import SwiftUI

struct ModelLoadingOverlay: View {
    @EnvironmentObject var llmService: LLMService

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()

            VStack(spacing: 28) {
                // Animated icon
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.orange)
                    .symbolEffect(.pulse, options: .repeating)

                VStack(spacing: 12) {
                    Text(statusText)
                        .font(.headline)

                    Text("Bonsai 8B")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // Progress bar
                VStack(spacing: 8) {
                    ProgressView(value: llmService.loadProgress, total: 1.0)
                        .progressViewStyle(.linear)
                        .tint(.orange)

                    Text(progressText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 8)
            }
            .padding(32)
            .frame(width: 280)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 20, y: 10)
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.25), value: llmService.isLoadingModel)
    }

    private var statusText: String {
        if llmService.loadProgress > 0 && llmService.loadProgress < 1.0 {
            return "Downloading Model..."
        } else {
            return "Loading Model..."
        }
    }

    private var progressText: String {
        if llmService.loadProgress > 0 {
            return "\(Int(llmService.loadProgress * 100))%"
        } else {
            return "Preparing..."
        }
    }
}
