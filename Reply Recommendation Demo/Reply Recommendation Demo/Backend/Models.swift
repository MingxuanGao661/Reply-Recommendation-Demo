import Foundation

// MARK: - Input

struct Message: Codable {
    let speaker: String  // "me" or "other"
    let text: String
}

struct Profile: Codable {
    var tone: String = "warm"
    var length: String = "short"
    var style: String = "casual"

    init(tone: String = "warm", length: String = "short", style: String = "casual") {
        self.tone = tone
        self.length = length
        self.style = style
    }
}

struct ConversationInput: Codable {
    let conversation: [Message]
    let draft: String?
    let profile: Profile?

    var resolvedDraft: String {
        (draft ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var resolvedProfile: Profile {
        profile ?? Profile()
    }

    var hasDraft: Bool {
        !resolvedDraft.isEmpty
    }

    /// Parse from JSON string
    static func from(json: String) -> ConversationInput? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ConversationInput.self, from: data)
    }

    /// Parse from JSON Data
    static func from(data: Data) -> ConversationInput? {
        try? JSONDecoder().decode(ConversationInput.self, from: data)
    }
}

// MARK: - Output

struct Suggestion: Codable {
    let label: String
    let text: String
}

struct SuggestionOutput: Codable {
    let suggestions: [Suggestion]

    func toJSON(prettyPrint: Bool = true) -> String? {
        let encoder = JSONEncoder()
        if prettyPrint { encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes] }
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Metrics

struct InferenceMetrics {
    var modelName: String = ""
    var latencyMs: Double = 0
    var memoryBeforeMB: Double = 0
    var memoryAfterMB: Double = 0
    var memoryDeltaMB: Double = 0
    var tokensGenerated: Int = 0
    var tokensPerSec: Double = 0
    var promptTokens: Int = 0
    var totalTokens: Int = 0

    func toDict() -> [String: Any] {
        [
            "model_name": modelName,
            "latency_ms": latencyMs,
            "memory_before_mb": memoryBeforeMB,
            "memory_after_mb": memoryAfterMB,
            "memory_delta_mb": memoryDeltaMB,
            "tokens_generated": tokensGenerated,
            "tokens_per_sec": tokensPerSec,
            "prompt_tokens": promptTokens,
            "total_tokens": totalTokens,
        ]
    }

    var summary: String {
        var lines = [
            "Model:            \(modelName)",
            "Latency:          \(Int(latencyMs)) ms",
            "Memory delta:     \(String(format: "%+.1f", memoryDeltaMB)) MB",
        ]
        if tokensGenerated > 0 {
            lines.append("Tokens generated: \(tokensGenerated)")
            lines.append("Tokens/sec:       \(String(format: "%.1f", tokensPerSec))")
        }
        return lines.joined(separator: "\n")
    }
}
