//
//  LoginView.swift
//  little-chef
//
//  Created by Cedric Nagata on 9/5/25.
//

import SwiftUI

struct LoginView: View {
    @EnvironmentObject var authManager: AuthManager
    @State private var email = ""
    @State private var password = ""
    @State private var showingRegister = false
    @FocusState private var focusedField: Field?
    
    enum Field {
        case email, password
    }
    
    var body: some View {
        VStack(spacing: 24) {
                // App Logo and Title
                VStack(spacing: 16) {
                    Image("littlechef")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 80, height: 80)
                    
                    Text("LittleChef")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    
                    Text("Your cooking companion")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 40)
                
                Spacer()
                
                // Login Form
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Email")
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        TextField("Enter your email", text: $email)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.emailAddress)
                            .focused($focusedField, equals: .email)
                            .onSubmit {
                                focusedField = .password
                            }
                            .onChange(of: email) { _ in
                                authManager.clearError()
                            }
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Password")
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        SecureField("Enter your password", text: $password)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .textContentType(.none)
                            .focused($focusedField, equals: .password)
                            .onSubmit {
                                Task {
                                    await handleLogin()
                                }
                            }
                            .onChange(of: password) { _ in
                                authManager.clearError()
                            }
                    }
                    
                    // Error Message
                    if let errorMessage = authManager.errorMessage {
                        HStack {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundColor(.red)
                            Text(errorMessage)
                                .foregroundColor(.red)
                                .font(.subheadline)
                        }
                        .padding()
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(8)
                        .multilineTextAlignment(.center)
                    }
                    
                    // Login Button
                    Button(action: {
                        Task {
                            await handleLogin()
                        }
                    }) {
                        HStack {
                            if authManager.isLoading {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(0.8)
                            }
                            Text("Sign In")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.orange)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                    .disabled(email.isEmpty || password.isEmpty || authManager.isLoading)
                    .opacity(email.isEmpty || password.isEmpty ? 0.6 : 1.0)
                }
                .padding(.horizontal, 32)
                
                Spacer()
                
                // Register Link
                VStack(spacing: 12) {
                    Divider()
                    
                    Button("Don't have an account? Sign Up") {
                        authManager.clearError()
                        showingRegister = true
                    }
                    .foregroundColor(.orange)
                    .font(.subheadline)
                }
                .padding(.bottom, 32)
        }
        .onTapGesture {
            focusedField = nil
        }
        .sheet(isPresented: $showingRegister) {
            RegisterView()
        }
        .onChange(of: authManager.isAuthenticated) { isAuthenticated in
            if isAuthenticated {
                // Clear form on successful login
                email = ""
                password = ""
                authManager.clearError()
            }
        }
    }
    
    private func handleLogin() async {
        guard !email.isEmpty, !password.isEmpty else { return }
        
        focusedField = nil
        await authManager.login(email: email, password: password)
    }
}

#Preview {
    LoginView()
        .environmentObject(AuthManager())
}
