import Foundation
import QuartzCore

/// Cloud LLM inference via OpenAI-compatible APIs.
/// Supports OpenAI, Gemini, Groq, OpenRouter (all use the same chat completions endpoint).
/// Input/output are JSON strings — same format as LLMService.
final class CloudService {

    // MARK: - Provider Presets

    struct ProviderPreset {
        let baseURL: String
        let defaultModel: String
    }

    /// Trims whitespace; for Anthropic, strips accidental `Bearer ` (header pasted into the key field).
    private static func normalizedAPIKey(_ raw: String, provider: String) -> String {
        var key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider == "anthropic", key.lowercased().hasPrefix("bearer ") {
            key = String(key.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return key
    }

    static let providers: [String: ProviderPreset] = [
        "openai": ProviderPreset(
            baseURL: "https://api.openai.com/v1",
            defaultModel: "gpt-5.4-nano"
        ),
        "anthropic": ProviderPreset(
            baseURL: "https://api.anthropic.com/v1",
            defaultModel: "claude-sonnet-4-6"
        ),
        "gemini": ProviderPreset(
            baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
            defaultModel: "gemini-3-flash-preview"
        ),
        "groq": ProviderPreset(
            baseURL: "https://api.groq.com/openai/v1",
            defaultModel: "llama-3.3-70b-versatile"
        ),
        "openrouter": ProviderPreset(
            baseURL: "https://openrouter.ai/api/v1",
            defaultModel: "anthropic/claude-sonnet-4-6"
        ),
    ]

    // MARK: - Properties

    private let apiKey: String
    private let baseURL: String
    private let model: String
    private let provider: String
    private let isAnthropic: Bool
    let modelName: String

    /// User-level defaults per axis. Merged in parallel with `conversation_profile`.
    var defaultProfile: Profile?

    // MARK: - Init

    /// Initialize a cloud inference service.
    /// - Parameters:
    ///   - apiKey: API key for the provider
    ///   - provider: One of "openai", "anthropic", "gemini", "groq", "openrouter"
    ///   - model: Specific model name (nil = use provider's default)
    ///   - defaultProfile: User-level defaults; fills any axis missing from `conversation_profile`
    init(
        apiKey: String,
        provider: String = "openai",
        model: String? = nil,
        defaultProfile: Profile? = nil
    ) throws {
        guard let preset = Self.providers[provider] else {
            throw CloudError.unknownProvider(provider, Array(Self.providers.keys))
        }
        self.apiKey = Self.normalizedAPIKey(apiKey, provider: provider)
        self.provider = provider
        self.baseURL = preset.baseURL
        self.model = model ?? preset.defaultModel
        self.modelName = "\(provider)/\(self.model)"
        self.isAnthropic = provider == "anthropic"
        self.defaultProfile = defaultProfile
    }

    // MARK: - Public API

    /// Generate reply suggestions from a JSON input string.
    func generate(inputJSON: String) async throws -> (outputJSON: String, metrics: InferenceMetrics) {
        guard let input = ConversationInput.from(json: inputJSON) else {
            throw CloudError.invalidInput
        }
        return try await generate(input: input)
    }

    /// Generate reply suggestions from a ConversationInput.
    func generate(input: ConversationInput) async throws -> (outputJSON: String, metrics: InferenceMetrics) {
        let messages = PromptBuilder.buildMessages(input: input, userDefaultProfile: defaultProfile)

        var metrics = InferenceMetrics(modelName: modelName)
        metrics.memoryBeforeMB = LLMService.getMemoryMB()
        let startTime = CACurrentMediaTime()

        let rawText: String
        if isAnthropic {
            rawText = try await callAnthropic(messages: messages, metrics: &metrics)
        } else {
            rawText = try await callOpenAICompatible(messages: messages, metrics: &metrics)
        }

        let elapsed = CACurrentMediaTime() - startTime
        metrics.latencyMs = elapsed * 1000
        metrics.memoryAfterMB = LLMService.getMemoryMB()
        metrics.memoryDeltaMB = metrics.memoryAfterMB - metrics.memoryBeforeMB

        let output = OutputParser.parse(raw: rawText)
        let outputJSON = output.toJSON() ?? "{\"suggestions\": []}"

        return (outputJSON, metrics)
    }

    // MARK: - OpenAI-Compatible API (OpenAI, Gemini, Groq, OpenRouter)

    private func callOpenAICompatible(messages: [[String: String]], metrics: inout InferenceMetrics) async throws -> String {
        let url = URL(string: "\(baseURL)/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "max_tokens": 512,
            "temperature": 0.7,
            "response_format": ["type": "json_object"],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudError.networkError("Invalid response")
        }
        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw CloudError.apiError(httpResponse.statusCode, errorBody)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw CloudError.parseError("Failed to parse API response")
        }

        if let usage = json["usage"] as? [String: Any] {
            metrics.promptTokens = usage["prompt_tokens"] as? Int ?? 0
            metrics.tokensGenerated = usage["completion_tokens"] as? Int ?? 0
            metrics.totalTokens = usage["total_tokens"] as? Int ?? 0
        }

        return content
    }

    // MARK: - Anthropic Native API

    private func callAnthropic(messages: [[String: String]], metrics: inout InferenceMetrics) async throws -> String {
        let url = URL(string: "\(baseURL)/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.addValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        var systemPrompt = ""
        var userMessages: [[String: String]] = []
        for msg in messages {
            if msg["role"] == "system" {
                systemPrompt = msg["content"] ?? ""
            } else {
                userMessages.append(msg)
            }
        }

        let body: [String: Any] = [
            "model": model,
            "system": systemPrompt,
            "messages": userMessages,
            "max_tokens": 512,
            "temperature": 0.7,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudError.networkError("Invalid response")
        }
        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw CloudError.apiError(httpResponse.statusCode, errorBody)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let firstBlock = content.first,
              let text = firstBlock["text"] as? String else {
            throw CloudError.parseError("Failed to parse Anthropic response")
        }

        if let usage = json["usage"] as? [String: Any] {
            metrics.promptTokens = usage["input_tokens"] as? Int ?? 0
            metrics.tokensGenerated = usage["output_tokens"] as? Int ?? 0
            metrics.totalTokens = metrics.promptTokens + metrics.tokensGenerated
        }

        return text
    }
}

// MARK: - Errors

enum CloudError: LocalizedError {
    case unknownProvider(String, [String])
    case invalidInput
    case networkError(String)
    case apiError(Int, String)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .unknownProvider(let p, let available):
            return "Unknown provider '\(p)'. Available: \(available.joined(separator: ", "))"
        case .invalidInput:
            return "Invalid JSON input"
        case .networkError(let msg):
            return "Network error: \(msg)"
        case .apiError(let code, let body):
            return "API error (\(code)): \(body)"
        case .parseError(let msg):
            return msg
        }
    }
}
