import Combine
import Foundation

@MainActor
final class ChatViewModel: ObservableObject {
    @Published private(set) var scenario: DemoScenario
    @Published private(set) var threadTitle: String
    @Published private(set) var threadSubtitle: String
    @Published private(set) var messages: [ChatMessageItem]
    @Published var draftText: String
    @Published private(set) var suggestions: [ReplySuggestionItem]
    @Published private(set) var isGenerating: Bool
    @Published private(set) var errorMessage: String?
    @Published private(set) var metrics: InferenceMetrics?
    @Published private(set) var engineStatusText: String
    @Published var threadToneOverride: ThreadToneOverride
    @Published var threadLengthOverride: ThreadLengthOverride

    private let settingsStore: AppSettingsStore
    private var cachedLocalEngine: LocalReplyEngine?
    private var cachedLocalModelResource: String?
    private let mockEngine = MockReplyEngine()
    private var cancellables = Set<AnyCancellable>()
    private var hasBootstrapped = false
    private let contextWindowSize = 10
    private var selfId: String
    private var replyTo: String
    private var participants: [Participant]

    init(
        scenario: DemoScenario = .weekendPlans,
        settingsStore: AppSettingsStore
    ) {
        self.settingsStore = settingsStore
        self.scenario = scenario

        let thread = scenario.makeThread()
        threadTitle = thread.title
        threadSubtitle = thread.subtitle
        messages = thread.messages
        draftText = ""
        suggestions = []
        isGenerating = false
        errorMessage = nil
        metrics = nil
        selfId = thread.selfId
        replyTo = thread.replyTo
        participants = thread.participants
        threadToneOverride = ThreadToneOverride(
            profileTone: thread.conversationProfile?.tone
        )
        threadLengthOverride = ThreadLengthOverride(
            profileLength: thread.conversationProfile?.length
        )
        // Cannot call instance methods on `self` here — `engineStatusText` is not initialized yet.
        let initialModelName = settingsStore.bundledLlamaModel.resourceName
        let initialLocalEngine = LocalReplyEngine(modelResourceName: initialModelName)
        cachedLocalEngine = initialLocalEngine
        cachedLocalModelResource = initialModelName
        engineStatusText = initialLocalEngine.statusDescription

        settingsStore.$bundledLlamaModel
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.invalidateLocalEngineCache()
                self.refreshEngineStatus()
            }
            .store(in: &cancellables)
    }

    private func localEngineForCurrentSettings() -> LocalReplyEngine {
        let name = settingsStore.bundledLlamaModel.resourceName
        if cachedLocalModelResource == name, let cached = cachedLocalEngine {
            return cached
        }
        let engine = LocalReplyEngine(modelResourceName: name)
        cachedLocalEngine = engine
        cachedLocalModelResource = name
        return engine
    }

    private func invalidateLocalEngineCache() {
        cachedLocalEngine = nil
        cachedLocalModelResource = nil
    }

    var backendBadgeText: String {
        resolvedBackendMode.statusBadgeText
    }

    var isLocalBackendSelected: Bool {
        resolvedBackendMode == .local
    }

    var canSendDraft: Bool {
        !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var metricsSummary: String? {
        guard let metrics else { return nil }
        let latency = "\(Int(metrics.latencyMs)) ms"
        if metrics.modelName.isEmpty {
            return latency
        }
        if metrics.tokensGenerated > 0 {
            return "\(metrics.modelName) | \(latency) | \(metrics.tokensGenerated) tok"
        }
        return "\(metrics.modelName) | \(latency)"
    }

    func bootstrapIfNeeded() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        engineStatusText = localEngineForCurrentSettings().statusDescription
        await generateSuggestions()
    }

    func applyScenario(_ newScenario: DemoScenario) {
        guard scenario != newScenario else { return }
        scenario = newScenario
        let thread = newScenario.makeThread()
        threadTitle = thread.title
        threadSubtitle = thread.subtitle
        messages = thread.messages
        draftText = ""
        suggestions = []
        metrics = nil
        errorMessage = nil
        selfId = thread.selfId
        replyTo = thread.replyTo
        participants = thread.participants
        threadToneOverride = ThreadToneOverride(
            profileTone: thread.conversationProfile?.tone
        )
        threadLengthOverride = ThreadLengthOverride(
            profileLength: thread.conversationProfile?.length
        )
    }

    func insertSuggestion(_ suggestion: ReplySuggestionItem) {
        draftText = suggestion.text
    }

    func clearError() {
        errorMessage = nil
    }

    func sendDraft() {
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let participantName = participants
            .first(where: { $0.id == selfId })?
            .name ?? "Me"
        messages.append(
            ChatMessageItem(
                speakerId: selfId,
                speakerName: participantName,
                text: trimmed,
                createdAt: Date(),
                isSelf: true
            )
        )
        draftText = ""
        suggestions = []
        metrics = nil
        errorMessage = nil
    }

    func refreshEngineStatus() {
        if settingsStore.backendMode == .local,
           settingsStore.isRunningInXcodePreview {
            engineStatusText = "Local GGUF inference is disabled in Xcode Previews. Run the app in Simulator or on device to test Local mode."
            return
        }

        switch resolvedBackendMode {
        case .local:
            engineStatusText = localEngineForCurrentSettings().statusDescription
        case .cloud:
            let provider = settingsStore.cloudProvider.displayName
            engineStatusText = settingsStore.cloudAPIKey.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
                ? "Cloud mode selected. Add an API key to generate suggestions."
                : "\(provider) ready. Requests are sent to the selected cloud provider."
        case .mock:
            engineStatusText = "Safe demo mock mode is ready."
        }
    }

    func generateSuggestions() async {
        guard !isGenerating else { return }
        isGenerating = true
        suggestions = []
        errorMessage = nil
        refreshEngineStatus()
        defer {
            isGenerating = false
            refreshEngineStatus()
        }

        let input = makeConversationInput()

        // Called from inferenceQueue (background) — hop to MainActor to mutate published state.
        let appendSuggestion: (Suggestion) -> Void = { [weak self] suggestion in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let item = self.normalizeSingleSuggestion(suggestion) {
                    self.suggestions.append(item)
                }
            }
        }

        do {
            let metricsResult = try await resolveEngine().generateSuggestionsProgressive(
                input: input,
                defaultProfile: settingsStore.defaultProfile,
                onSuggestionReady: appendSuggestion
            )
            metrics = metricsResult
            if suggestions.isEmpty {
                throw ReplySuggestionEngineError.emptySuggestions
            }
        } catch {
            guard settingsStore.safeDemoModeEnabled,
                  settingsStore.backendMode != .mock else {
                suggestions = []
                metrics = nil
                errorMessage = error.localizedDescription
                return
            }

            suggestions = []
            do {
                let metricsResult = try await mockEngine.generateSuggestionsProgressive(
                    input: input,
                    defaultProfile: settingsStore.defaultProfile,
                    onSuggestionReady: appendSuggestion
                )
                metrics = metricsResult
                errorMessage = "Fallback to Mock: \(error.localizedDescription)"
            } catch {
                suggestions = []
                metrics = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func normalizeSuggestions(
        _ rawSuggestions: [Suggestion]
    ) -> [ReplySuggestionItem] {
        let cleaned = rawSuggestions.compactMap { suggestion -> Suggestion? in
            let label = suggestion.label.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let text = suggestion.text.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !text.isEmpty else { return nil }
            let normalizedLabel = normalizeSuggestionLabel(label)
            return Suggestion(label: normalizedLabel, text: text)
        }

        let preferredOrder = ["Natural", "Polite", "Like You"]
        var usedLabels = Set<String>()
        var ordered: [ReplySuggestionItem] = []

        for label in preferredOrder {
            if let match = cleaned.first(where: { $0.label == label && !usedLabels.contains($0.text) }) {
                ordered.append(ReplySuggestionItem(suggestion: match))
                usedLabels.insert(match.text)
            }
        }

        for suggestion in cleaned where !usedLabels.contains(suggestion.text) {
            let fallbackLabel = ordered.count < preferredOrder.count
                ? preferredOrder[ordered.count]
                : suggestion.label
            ordered.append(
                ReplySuggestionItem(
                    suggestion: Suggestion(
                        label: fallbackLabel,
                        text: suggestion.text
                    )
                )
            )
            usedLabels.insert(suggestion.text)
        }

        return Array(ordered.prefix(3))
    }

    private func normalizeSuggestionLabel(_ label: String) -> String {
        switch label.lowercased() {
        case "natural", "normal":
            return "Natural"
        case "polite", "kind", "kinder":
            return "Polite"
        case "like you", "likeyou", "casual", "casual punchy":
            return "Like You"
        case "label", "text", "option":
            return "Natural"
        default:
            return label.isEmpty ? "Natural" : label.capitalized
        }
    }

    private func resolveEngine() -> any ReplySuggestionEngine {
        switch settingsStore.backendMode {
        case .mock:
            return mockEngine
        case .local:
            if settingsStore.isRunningInXcodePreview { return mockEngine }
            return localEngineForCurrentSettings()
        case .cloud:
            return CloudReplyEngine(
                provider: settingsStore.cloudProvider,
                modelName: settingsStore.cloudModelName,
                apiKey: settingsStore.cloudAPIKey
            )
        }
    }

    private func normalizeSingleSuggestion(_ suggestion: Suggestion) -> ReplySuggestionItem? {
        let label = normalizeSuggestionLabel(
            suggestion.label.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let text = suggestion.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return ReplySuggestionItem(suggestion: Suggestion(label: label, text: text))
    }

    private var resolvedBackendMode: ReplyBackendMode {
        if settingsStore.backendMode == .local,
           settingsStore.isRunningInXcodePreview {
            return .mock
        }
        return settingsStore.backendMode
    }

    private func makeConversationInput() -> ConversationInput {
        let conversation = messages
            .suffix(contextWindowSize)
            .map { message in
                Message(speaker: message.speakerId, text: message.text)
            }

        return ConversationInput(
            conversation: Array(conversation),
            draft: draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : draftText,
            conversationProfile: Profile(
                tone: threadToneOverride.toneValue,
                length: threadLengthOverride.lengthValue
            ),
            selfId: selfId,
            replyTo: replyTo,
            participants: participants
        )
    }
}
