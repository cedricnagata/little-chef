//
//  SettingsView.swift
//  little-chef
//
//  Created by Cedric Nagata on 9/5/25.
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var authManager: AuthManager
    @State private var showingDeleteAlert = false
    @State private var isDeleting = false
    
    var body: some View {
        List {
            // Profile Settings Section
            Section {
                NavigationLink(destination: ProfileSettingsView()) {
                    SettingsRowView(
                        icon: "person.circle.fill",
                        title: "Profile Settings",
                        subtitle: "LLM model, preferences, dietary restrictions"
                    )
                }
                
                NavigationLink(destination: AccountSettingsView()) {
                    SettingsRowView(
                        icon: "gear.circle.fill",
                        title: "Account Settings", 
                        subtitle: "Email, name, password"
                    )
                }
            } header: {
                Text("Settings")
            }
            
            // Danger Zone Section
            Section {
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
                        
                        VStack(alignment: .leading) {
                            Text("Delete Account")
                                .foregroundColor(.red)
                                .font(.body)
                            Text("Permanently delete your account and data")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                        
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                .disabled(isDeleting)
            } header: {
                Text("Danger Zone")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .alert("Delete Account", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                deleteAccount()
            }
        } message: {
            Text("Are you sure you want to permanently delete your account? This action cannot be undone and will delete all your recipes and data.")
        }
    }
    
    private func deleteAccount() {
        isDeleting = true
        
        // TODO: Implement API call to delete account
        // For now, just simulate deletion and logout
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            isDeleting = false
            
            // In a real implementation, this would call the backend API
            // to permanently delete the user's account and all associated data
            Task {
                await authManager.logout()
            }
        }
    }
}

struct SettingsRowView: View {
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
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .environmentObject(AuthManager())
    }
}
