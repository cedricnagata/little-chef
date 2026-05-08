//
//  OCRService.swift
//  little-chef
//
//  Extracts text from images using Apple Vision framework
//  Replaces GPT-4 Vision API
//

import Foundation
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

        let text = try await performOCR(on: cgImage)

        guard !text.isEmpty else {
            throw OCRError.noTextFound
        }

        return text
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

    private func performOCR(on cgImage: CGImage) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: "")
                    return
                }

                // Extract text from observations
                let recognizedText = observations.compactMap { observation in
                    observation.topCandidates(1).first?.string
                }.joined(separator: "\n")

                continuation.resume(returning: recognizedText)
            }

            // Configure OCR request
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = true

            // Minimum text height for better accuracy (0.0 to 1.0)
            request.minimumTextHeight = 0.02

            // Perform the request
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }


}

// MARK: - Error Types

enum OCRError: LocalizedError {
    case invalidImage
    case noImagesProvided
    case noTextFound
    case processingFailed(Error)

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "Invalid or corrupted image"
        case .noImagesProvided:
            return "No images provided for text extraction"
        case .noTextFound:
            return "No text found in the image(s). Please ensure the image contains readable text."
        case .processingFailed(let error):
            return "OCR processing failed: \(error.localizedDescription)"
        }
    }
}
