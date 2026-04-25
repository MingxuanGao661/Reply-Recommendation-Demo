import Foundation

/// Parses raw LLM output into SuggestionOutput, tolerant of malformed JSON.
/// Mirrors the logic from Python schemas.py `from_raw_text()`.
enum OutputParser {

    /// Main entry: raw string → SuggestionOutput
    static func parse(raw: String) -> SuggestionOutput {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let startIdx = text.firstIndex(of: "{") else {
            return SuggestionOutput(suggestions: [Suggestion(label: "Raw", text: text)])
        }

        // Try closing braces from right to left (handles garbage tails)
        var searchEnd = text.endIndex
        while searchEnd > startIdx {
            guard let braceIdx = text[startIdx..<searchEnd].lastIndex(of: "}") else { break }
            let candidate = String(text[startIdx...braceIdx])

            if let output = tryParseJSON(candidate) {
                return output
            }
            searchEnd = braceIdx
        }

        // Last resort: regex extraction
        if let output = regexFallback(text) {
            return output
        }

        return SuggestionOutput(suggestions: [Suggestion(label: "Raw", text: text)])
    }

    // MARK: - JSON Parsing

    private static func tryParseJSON(_ jsonString: String) -> SuggestionOutput? {
        guard let data = jsonString.data(using: .utf8) else { return nil }

        // Try standard format: {"suggestions": [{"label": ..., "text": ...}]}
        if let wrapper = try? JSONDecoder().decode(SuggestionOutput.self, from: data) {
            if !wrapper.suggestions.isEmpty { return wrapper }
        }

        // Try as raw dict/array
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return parseSuggestions(from: json)
    }

    /// Handles various model output formats (mirrors Python _parse_suggestions)
    private static func parseSuggestions(from dict: [String: Any]) -> SuggestionOutput? {
        // Format 0: single object {"label": "Natural", "text": "..."}
        if let text = dict["text"] as? String {
            let label = dict["label"] as? String ?? "Option"
            return SuggestionOutput(suggestions: [Suggestion(label: label, text: text)])
        }

        let raw = dict["suggestions"] ?? dict

        // Format A: array of objects
        if let array = raw as? [[String: Any]] {
            let suggestions = array.compactMap { item -> Suggestion? in
                if let text = item["text"] as? String {
                    let label = item["label"] as? String ?? "Option"
                    return Suggestion(label: label, text: text)
                }
                if let first = item.first {
                    return Suggestion(label: first.key, text: "\(first.value)")
                }
                return nil
            }
            if !suggestions.isEmpty {
                return SuggestionOutput(suggestions: suggestions)
            }
        }

        // Format B: array of strings
        if let array = raw as? [String] {
            let suggestions = array.enumerated().map { i, text in
                Suggestion(label: "Option \(i + 1)", text: text)
            }
            if !suggestions.isEmpty {
                return SuggestionOutput(suggestions: suggestions)
            }
        }

        // Format C: {"Natural": "...", "Polite": "...", "Like You": "..."}
        if let rawDict = raw as? [String: String] {
            if let text = rawDict["text"] {
                let label = rawDict["label"] ?? "Option"
                return SuggestionOutput(suggestions: [Suggestion(label: label, text: text)])
            }

            let suggestions = rawDict.map { Suggestion(label: $0.key, text: $0.value) }
            if !suggestions.isEmpty {
                return SuggestionOutput(suggestions: suggestions)
            }
        }

        return nil
    }

    // MARK: - Regex Fallback

    private static func regexFallback(_ text: String) -> SuggestionOutput? {
        let pattern = #""label"\s*:\s*"([^"]+)"\s*,\s*"text"\s*:\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        let suggestions = matches.map { match in
            let label = nsText.substring(with: match.range(at: 1))
            let textVal = nsText.substring(with: match.range(at: 2))
            return Suggestion(label: label, text: textVal)
        }

        return suggestions.isEmpty ? nil : SuggestionOutput(suggestions: suggestions)
    }
}
