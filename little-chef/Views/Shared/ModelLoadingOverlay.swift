//
//  ModelLoadingOverlay.swift
//  little-chef
//
//  Loading overlay displayed when LLM models are downloading
//

import SwiftUI

struct ModelLoadingOverlay: View {
    let modelName: String
    let progress: Double

    var body: some View {
        ZStack {
            Color.black.opacity(0.7)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                ProgressView(value: progress, total: 1.0)
                    .progressViewStyle(CircularProgressViewStyle(tint: .orange))
                    .scaleEffect(1.5)

                VStack(spacing: 8) {
                    Text("Loading \(modelName)")
                        .font(.headline)
                        .foregroundColor(.white)

                    if progress > 0 {
                        Text("\(Int(progress * 100))%")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.8))
                    } else {
                        Text("Preparing...")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
            }
            .padding(32)
            .background(Color(.systemBackground))
            .cornerRadius(16)
            .shadow(radius: 10)
        }
    }
}
