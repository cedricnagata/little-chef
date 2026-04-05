//
//  ChatAreaView.swift
//  little-chef
//

import SwiftUI

struct ChatAreaView: View {
    @EnvironmentObject var cookingSessionManager: CookingSessionManager

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if cookingSessionManager.getConversationHistory().isEmpty {
                        WelcomeMessageView()
                    } else {
                        ForEach(cookingSessionManager.getConversationHistory()) { message in
                            MessageBubbleView(message: message)
                                .id(message.id)
                        }
                    }

                    if cookingSessionManager.isLoading {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Thinking...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                    }
                }
                .padding()
            }
            .onChange(of: cookingSessionManager.getConversationHistory().count) {
                if let lastMessage = cookingSessionManager.getConversationHistory().last {
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

// MARK: - Welcome Message

private struct WelcomeMessageView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image("littlechef")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 60, height: 60)

            Text("LittleChef is Ready!")
                .font(.headline)
                .fontWeight(.semibold)

            Text("Ask me anything about cooking this recipe! You can ask about ingredients, techniques, timing, or substitutions.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding(.vertical, 40)
    }
}

// MARK: - Message Bubble

struct MessageBubbleView: View {
    let message: Message

    var body: some View {
        HStack {
            if message.role == "user" {
                Spacer(minLength: 60)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(message.content)
                        .padding(12)
                        .background(Color.orange)
                        .foregroundColor(.white)
                        .cornerRadius(16)

                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(message.content)
                        .padding(12)
                        .background(Color(.systemGray5))
                        .foregroundColor(.primary)
                        .cornerRadius(16)

                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 60)
            }
        }
    }
}
