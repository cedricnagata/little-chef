//
//  OCRService.swift
//  little-chef
//
//  Reads the text in recipe photos with Apple's Vision framework, on the device.
//

import Foundation
import ImageIO
import Vision
import UIKit

/// Service for extracting text from recipe images using OCR
class OCRService {
    static let shared = OCRService()

    private init() {}

    // MARK: - Public Methods

    /// Extract text from a single image
    func extractText(from image: UIImage) async throws -> String {
        guard let cgImage = image.cgImage else {
            throw OCRError.invalidImage
        }

        // The pixels of a photo taken upright are stored sideways, with the rotation kept beside
        // them. Read without it, a portrait photo of a recipe was recognized as a page lying on
        // its side, which finds little or nothing.
        let text = try await performOCR(on: cgImage, orientation: Self.orientation(of: image))

        guard !text.isEmpty else {
            throw OCRError.noTextFound
        }

        return text
    }

    private static func orientation(of image: UIImage) -> CGImagePropertyOrientation {
        switch image.imageOrientation {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }

    /// Extract text from multiple images and combine
    func extractText(from images: [UIImage]) async throws -> String {
        guard !images.isEmpty else {
            throw OCRError.noImagesProvided
        }

        var extractedTexts: [String] = []

        for (index, image) in images.enumerated() {
            do {
                let text = try await extractText(from: image)
                extractedTexts.append("--- Image \(index + 1) ---\n\(text)")
            } catch {
                // Continue with other images if one fails
                dprint("Failed to extract text from image \(index + 1): \(error)")
            }
        }

        guard !extractedTexts.isEmpty else {
            throw OCRError.noTextFound
        }

        return extractedTexts.joined(separator: "\n\n")
    }

    // MARK: - Private Methods

    /// Off the main thread: recognition takes seconds, and this is called from main-actor code.
    /// The results are read after `perform` returns rather than in a completion handler, so a
    /// failure reported both ways can't resume a continuation twice.
    private func performOCR(on cgImage: CGImage, orientation: CGImagePropertyOrientation) async throws -> String {
        try await Task.detached(priority: .userInitiated) { () throws -> String in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = true
            request.minimumTextHeight = 0.02

            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
            try handler.perform([request])
            return (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
        }.value
    }
}

// MARK: - Error Types

enum OCRError: LocalizedError {
    case invalidImage
    case noImagesProvided
    case noTextFound

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "Invalid or corrupted image"
        case .noImagesProvided:
            return "No images provided for text extraction"
        case .noTextFound:
            return "No text found in the image(s). Please ensure the image contains readable text."
        }
    }
}
