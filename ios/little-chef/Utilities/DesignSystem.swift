//
//  DesignSystem.swift
//  little-chef
//
//  Centralized design system for consistent UI/UX
//

import SwiftUI

// MARK: - Design System

enum DesignSystem {

    // MARK: - Spacing
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: - Corner Radius
    enum CornerRadius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
    }

    // MARK: - Colors
    enum Colors {
        static let primary = Color.orange
        static let primaryLight = Color.orange.opacity(0.1)
        static let primaryMedium = Color.orange.opacity(0.15)

        static let success = Color.green
        static let successLight = Color.green.opacity(0.2)

        static let error = Color.red

        static let textPrimary = Color.primary
        static let textSecondary = Color.secondary

        static let background = Color(.systemBackground)
        static let backgroundSecondary = Color(.systemGray6)
        static let backgroundTertiary = Color(.systemGray5)
    }
}

// MARK: - Typography Extensions

extension View {
    /// Section header style: semibold headline
    func sectionHeader() -> some View {
        self
            .font(.headline)
            .fontWeight(.semibold)
    }

    /// Card title style: body weight semibold
    func cardTitle() -> some View {
        self
            .font(.body)
            .fontWeight(.semibold)
    }

    /// Body text style: regular body text
    func bodyText() -> some View {
        self
            .font(.body)
    }

    /// Caption style: small secondary text
    func captionText() -> some View {
        self
            .font(.caption)
            .foregroundColor(DesignSystem.Colors.textSecondary)
    }
}

// MARK: - Component Styles

extension View {
    /// Standard card background
    func cardBackground() -> some View {
        self
            .background(DesignSystem.Colors.backgroundSecondary)
            .cornerRadius(DesignSystem.CornerRadius.medium)
    }

    /// Primary action button style
    func primaryButton() -> some View {
        self
            .padding(DesignSystem.Spacing.md)
            .background(DesignSystem.Colors.primary)
            .foregroundColor(.white)
            .cornerRadius(DesignSystem.CornerRadius.small)
    }

    /// Secondary action button style
    func secondaryButton() -> some View {
        self
            .padding(DesignSystem.Spacing.md)
            .background(DesignSystem.Colors.backgroundSecondary)
            .foregroundColor(DesignSystem.Colors.primary)
            .cornerRadius(DesignSystem.CornerRadius.small)
    }
}
