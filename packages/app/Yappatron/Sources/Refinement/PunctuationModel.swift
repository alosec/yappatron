import Foundation

/// Text-to-text refinement using local LLM via Ollama
/// Adds punctuation, fixes errors, proper capitalization
actor PunctuationModel {

    private let systemPrompt = """
You are a text refinement assistant. Your job is to take unpunctuated, potentially error-filled transcribed speech and output properly formatted text with correct punctuation, capitalization, and minor error corrections.

Rules:
- Add appropriate punctuation (periods, commas, question marks, exclamation points)
- Capitalize properly (sentences, proper nouns, I)
- Fix obvious transcription errors (common homophones, typos)
- Preserve the original meaning and words as much as possible
- Do NOT add words that weren't there
- Do NOT change the tone or style significantly
- Output ONLY the refined text, no explanations

Examples:
Input: "hey whats up how are you doing today"
Output: "Hey, what's up? How are you doing today?"

Input: "i think we should go to the store and get some milk bread and eggs"
Output: "I think we should go to the store and get some milk, bread, and eggs."

Input: "can you believe what happened yesterday it was crazy"
Output: "Can you believe what happened yesterday? It was crazy!"
"""

    private var ollamaAvailable: Bool?

    /// Refine text with punctuation and error correction using Ollama
    func refine(_ text: String, context: String = "") async -> String {
        // Try Ollama
        if let refined = await callOllama(text: text, context: context) {
            return refined
        }

        // Fallback to enhanced rule-based approach
        return enhancedRuleBasedRefine(text)
    }

    /// Call Ollama API for text refinement
    private func callOllama(text: String, context: String) async -> String? {
        // Check cache
        if let available = ollamaAvailable, !available {
            return nil
        }

        do {
            let url = URL(string: "http://localhost:11434/api/generate")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 5.0  // Quick timeout for responsiveness

            // Build prompt
            let prompt: String
            if !context.isEmpty {
                prompt = "\(systemPrompt)\n\nPrevious text: \"\(context)\"\nCurrent text to refine: \"\(text)\"\n\nOutput only the refined current text:"
            } else {
                prompt = "\(systemPrompt)\n\nText to refine: \"\(text)\"\n\nRefined text:"
            }

            let body: [String: Any] = [
                "model": "phi3:mini",
                "prompt": prompt,
                "stream": false,
                "options": [
                    "temperature": 0.3,      // Low temperature for consistency
                    "num_predict": 150,      // Limit output length
                    "top_k": 40,
                    "top_p": 0.9
                ]
            ]

            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                ollamaAvailable = false
                log("[PunctuationModel] Ollama not available")
                return nil
            }

            ollamaAvailable = true

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let refinedRaw = (json?["response"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Clean up the response (sometimes LLMs add quotes or extra text)
            let refined = cleanLLMResponse(refinedRaw, original: text)

            guard !refined.isEmpty else {
                log("[PunctuationModel] Empty response from Ollama")
                return nil
            }

            log("[PunctuationModel] Ollama refined: '\(text)' → '\(refined)'")
            return refined

        } catch {
            ollamaAvailable = false
            log("[PunctuationModel] Ollama error: \(error.localizedDescription)")
            return nil
        }
    }

    /// Clean up LLM response (remove quotes, extra explanations, etc.)
    private func cleanLLMResponse(_ response: String, original: String) -> String {
        var cleaned = response

        // Remove common wrapper patterns
        if cleaned.hasPrefix("\"") && cleaned.hasSuffix("\"") {
            cleaned = String(cleaned.dropFirst().dropLast())
        }

        // If response contains newlines, take only the first line
        if let firstLine = cleaned.split(separator: "\n").first {
            cleaned = String(firstLine).trimmingCharacters(in: .whitespaces)
        }

        // If the response is way longer than input, it might have added explanations
        // Take only the part that looks like refined text
        if cleaned.count > original.count * 2 {
            // Look for patterns like "Refined text: ..." or "Output: ..."
            let patterns = ["refined text:", "output:", "result:"]
            for pattern in patterns {
                if let range = cleaned.lowercased().range(of: pattern) {
                    cleaned = String(cleaned[range.upperBound...])
                        .trimmingCharacters(in: .whitespaces)
                    break
                }
            }

            // If still too long, truncate
            if cleaned.count > original.count * 2 {
                cleaned = enhancedRuleBasedRefine(original)
            }
        }

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Enhanced rule-based refinement (fallback when Ollama unavailable)
    private func enhancedRuleBasedRefine(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return result }

        // Capitalize first letter
        result = result.prefix(1).uppercased() + result.dropFirst()

        // Capitalize " i " to " I "
        result = result.replacingOccurrences(of: " i ", with: " I ")
        result = result.replacingOccurrences(of: " i'", with: " I'")

        // Start of sentence
        if result.hasPrefix("i ") {
            result = "I" + result.dropFirst()
        }

        // Fix common contractions
        let contractions: [(String, String)] = [
            (" dont ", " don't "), (" cant ", " can't "), (" wont ", " won't "),
            (" isnt ", " isn't "), (" arent ", " aren't "), (" wasnt ", " wasn't "),
            (" werent ", " weren't "), (" hasnt ", " hasn't "), (" havent ", " haven't "),
            (" didnt ", " didn't "), (" doesnt ", " doesn't "), (" wouldnt ", " wouldn't "),
            (" couldnt ", " couldn't "), (" shouldnt ", " shouldn't "),
            (" im ", " I'm "), (" youre ", " you're "), (" theyre ", " they're "),
            (" were ", " we're "), (" hes ", " he's "), (" shes ", " she's "),
            (" its ", " it's "), (" thats ", " that's "), (" whats ", " what's "),
            (" hows ", " how's "), (" wheres ", " where's "), (" theres ", " there's ")
        ]

        for (wrong, right) in contractions {
            result = result.replacingOccurrences(of: wrong, with: right, options: .caseInsensitive)
        }

        // Add period at end if no punctuation
        let endsWithPunctuation = result.last.map { "!.?".contains($0) } ?? false
        if !endsWithPunctuation {
            // Check if it looks like a question
            let questionWords = ["what", "where", "when", "why", "how", "who", "which", "whose", "whom", "are", "is", "can", "could", "would", "should", "do", "does", "did"]
            let firstWord = result.split(separator: " ").first?.lowercased()

            if let first = firstWord, questionWords.contains(String(first)) {
                result += "?"
            } else {
                result += "."
            }
        }

        log("[PunctuationModel] Rule-based fallback: '\(text)' → '\(result)'")
        return result
    }
}
