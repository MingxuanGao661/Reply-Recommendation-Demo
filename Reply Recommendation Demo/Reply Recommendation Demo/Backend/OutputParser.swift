import Foundation

/// Parses raw LLM output into SuggestionOutput, tolerant of malformed JSON.
/// Mirrors the logic from Python schemas.py `from_raw_text()`.
enum OutputParser {

    /// Main entry: raw string → SuggestionOutput
    static func parse(raw: String) -> SuggestionOutput {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let startIdx = text.firstIndex(of: "{") else {
            return sanitizeOutput(SuggestionOutput(suggestions: [Suggestion(label: "Raw", text: text)]))
        }

        // Try closing braces from right to left (handles garbage tails)
        var searchEnd = text.endIndex
        while searchEnd > startIdx {
            guard let braceIdx = text[startIdx..<searchEnd].lastIndex(of: "}") else { break }
            let candidate = String(text[startIdx...braceIdx])

            if let output = tryParseJSON(candidate) {
                return sanitizeOutput(output)
            }
            searchEnd = braceIdx
        }

        // Last resort: regex extraction
        if let output = regexFallback(text) {
            return sanitizeOutput(output)
        }

        return sanitizeOutput(SuggestionOutput(suggestions: [Suggestion(label: "Raw", text: text)]))
    }

    /// Small models sometimes echo JSON into the `text` field; strip / re-extract so UI stays readable.
    private static func sanitizeOutput(_ output: SuggestionOutput) -> SuggestionOutput {
        SuggestionOutput(
            suggestions: output.suggestions.map { Suggestion(label: $0.label, text: sanitizeSuggestionText($0.text)) }
        )
    }

    private static func sanitizeSuggestionText(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Unwrap one or more nested JSON shells in `text`
        for _ in 0..<3 {
            guard t.contains("\"text\""), t.contains("\"label\"") || t.hasPrefix("{") else { break }
            if let body = decodeLooseSingleObjectJSON(t), body != t {
                t = body.trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            if let extracted = extractTextFieldFromJSONFragment(t), extracted != t {
                t = extracted.trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            break
        }
        // Truncated / invalid JSON object still sitting in `text` — try label/text regex pairs.
        if t.hasPrefix("{"), t.contains("\"label\""),
           let fallback = regexFallback(t),
           let first = fallback.suggestions.first?.text,
           !first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return first.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return t
    }

    private struct LooseSingleSuggestion: Decodable {
        let label: String?
        let text: String?
    }

    private static func decodeLooseSingleObjectJSON(_ s: String) -> String? {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONDecoder().decode(LooseSingleSuggestion.self, from: data),
              let text = obj.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        // Only accept if this looks like the model stuffed a whole JSON object into `text`
        if text.hasPrefix("{") && text.contains("\"label\"") { return nil }
        return text
    }

    /// Best-effort: read the value after `"text":` when the overall JSON is truncated / invalid.
    private static func extractTextFieldFromJSONFragment(_ s: String) -> String? {
        guard let range = s.range(of: "\"text\"") else { return nil }
        var i = range.upperBound
        while i < s.endIndex, s[i].isWhitespace { i = s.index(after: i) }
        guard i < s.endIndex, s[i] == ":" else { return nil }
        i = s.index(after: i)
        while i < s.endIndex, s[i].isWhitespace { i = s.index(after: i) }
        guard i < s.endIndex, s[i] == "\"" else { return nil }
        i = s.index(after: i)
        let start = i
        var escaped = false
        while i < s.endIndex {
            let ch = s[i]
            if escaped {
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "\"" {
                let inner = unescapeJSONString(String(s[start..<i]))
                if !inner.isEmpty { return inner }
                // Handles broken generations like `"text":"" Can you tell me more...` (prose after the string)
                let tail = s[s.index(after: i)...]
                let trimmedTail = String(tail).trimmingCharacters(in: .whitespacesAndNewlines)
                let prose = String(trimmedTail.drop(while: { $0 == "," || $0.isWhitespace }))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !prose.isEmpty, !prose.hasPrefix("{") { return prose }
                return nil
            }
            i = s.index(after: i)
        }
        return nil
    }

    private static func unescapeJSONString(_ s: String) -> String {
        s
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
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
