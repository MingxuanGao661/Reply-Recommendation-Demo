import Foundation

struct ReplyGenerationResult {
    let suggestions: [Suggestion]
    let metrics: InferenceMetrics
}

struct InlineGenerationResult {
    let suggestion: Suggestion
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

    /// Fast-path single suggestion for inline completion.
    func generateInlineSuggestion(
        input: ConversationInput,
        defaultProfile: Profile
    ) async throws -> InlineGenerationResult
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

    func generateInlineSuggestion(
        input: ConversationInput,
        defaultProfile: Profile
    ) async throws -> InlineGenerationResult {
        if input.hasDraft {
            let startTime = Date()
            try await Task.sleep(nanoseconds: 120_000_000)
            var metrics = InferenceMetrics()
            metrics.modelName = "mock/inline"
            metrics.latencyMs = Date().timeIntervalSince(startTime) * 1000
            metrics.tokensGenerated = 4
            metrics.totalTokens = 4
            return InlineGenerationResult(
                suggestion: Suggestion(label: "Direct", text: input.resolvedDraft + " sounds good."),
                metrics: metrics
            )
        }

        let result = try await generateSuggestions(input: input, defaultProfile: defaultProfile)
        guard let first = result.suggestions.first else {
            throw ReplySuggestionEngineError.emptySuggestions
        }
        return InlineGenerationResult(suggestion: first, metrics: result.metrics)
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

    func generateInlineSuggestion(
        input: ConversationInput,
        defaultProfile: Profile
    ) async throws -> InlineGenerationResult {
        let result = try await generateSuggestions(input: input, defaultProfile: defaultProfile)
        guard let first = result.suggestions.first else {
            throw ReplySuggestionEngineError.emptySuggestions
        }
        return InlineGenerationResult(suggestion: first, metrics: result.metrics)
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

    func generateInlineSuggestion(
        input: ConversationInput,
        defaultProfile: Profile
    ) async throws -> InlineGenerationResult {
        let result = try await generateSuggestions(input: input, defaultProfile: defaultProfile)
        guard let first = result.suggestions.first else {
            throw ReplySuggestionEngineError.emptySuggestions
        }
        return InlineGenerationResult(suggestion: first, metrics: result.metrics)
    }
}

final class LocalReplyEngine: ReplySuggestionEngine {
    private static let inferenceQueueSpecificKey = DispatchSpecificKey<Void>()
    private static let sharedEngineLock = NSLock()
    private static var sharedEngineSignature: String?
    private static var sharedEngine: LocalReplyEngine?

    private let modelResourceName: String
    /// Resource name (no extension) of the bundled LoRA adapter GGUF, if any.
    private let loraResourceName: String?
    /// Absolute filesystem path to a LoRA `.gguf` (e.g. user-trained adapter). When set and the file exists, this wins over `loraResourceName`.
    private let loraAdapterFilePath: String?
    /// When true, **general** (`replyStyles`) inference uses the User-LoRA single-reply prompt (plain text → one `Natural` card).
    private let usePersonalLoraGeneralInference: Bool
    /// Scale applied to the LoRA adapter weights (1.0 = full strength).
    private let loraScale: Float
    private let bundle: Bundle
    private let temperature: Float
    private let topK: Int32
    private let inferenceQueue = DispatchQueue(
        label: "reply-demo.local-inference",
        qos: .userInitiated
    )

    private var service: LLMService?

    private static func logRuntime(_ message: String) {
        NSLog("[runtime] %@", message)
    }

    static func shared(
        signature: String,
        modelResourceName: String = "Llama-3.2-3B-Instruct-Q4_K_M",
        loraResourceName: String? = nil,
        loraAdapterFilePath: String? = nil,
        usePersonalLoraGeneralInference: Bool = false,
        loraScale: Float = 1.0,
        bundle: Bundle = .main,
        temperature: Float = 0.70,
        topK: Int32 = 40
    ) -> LocalReplyEngine {
        sharedEngineLock.lock()
        defer { sharedEngineLock.unlock() }

        if sharedEngineSignature == signature,
           let sharedEngine {
            return sharedEngine
        }

        let engine = LocalReplyEngine(
            modelResourceName: modelResourceName,
            loraResourceName: loraResourceName,
            loraAdapterFilePath: loraAdapterFilePath,
            usePersonalLoraGeneralInference: usePersonalLoraGeneralInference,
            loraScale: loraScale,
            bundle: bundle,
            temperature: temperature,
            topK: topK
        )
        sharedEngineSignature = signature
        sharedEngine = engine
        return engine
    }

    init(
        modelResourceName: String = "Llama-3.2-3B-Instruct-Q4_K_M",
        loraResourceName: String? = nil,
        loraAdapterFilePath: String? = nil,
        usePersonalLoraGeneralInference: Bool = false,
        loraScale: Float = 1.0,
        bundle: Bundle = .main,
        temperature: Float = 0.70,
        topK: Int32 = 40
    ) {
        self.modelResourceName = modelResourceName
        self.loraResourceName = loraResourceName
        self.temperature = temperature
        self.topK = topK
        self.loraAdapterFilePath = loraAdapterFilePath
        self.usePersonalLoraGeneralInference = usePersonalLoraGeneralInference
        self.loraScale = loraScale
        self.bundle = bundle
        inferenceQueue.setSpecific(key: Self.inferenceQueueSpecificKey, value: ())
    }

    deinit {
        // Ensure the service is released on the same serial queue used for inference.
        // This avoids teardown racing with in-flight decode work.
        if DispatchQueue.getSpecific(key: Self.inferenceQueueSpecificKey) != nil {
            service = nil
        } else {
            inferenceQueue.sync {
                service = nil
            }
        }
    }

    var statusDescription: String {
        if service != nil {
            let loraNote = resolvedLoraPathForLoad() != nil ? " + LoRA" : ""
#if targetEnvironment(simulator)
            return "Local model\(loraNote) loaded on Simulator (CPU mode)."
#else
            return "Local model\(loraNote) loaded and ready."
#endif
        }
        if modelPathInBundle() != nil {
            let loraNote: String
            if resolvedLoraPathForLoad() != nil {
                loraNote = " + LoRA adapter found."
            } else if loraAdapterFilePath?.isEmpty == false {
                loraNote = " (User LoRA path set but file not found.)"
            } else if let name = loraResourceName {
                loraNote = " (LoRA adapter \(name).gguf not found in bundle.)"
            } else {
                loraNote = ""
            }
#if targetEnvironment(simulator)
            return "Model found in bundle\(loraNote) First Simulator Local run will initialize CPU inference."
#else
            return "Model found in bundle\(loraNote) First Local generation will initialize it."
#endif
        }
        return "Local GGUF not found in the app bundle."
    }

    var isModelBundled: Bool {
        modelPathInBundle() != nil
    }

    /// Warms up the local model so the first real generation has no cold-start delay.
    ///
    /// Two-phase warm-up:
    /// 1. `prepareService` loads model weights + allocates KV cache (~1-3 s for 3B).
    /// 2. A minimal 2-token inference triggers Metal shader JIT compilation (~0.5-1 s).
    ///    Without step 2, the first real `generate()` call still pays a JIT penalty.
    func warmUp() {
        guard service == nil, modelPathInBundle() != nil else { return }
        inferenceQueue.async { [weak self] in
            guard let self else { return }
            guard let svc = try? self.prepareService(defaultProfile: Profile()) else { return }
            // Minimal decode: just enough to compile Metal shaders. Output is discarded.
            _ = try? svc.generate(prompt: "<|begin_of_text|>", tokenLimit: 2)
        }
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
                    let totalStart = Date()
                    let service = try self.prepareService(defaultProfile: defaultProfile)
                    service.defaultProfile = defaultProfile
                    let (jsonString, metrics) = try service.generate(input: input)
                    let result = try decodeGenerationResult(
                        outputJSON: jsonString,
                        metrics: metrics
                    )
                    Self.logRuntime(
                        "generate total wallMs=\(Self.elapsedMs(since: totalStart)) inferenceMs=\(Int(metrics.latencyMs)) tokens=\(metrics.tokensGenerated)"
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func generateInlineSuggestion(
        input: ConversationInput,
        defaultProfile: Profile
    ) async throws -> InlineGenerationResult {
        try await withCheckedThrowingContinuation { continuation in
            inferenceQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                do {
                    let totalStart = Date()
                    let service = try self.prepareService(defaultProfile: defaultProfile)
                    service.defaultProfile = defaultProfile

                    // Copilot-style prompt: plain-text output, 3-message context, pre-filled draft prefix.
                    let draftPrefix = input.hasDraft ? input.resolvedDraft : ""
                    let promptParts = PromptBuilder.buildLlamaPromptInlineParts(input: input)
                    let prompt = promptParts.cacheablePrefix + promptParts.requestSuffix
                    let cacheKey = self.inlineKVCacheKey(prefix: promptParts.cacheablePrefix)
                    Self.logInlineDebug(
                        "engine start draftChars=\(draftPrefix.count) promptChars=\(prompt.count) model=\(self.modelResourceName)"
                    )

                    // Tiny token budget for inline: speed matters more than perfect wording here.
                    let (rawOutput, metrics) = try service.generateRaw(
                        prefix: promptParts.cacheablePrefix,
                        suffix: promptParts.requestSuffix,
                        cacheKey: cacheKey,
                        tokenLimit: 15
                    )
                    Self.logInlineDebug(
                        "engine output latencyMs=\(Int(metrics.latencyMs)) tokens=\(metrics.tokensGenerated) raw=\(Self.preview(rawOutput))"
                    )
                    Self.logRuntime(
                        "inline total wallMs=\(Self.elapsedMs(since: totalStart)) inferenceMs=\(Int(metrics.latencyMs)) tokens=\(metrics.tokensGenerated)"
                    )

                    // Output is the continuation after the pre-filled draft.
                    // Reconstruct the full message: draft + continuation, strip after first newline.
                    let fullText = InlineCompletionFormatter.fullText(
                        draftPrefix: draftPrefix,
                        rawOutput: rawOutput
                    )

                    guard !fullText.isEmpty else {
                        Self.logInlineDebug("engine empty fullText")
                        throw ReplySuggestionEngineError.emptySuggestions
                    }
                    if !draftPrefix.isEmpty,
                       InlineCompletionFormatter.visibleSuffix(fullText: fullText, draftPrefix: draftPrefix) == nil {
                        Self.logInlineDebug(
                            "engine no visible suffix full=\(Self.preview(fullText)) draftChars=\(draftPrefix.count)"
                        )
                        throw ReplySuggestionEngineError.emptySuggestions
                    }
                    Self.logInlineDebug(
                        "engine fullText prefixMatch=\(fullText.lowercased().hasPrefix(draftPrefix.lowercased())) full=\(Self.preview(fullText))"
                    )

                    let label: String
                    switch input.suggestionThemeSet {
                    case .decisionReply: label = "Agree"
                    case .replyStyles:   label = "Direct"
                    }
                    continuation.resume(returning: InlineGenerationResult(
                        suggestion: Suggestion(label: label, text: fullText),
                        metrics: metrics
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func logInlineDebug(_ message: String) {
        NSLog("[inline-debug] %@", message)
    }

    private static func elapsedMs(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    private static func preview(_ text: String, limit: Int = 180) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        guard cleaned.count > limit else { return cleaned }
        return String(cleaned.prefix(limit)) + "..."
    }

    private func inlineKVCacheKey(prefix: String) -> String {
        [
            "inline-v1",
            modelResourceName,
            loraResourceName ?? "-",
            loraAdapterFilePath ?? "-",
            usePersonalLoraGeneralInference ? "personal" : "standard",
            String(prefix.hashValue),
        ].joined(separator: "|")
    }

    private func progressiveKVCacheKey(prefix: String) -> String {
        [
            "progressive-v1",
            modelResourceName,
            loraResourceName ?? "-",
            loraAdapterFilePath ?? "-",
            usePersonalLoraGeneralInference ? "personal" : "standard",
            String(prefix.hashValue),
        ].joined(separator: "|")
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
                    let totalStart = Date()
                    let service = try self.prepareService(defaultProfile: defaultProfile)
                    service.defaultProfile = defaultProfile

                    var combined = InferenceMetrics(modelName: self.modelResourceName)

                    if self.usePersonalLoraGeneralInference {
                        switch input.suggestionThemeSet {
                        case .replyStyles:
                            let toneStart = Date()
                            let (jsonString, metrics) = try service.generate(input: input)
                            combined.tokensGenerated += metrics.tokensGenerated
                            combined.totalTokens += metrics.totalTokens
                            combined.latencyMs += metrics.latencyMs
                            combined.modelName = metrics.modelName
                            Self.logRuntime(
                                "progressive tone=PersonalLoRA wallMs=\(Self.elapsedMs(since: toneStart)) inferenceMs=\(Int(metrics.latencyMs)) tokens=\(metrics.tokensGenerated)"
                            )

                            let result = try decodeGenerationResult(
                                outputJSON: jsonString,
                                metrics: metrics
                            )
                            for suggestion in result.suggestions {
                                onSuggestionReady(suggestion)
                            }
                            Self.logRuntime(
                                "progressive total wallMs=\(Self.elapsedMs(since: totalStart)) inferenceMs=\(Int(combined.latencyMs)) tones=\(result.suggestions.count) tokens=\(combined.tokensGenerated)"
                            )
                            continuation.resume(returning: combined)
                            return
                        case .decisionReply:
                            break
                        }
                    }

                    for toneLabel in input.suggestionThemeSet.labels {
                        let toneStart = Date()
                        let promptParts = PromptBuilder.buildLlamaPromptSingleParts(
                            input: input,
                            userDefaultProfile: defaultProfile,
                            toneLabel: toneLabel
                        )
                        let (jsonString, metrics) = try service.generate(
                            prefix: promptParts.cacheablePrefix,
                            suffix: promptParts.requestSuffix,
                            cacheKey: self.progressiveKVCacheKey(prefix: promptParts.cacheablePrefix)
                        )
                        Self.logRuntime(
                            "progressive tone=\(toneLabel) wallMs=\(Self.elapsedMs(since: toneStart)) inferenceMs=\(Int(metrics.latencyMs)) promptTokens=\(metrics.promptTokens) tokens=\(metrics.tokensGenerated)"
                        )

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

                    Self.logRuntime(
                        "progressive total wallMs=\(Self.elapsedMs(since: totalStart)) inferenceMs=\(Int(combined.latencyMs)) tones=\(input.suggestionThemeSet.labels.count) tokens=\(combined.tokensGenerated)"
                    )
                    continuation.resume(returning: combined)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func prepareService(defaultProfile: Profile) throws -> LLMService {
        if let service {
            service.defaultProfile = defaultProfile
            service.inferPersonalLoraGeneralAsPlainText = usePersonalLoraGeneralInference
            return service
        }

        guard let modelPath = modelPathInBundle() else {
            throw ReplySuggestionEngineError.localModelMissing(
                "\(modelResourceName).gguf"
            )
        }

        let resolvedLoraPath = resolvedLoraPathForLoad()
        let loadStart = Date()
        Self.logRuntime(
            "loading start model=\(modelResourceName) lora=\(resolvedLoraPath == nil ? "none" : "enabled")"
        )
        let service = try LLMService(
            modelPath: modelPath,
            loraPath: resolvedLoraPath,
            loraScale: loraScale,
            defaultProfile: defaultProfile,
            temperature: temperature,
            topK: topK
        )
        service.inferPersonalLoraGeneralAsPlainText = usePersonalLoraGeneralInference
        self.service = service
        Self.logRuntime(
            "loading complete wallMs=\(Self.elapsedMs(since: loadStart)) model=\(modelResourceName) lora=\(resolvedLoraPath == nil ? "none" : "enabled")"
        )
        return service
    }

    private func modelPathInBundle() -> String? {
        bundle.path(forResource: modelResourceName, ofType: "gguf")
    }

    private func loraPathInBundle() -> String? {
        guard let name = loraResourceName else { return nil }
        return bundle.path(forResource: name, ofType: "gguf")
    }

    private func resolvedLoraPathForLoad() -> String? {
        let trimmed = loraAdapterFilePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty, FileManager.default.fileExists(atPath: trimmed) {
            return trimmed
        }
        return loraPathInBundle()
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
