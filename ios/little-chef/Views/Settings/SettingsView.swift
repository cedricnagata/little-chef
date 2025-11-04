//
//  SettingsView.swift
//  little-chef
//
//  Simplified for local-only operation
//

import SwiftUI

struct SettingsView: View {
    @State private var showingDeleteDataAlert = false
    @State private var isDeleting = false

    var body: some View {
        List {
            // Profile Settings Section
            Section {
                NavigationLink(destination: ProfileSettingsView()) {
                    SettingsRowView(
                        icon: "person.circle.fill",
                        title: "Preferences",
                        subtitle: "Measurement system, dietary restrictions, voice settings"
                    )
                }

                NavigationLink(destination: ModelManagementView()) {
                    SettingsRowView(
                        icon: "cpu",
                        title: "Model Management",
                        subtitle: "Manage local AI model"
                    )
                }
            } header: {
                Text("Settings")
            }

            // Data Management Section
            Section {
                Button(action: {
                    showingDeleteDataAlert = true
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
                            Text("Delete All Data")
                                .foregroundColor(.red)
                                .font(.body)
                            Text("Permanently delete all recipes and settings")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }

                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                .disabled(isDeleting)
            } header: {
                Text("Data Management")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .alert("Delete All Data", isPresented: $showingDeleteDataAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                deleteAllData()
            }
        } message: {
            Text("Are you sure you want to permanently delete all your recipes and settings? This action cannot be undone.")
        }
    }

    private func deleteAllData() {
        isDeleting = true

        Task {
            do {
                let dataManager = try LocalDataManager()
                try dataManager.deleteAllRecipes()
                try dataManager.resetPreferences()

                await MainActor.run {
                    isDeleting = false
                }
            } catch {
                print("Failed to delete data: \(error)")
                await MainActor.run {
                    isDeleting = false
                }
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
    }
}
