//
//  WebScraperService.swift
//  little-chef
//
//  Scrapes recipe content from URLs using WKWebView for full JS rendering
//

import Foundation
import WebKit

/// Service for scraping recipe content from web URLs using WKWebView
@MainActor
class WebScraperService: NSObject {
    static let shared = WebScraperService()

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<String, Error>?
    private var timeoutTask: Task<Void, Never>?

    override private init() {
        super.init()
    }

    // MARK: - Public API

    /// Scrape recipe content from a URL. Loads the page in WKWebView to execute JavaScript,
    /// then extracts text content from the rendered DOM.
    func scrapeRecipe(from url: String) async throws -> String {
        guard let urlObj = URL(string: url) else {
            throw WebScraperError.invalidURL
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            // Create a fresh offscreen WKWebView
            let config = WKWebViewConfiguration()
            let wv = WKWebView(frame: .zero, configuration: config)
            wv.navigationDelegate = self
            self.webView = wv

            // Set a timeout
            self.timeoutTask = Task {
                try? await Task.sleep(nanoseconds: 15_000_000_000) // 15 seconds
                if self.continuation != nil {
                    self.finish(with: .failure(WebScraperError.fetchFailed))
                }
            }

            wv.load(URLRequest(url: urlObj))
        }
    }

    // MARK: - Private

    private func finish(with result: Result<String, Error>) {
        timeoutTask?.cancel()
        timeoutTask = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil

        if let cont = continuation {
            continuation = nil
            cont.resume(with: result)
        }
    }

    /// Extract content from the loaded page. Tries schema.org JSON-LD first, then body text.
    private func extractContent() {
        guard let wv = webView else {
            finish(with: .failure(WebScraperError.noContentFound))
            return
        }

        // First try to get JSON-LD recipe schema
        let schemaJS = """
        (function() {
            var scripts = document.querySelectorAll('script[type="application/ld+json"]');
            for (var i = 0; i < scripts.length; i++) {
                var text = scripts[i].textContent;
                if (text.indexOf('Recipe') !== -1) {
                    return 'SCHEMA_JSON:' + text;
                }
            }
            return null;
        })()
        """

        wv.evaluateJavaScript(schemaJS) { [weak self] result, _ in
            guard let self else { return }

            if let schemaText = result as? String, schemaText.hasPrefix("SCHEMA_JSON:") {
                let json = String(schemaText.dropFirst("SCHEMA_JSON:".count))
                self.finish(with: .success("Schema.org Recipe JSON:\n\(json)"))
                return
            }

            // Fall back to body text
            let bodyJS = "document.body.innerText"
            wv.evaluateJavaScript(bodyJS) { [weak self] result, error in
                guard let self else { return }

                if let error {
                    self.finish(with: .failure(error))
                    return
                }

                guard let text = result as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.finish(with: .failure(WebScraperError.noContentFound))
                    return
                }

                // Clean up excessive whitespace
                let cleaned = text
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")

                self.finish(with: .success(cleaned))
            }
        }
    }
}

// MARK: - WKNavigationDelegate

extension WebScraperService: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            // Brief delay to let JS-rendered content settle
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self.extractContent()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.finish(with: .failure(WebScraperError.fetchFailed))
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.finish(with: .failure(WebScraperError.fetchFailed))
        }
    }
}

// MARK: - Error Types

enum WebScraperError: LocalizedError {
    case invalidURL
    case fetchFailed
    case noContentFound

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL provided"
        case .fetchFailed:
            return "Failed to fetch webpage. Please check the URL and your internet connection."
        case .noContentFound:
            return "No recipe content found on the webpage"
        }
    }
}
