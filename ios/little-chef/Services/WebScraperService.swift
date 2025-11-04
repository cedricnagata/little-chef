//
//  WebScraperService.swift
//  little-chef
//
//  Scrapes recipe content from URLs using SwiftSoup
//  Replaces Firecrawl API
//

import Foundation
import SwiftSoup

/// Service for scraping recipe content from web URLs
class WebScraperService {
    static let shared = WebScraperService()

    private init() {}

    // MARK: - Public Methods

    /// Scrape recipe content from a URL
    func scrapeRecipe(from url: String) async throws -> String {
        guard let urlObj = URL(string: url) else {
            throw WebScraperError.invalidURL
        }

        // Fetch HTML content
        let html = try await fetchHTML(from: urlObj)

        // Parse and extract main content
        let content = try extractMainContent(from: html)

        return content
    }

    // MARK: - Private Methods

    private func fetchHTML(from url: URL) async throws -> String {
        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw WebScraperError.fetchFailed
        }

        guard let html = String(data: data, encoding: .utf8) else {
            throw WebScraperError.decodingFailed
        }

        return html
    }

    private func extractMainContent(from html: String) throws -> String {
        let document = try SwiftSoup.parse(html)

        // Try multiple strategies to extract recipe content

        // Strategy 1: Look for recipe schema markup (structured data)
        if let schemaContent = try? extractFromSchema(document) {
            return schemaContent
        }

        // Strategy 2: Look for common recipe containers
        if let recipeContent = try? extractFromRecipeContainer(document) {
            return recipeContent
        }

        // Strategy 3: Look for article or main content
        if let mainContent = try? extractFromMainContent(document) {
            return mainContent
        }

        // Strategy 4: Fall back to body text (less reliable)
        return try extractBodyText(document)
    }

    // MARK: - Extraction Strategies

    private func extractFromSchema(_ document: Document) throws -> String? {
        // Look for JSON-LD schema markup
        let scripts = try document.select("script[type='application/ld+json']")

        for script in scripts {
            let jsonText = try script.html()

            // Check if it's a Recipe schema
            if jsonText.contains("\"@type\"") && (jsonText.contains("Recipe") || jsonText.contains("recipe")) {
                // Return the JSON as-is for the LLM to parse
                return "Schema.org Recipe JSON:\n\(jsonText)"
            }
        }

        return nil
    }

    private func extractFromRecipeContainer(_ document: Document) throws -> String? {
        // Common recipe container selectors
        let selectors = [
            "[class*='recipe']",
            "[id*='recipe']",
            "[itemtype*='Recipe']",
            ".recipe-content",
            ".recipe-container",
            "#recipe",
            "article.recipe"
        ]

        for selector in selectors {
            if let element = try? document.select(selector).first() {
                // Extract text from this container
                let text = try cleanText(element.text())
                if !text.isEmpty && text.count > 100 {
                    return text
                }
            }
        }

        return nil
    }

    private func extractFromMainContent(_ document: Document) throws -> String? {
        // Look for main content containers
        let selectors = [
            "main",
            "article",
            "[role='main']",
            ".main-content",
            "#main-content",
            ".content",
            "#content"
        ]

        for selector in selectors {
            if let element = try? document.select(selector).first() {
                let text = try cleanText(element.text())
                if !text.isEmpty && text.count > 100 {
                    return text
                }
            }
        }

        return nil
    }

    private func extractBodyText(_ document: Document) throws -> String {
        // Remove script, style, and nav elements
        try document.select("script, style, nav, header, footer, aside, iframe").remove()

        // Get body text
        guard let body = document.body() else {
            throw WebScraperError.noContentFound
        }

        let text = try cleanText(body.text())

        guard !text.isEmpty else {
            throw WebScraperError.noContentFound
        }

        return text
    }

    // MARK: - Text Cleaning

    private func cleanText(_ text: String) throws -> String {
        // Remove excessive whitespace
        var cleaned = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        // Remove common noise patterns
        cleaned = cleaned.replacingOccurrences(of: "\\[.*?\\]", with: "", options: .regularExpression)

        // Trim whitespace
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned
    }
}

// MARK: - Error Types

enum WebScraperError: LocalizedError {
    case invalidURL
    case fetchFailed
    case decodingFailed
    case noContentFound

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL provided"
        case .fetchFailed:
            return "Failed to fetch webpage. Please check the URL and your internet connection."
        case .decodingFailed:
            return "Failed to decode webpage content"
        case .noContentFound:
            return "No recipe content found on the webpage"
        }
    }
}
