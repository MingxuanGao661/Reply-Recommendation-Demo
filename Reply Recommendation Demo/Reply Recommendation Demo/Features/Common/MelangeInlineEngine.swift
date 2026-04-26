import Foundation

/// ReplySuggestionEngine powered by Melange LFM2.5 1.2B.
/// This engine only handles inline generation; panel suggestions remain on LocalReplyEngine.
final class MelangeInlineEngine: ReplySuggestionEngine {
    private let service: MelangeLLMService

    init(service: MelangeLLMService) {
        self.service = service
    }

    func generateSuggestions(
        input: ConversationInput,
        defaultProfile: Profile
    ) async throws -> ReplyGenerationResult {
        throw ReplySuggestionEngineError.emptySuggestions
    }

    func generateInlineSuggestion(
        input: ConversationInput,
        defaultProfile: Profile
    ) async throws -> InlineGenerationResult {
        let draftPrefix = input.hasDraft ? input.resolvedDraft : ""
        let prompt = PromptBuilder.buildLFM25PromptInline(input: input)
        Self.logDebug("engine start draftChars=\(draftPrefix.count) promptChars=\(prompt.count)")
        let (rawOutput, latencyMs, tokensGenerated) = try await service.generate(prompt: prompt)
        Self.logDebug(
            "engine raw latencyMs=\(Int(latencyMs)) tokens=\(tokensGenerated) raw=\(Self.preview(rawOutput))"
        )

        let fullText = InlineCompletionFormatter.fullText(
            draftPrefix: draftPrefix,
            rawOutput: rawOutput
        )
        Self.logDebug("engine formatted full=\(Self.preview(fullText))")
        guard !fullText.isEmpty else {
            Self.logDebug("engine empty formatted output")
            throw ReplySuggestionEngineError.emptySuggestions
        }

        var metrics = InferenceMetrics()
        metrics.modelName = "Melange/LFM2.5-1.2B"
        metrics.latencyMs = latencyMs
        metrics.tokensGenerated = tokensGenerated
        metrics.totalTokens = tokensGenerated

        return InlineGenerationResult(
            suggestion: Suggestion(label: "Direct", text: fullText),
            metrics: metrics
        )
    }

    func warmUp() async throws {
        try await service.warmUp()
    }

    func release() async {
        await service.release()
    }

    private static func logDebug(_ message: String) {
        NSLog("[melange-debug] %@", message)
    }

    private static func preview(_ text: String, limit: Int = 120) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        guard cleaned.count > limit else { return cleaned }
        return String(cleaned.prefix(limit)) + "..."
    }
}
