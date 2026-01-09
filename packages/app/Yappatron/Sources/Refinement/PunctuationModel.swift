import Foundation

/// Lightweight text-to-text refinement model
/// Phase 1: Rule-based punctuation and capitalization
/// Phase 2: ML model integration
actor PunctuationModel {

    enum ModelType {
        case rules          // Simple rule-based (Phase 1)
        case mlModel        // CoreML model (Phase 2)
    }

    private let modelType: ModelType

    init(modelType: ModelType = .rules) {
        self.modelType = modelType
    }

    /// Refine text with punctuation and capitalization
    func refine(_ text: String, context: String = "") async -> String {
        switch modelType {
        case .rules:
            return applyRules(text, context: context)
        case .mlModel:
            // TODO: Phase 2 - integrate ML model
            return applyRules(text, context: context)
        }
    }

    /// Simple rule-based refinement (Phase 1)
    private func applyRules(_ text: String, context: String) -> String {
        var result = text.trimmingCharacters(in: .whitespaces)

        // Capitalize first letter
        if let first = result.first {
            result = first.uppercased() + result.dropFirst()
        }

        // Add period at end if missing and looks like sentence end
        if !result.isEmpty && ![".", "!", "?", ","].contains(where: { result.hasSuffix(String($0)) }) {
            // Simple heuristic: if text is longer than 3 words, likely a sentence
            let wordCount = result.split(separator: " ").count
            if wordCount >= 3 {
                result += "."
            }
        }

        // Capitalize after sentence boundaries
        let sentenceEnders: Set<Character> = [".", "!", "?"]
        var chars = Array(result)
        var capitalizeNext = false

        for i in 0..<chars.count {
            if capitalizeNext && chars[i].isLetter {
                chars[i] = Character(chars[i].uppercased())
                capitalizeNext = false
            }
            if sentenceEnders.contains(chars[i]) {
                capitalizeNext = true
            }
        }

        return String(chars)
    }
}
