//
//  MainView.swift
//  little-chef
//
//  Created by Cedric Nagata on 9/5/25.
//

import SwiftUI

struct MainView: View {
    @EnvironmentObject var authManager: AuthManager
    
    var body: some View {
        TabView {
            // Recipes Tab
            RecipeListView()
                .tabItem {
                    Image(systemName: "book.fill")
                    Text("Recipes")
                }
            
            // Cooking Tab
            CookingView()
                .tabItem {
                    Image(systemName: "flame.fill")
                    Text("Cook")
                }
            
            // Profile Tab
            ProfileView()
                .tabItem {
                    Image(systemName: "person.fill")
                    Text("Profile")
                }
        }
        .accentColor(.orange)
    }
}

// MARK: - Temporary Placeholder Views

struct CookingView: View {
    var body: some View {
        NavigationStack {
            VStack {
                Image(systemName: "flame.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.orange)
                    .padding()
                
                Text("Start Cooking")
                    .font(.title)
                    .fontWeight(.bold)
                
                Text("Select a recipe to begin cooking with AI assistance")
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                
                Spacer()
            }
            .navigationTitle("Cook")
        }
    }
}

struct ProfileView: View {
    @EnvironmentObject var authManager: AuthManager
    @State private var showingDeleteAlert = false
    @State private var isDeleting = false
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                // User Info
                VStack(spacing: 16) {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 80))
                        .foregroundColor(.orange)
                    
                    if let user = authManager.currentUser {
                        Text(user.name)
                            .font(.title2)
                            .fontWeight(.semibold)
                        
                        Text(user.email)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.top, 20)
                
                // Settings Options
                VStack(spacing: 16) {
                    NavigationLink(destination: ProfileSettingsView()) {
                        SettingsOptionRow(
                            icon: "person.circle.fill",
                            title: "Profile Settings",
                            subtitle: "LLM model, preferences, dietary restrictions"
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                    
                    NavigationLink(destination: AccountSettingsView()) {
                        SettingsOptionRow(
                            icon: "gear.circle.fill",
                            title: "Account Settings", 
                            subtitle: "Email, name, password"
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                    
                    // Delete Account Button
                    Button(action: {
                        showingDeleteAlert = true
                    }) {
                        HStack {
                            if isDeleting {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .red))
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "trash.circle.fill")
                                    .font(.title2)
                                    .foregroundColor(.red)
                            }
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Delete Account")
                                    .foregroundColor(.red)
                                    .font(.body)
                                Text("Permanently delete your account and data")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                            }
                            
                            Spacer()
                            
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(12)
                    }
                    .disabled(isDeleting)
                }
                .padding(.horizontal)
                
                // Logout Button
                Button(action: {
                    Task {
                        await authManager.logout()
                    }
                }) {
                    HStack {
                        if authManager.isLoading {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.8)
                        }
                        Text("Sign Out")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.red)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .disabled(authManager.isLoading)
                .padding(.horizontal)
                .padding(.bottom, 32)
                }
            }
            .navigationTitle("Profile")
        }
        .alert("Delete Account", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                deleteAccount()
            }
        } message: {
            Text("Are you sure you want to permanently delete your account? This action cannot be undone and will delete all your recipes and data forever.")
        }
    }
    
    private func deleteAccount() {
        Task {
            isDeleting = true
            let success = await authManager.deleteAccount()
            isDeleting = false
            
            if !success {
                // Error handling is managed by AuthManager
                print("Failed to delete account")
            }
        }
    }
}

struct SettingsOptionRow: View {
    let icon: String
    let title: String
    let subtitle: String
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.orange)
                .frame(width: 30)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundColor(.primary)
                
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

#Preview {
    MainView()
        .environmentObject(AuthManager())
}
