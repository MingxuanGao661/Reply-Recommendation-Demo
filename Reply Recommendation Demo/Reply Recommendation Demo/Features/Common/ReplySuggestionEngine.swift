import Foundation

struct ReplyGenerationResult {
    let suggestions: [Suggestion]
    let metrics: InferenceMetrics
}

protocol ReplySuggestionEngine {
    func generateSuggestions(
        input: ConversationInput,
        defaultProfile: Profile
    ) async throws -> ReplyGenerationResult

    /// Progressive variant: calls `onSuggestionReady` each time one card is ready,
    /// so the UI can render cards as they arrive instead of waiting for all three.
    func generateSuggestionsProgressive(
        input: ConversationInput,
        defaultProfile: Profile,
        onSuggestionReady: @escaping (Suggestion) -> Void
    ) async throws -> InferenceMetrics
}

extension ReplySuggestionEngine {
    /// Default: finish all suggestions first, then deliver them in one batch.
    func generateSuggestionsProgressive(
        input: ConversationInput,
        defaultProfile: Profile,
        onSuggestionReady: @escaping (Suggestion) -> Void
    ) async throws -> InferenceMetrics {
        let result = try await generateSuggestions(input: input, defaultProfile: defaultProfile)
        for suggestion in result.suggestions {
            onSuggestionReady(suggestion)
        }
        return result.metrics
    }
}

enum ReplySuggestionEngineError: LocalizedError {
    case localModelMissing(String)
    case cloudAPIKeyMissing
    case emptySuggestions

    var errorDescription: String? {
        switch self {
        case .localModelMissing(let fileName):
            return "Missing local model in app bundle: \(fileName)."
        case .cloudAPIKeyMissing:
            return "Add a cloud API key in Settings to use Cloud mode."
        case .emptySuggestions:
            return "The model returned no suggestions."
        }
    }
}

final class MockReplyEngine: ReplySuggestionEngine {
    func generateSuggestions(
        input: ConversationInput,
        defaultProfile: Profile
    ) async throws -> ReplyGenerationResult {
        let startTime = Date()
        try await Task.sleep(nanoseconds: 450_000_000)

        let pairs = suggestionPairs(input: input, defaultProfile: defaultProfile)

        var metrics = InferenceMetrics()
        metrics.modelName = "mock/safe-demo"
        metrics.latencyMs = Date().timeIntervalSince(startTime) * 1000
        metrics.tokensGenerated = pairs.reduce(into: 0) { $0 += $1.1.count }
        metrics.totalTokens = metrics.tokensGenerated

        return ReplyGenerationResult(
            suggestions: pairs.map { Suggestion(label: $0.0, text: $0.1) },
            metrics: metrics
        )
    }

    func generateSuggestionsProgressive(
        input: ConversationInput,
        defaultProfile: Profile,
        onSuggestionReady: @escaping (Suggestion) -> Void
    ) async throws -> InferenceMetrics {
        let startTime = Date()

        let pairs = suggestionPairs(input: input, defaultProfile: defaultProfile)

        var totalTokens = 0
        for (label, text) in pairs {
            try await Task.sleep(nanoseconds: 200_000_000)
            onSuggestionReady(Suggestion(label: label, text: text))
            totalTokens += text.count
        }

        var metrics = InferenceMetrics()
        metrics.modelName = "mock/safe-demo"
        metrics.latencyMs = Date().timeIntervalSince(startTime) * 1000
        metrics.tokensGenerated = totalTokens
        metrics.totalTokens = totalTokens
        return metrics
    }

    private func suggestionPairs(
        input: ConversationInput,
        defaultProfile: Profile
    ) -> [(String, String)] {
        let effectiveProfile = input.effectiveProfile(userDefault: defaultProfile)
        let target = input.replyTargetName ?? "them"
        let topic = input.replyTargetMessage?.text ?? input.conversation.last?.text ?? "that"
        let draft = input.resolvedDraft

        switch input.suggestionThemeSet {
        case .replyStyles:
            if input.hasDraft {
                return [
                    ("Direct", polishedDraft(draft)),
                    ("Friendly", rewriteDraft(draft, closing: "Sounds good on my end.")),
                    ("Thoughtful", rewriteDraft(draft, closing: "Just wanted to make that clear.")),
                ]
            }
            return [
                ("Direct", "Yes, that works for me."),
                ("Friendly", "Sounds good, \(target). I'm in."),
                ("Thoughtful", thoughtfulReply(topic: topic, tone: effectiveProfile.resolvedTone)),
            ]
        case .decisionReply:
            if input.hasDraft {
                return [
                    ("Agree", rewriteDraft(draft, closing: "Yes, that works for me.")),
                    ("Soft Decline", "I don't think I can this time, but thank you for asking."),
                    ("Delay", "I'm not sure yet. Can I confirm a little later?"),
                ]
            }
            return [
                ("Agree", "Yes, that works for me."),
                ("Soft Decline", "I don't think I can this time, but thank you for asking."),
                ("Delay", "I'm not sure yet. Can I let you know a bit later?"),
            ]
        }
    }

    private func polishedDraft(_ draft: String) -> String {
        let cleaned = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "" }
        return cleaned.hasSuffix(".") || cleaned.hasSuffix("!") || cleaned.hasSuffix("?")
            ? cleaned
            : "\(cleaned)."
    }

    private func rewriteDraft(_ draft: String, closing: String) -> String {
        let base = polishedDraft(draft)
        guard !base.isEmpty else { return closing }
        return "\(base) \(closing)"
    }

    private func thoughtfulReply(topic: String, tone: String) -> String {
        switch tone {
        case "formal":
            return "That should work for me. Thanks for checking."
        case "neutral":
            return "That sounds good to me, and \(topic.lowercased()) works."
        case "friendly":
            return "That sounds good to me. Happy to make that work."
        default:
            return "That sounds good to me, and I appreciate you checking."
        }
    }
}

final class CloudReplyEngine: ReplySuggestionEngine {
    private let provider: CloudProviderOption
    private let modelName: String
    private let apiKey: String

    init(provider: CloudProviderOption, modelName: String, apiKey: String) {
        self.provider = provider
        self.modelName = modelName
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func generateSuggestions(
        input: ConversationInput,
        defaultProfile: Profile
    ) async throws -> ReplyGenerationResult {
        guard !apiKey.isEmpty else {
            throw ReplySuggestionEngineError.cloudAPIKeyMissing
        }

        let selectedModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let service = try CloudService(
            apiKey: apiKey,
            provider: provider.rawValue,
            model: selectedModel.isEmpty ? nil : selectedModel,
            defaultProfile: defaultProfile
        )
        let (jsonString, metrics) = try await service.generate(input: input)
        return try decodeGenerationResult(outputJSON: jsonString, metrics: metrics)
    }
}

final class LocalReplyEngine: ReplySuggestionEngine {
    private let modelResourceName: String
    private let bundle: Bundle
    private let inferenceQueue = DispatchQueue(
        label: "reply-demo.local-inference",
        qos: .userInitiated
    )

    private var service: LLMService?

    init(
        modelResourceName: String = "Llama-3.2-3B-Instruct-Q4_K_M",
        bundle: Bundle = .main
    ) {
        self.modelResourceName = modelResourceName
        self.bundle = bundle
    }

    var statusDescription: String {
        if service != nil {
#if targetEnvironment(simulator)
            return "Local model loaded on Simulator (CPU mode)."
#else
            return "Local model loaded and ready."
#endif
        }
        if modelPathInBundle() != nil {
#if targetEnvironment(simulator)
            return "Model found in bundle. First Simulator Local run will initialize CPU inference."
#else
            return "Model found in bundle. First Local generation will initialize it."
#endif
        }
        return "Local GGUF not found in the app bundle."
    }

    var isModelBundled: Bool {
        modelPathInBundle() != nil
    }

    func generateSuggestions(
        input: ConversationInput,
        defaultProfile: Profile
    ) async throws -> ReplyGenerationResult {
        try await withCheckedThrowingContinuation { continuation in
            inferenceQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                do {
                    let service = try self.prepareService(defaultProfile: defaultProfile)
                    service.defaultProfile = defaultProfile
                    let (jsonString, metrics) = try service.generate(input: input)
                    let result = try decodeGenerationResult(
                        outputJSON: jsonString,
                        metrics: metrics
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Progressive: runs three separate single-tone LLM calls in serial.
    /// Each card is delivered via `onSuggestionReady` as soon as it finishes,
    /// so the UI can animate cards in one by one.
    func generateSuggestionsProgressive(
        input: ConversationInput,
        defaultProfile: Profile,
        onSuggestionReady: @escaping (Suggestion) -> Void
    ) async throws -> InferenceMetrics {
        try await withCheckedThrowingContinuation { continuation in
            inferenceQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                do {
                    let service = try self.prepareService(defaultProfile: defaultProfile)
                    service.defaultProfile = defaultProfile

                    var combined = InferenceMetrics(modelName: self.modelResourceName)

                    for toneLabel in input.suggestionThemeSet.labels {
                        let prompt = PromptBuilder.buildLlamaPromptSingle(
                            input: input,
                            userDefaultProfile: defaultProfile,
                            toneLabel: toneLabel
                        )
                        let (jsonString, metrics) = try service.generate(prompt: prompt)

                        combined.tokensGenerated += metrics.tokensGenerated
                        combined.totalTokens    += metrics.totalTokens
                        combined.latencyMs      += metrics.latencyMs
                        combined.modelName       = metrics.modelName

                        let output = OutputParser.parse(raw: jsonString)
                        if let rawText = output.suggestions.first?.text
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                           !rawText.isEmpty {
                            onSuggestionReady(Suggestion(label: toneLabel, text: rawText))
                        }
                    }

                    continuation.resume(returning: combined)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func prepareService(defaultProfile: Profile) throws -> LLMService {
        if let service {
            return service
        }

        guard let modelPath = modelPathInBundle() else {
            throw ReplySuggestionEngineError.localModelMissing(
                "\(modelResourceName).gguf"
            )
        }

        let service = try LLMService(
            modelPath: modelPath,
            defaultProfile: defaultProfile
        )
        self.service = service
        return service
    }

    private func modelPathInBundle() -> String? {
        bundle.path(forResource: modelResourceName, ofType: "gguf")
    }
}

private func decodeGenerationResult(
    outputJSON: String,
    metrics: InferenceMetrics
) throws -> ReplyGenerationResult {
    guard let data = outputJSON.data(using: .utf8),
          let output = try? JSONDecoder().decode(SuggestionOutput.self, from: data),
          !output.suggestions.isEmpty else {
        throw ReplySuggestionEngineError.emptySuggestions
    }
    return ReplyGenerationResult(suggestions: output.suggestions, metrics: metrics)
}
