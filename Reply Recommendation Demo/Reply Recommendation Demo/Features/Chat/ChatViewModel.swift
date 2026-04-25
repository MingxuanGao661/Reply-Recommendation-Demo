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
    private let localEngine = LocalReplyEngine()
    private let mockEngine = MockReplyEngine()
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
        engineStatusText = localEngine.statusDescription
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
        engineStatusText = localEngine.statusDescription
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
            engineStatusText = localEngine.statusDescription
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
        errorMessage = nil
        refreshEngineStatus()
        defer {
            isGenerating = false
            refreshEngineStatus()
        }

        let input = makeConversationInput()

        do {
            let result = try await runSelectedEngine(input: input)
            suggestions = result.suggestions.map(ReplySuggestionItem.init)
            metrics = result.metrics
        } catch {
            guard settingsStore.safeDemoModeEnabled,
                  settingsStore.backendMode != .mock else {
                suggestions = []
                metrics = nil
                errorMessage = error.localizedDescription
                return
            }

            do {
                let result = try await mockEngine.generateSuggestions(
                    input: input,
                    defaultProfile: settingsStore.defaultProfile
                )
                suggestions = result.suggestions.map(ReplySuggestionItem.init)
                metrics = result.metrics
                errorMessage = "Fallback to Mock: \(error.localizedDescription)"
            } catch {
                suggestions = []
                metrics = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func runSelectedEngine(
        input: ConversationInput
    ) async throws -> ReplyGenerationResult {
        switch settingsStore.backendMode {
        case .mock:
            return try await mockEngine.generateSuggestions(
                input: input,
                defaultProfile: settingsStore.defaultProfile
            )
        case .local:
            if settingsStore.isRunningInXcodePreview {
                return try await mockEngine.generateSuggestions(
                    input: input,
                    defaultProfile: settingsStore.defaultProfile
                )
            }
            return try await localEngine.generateSuggestions(
                input: input,
                defaultProfile: settingsStore.defaultProfile
            )
        case .cloud:
            let cloudEngine = CloudReplyEngine(
                provider: settingsStore.cloudProvider,
                modelName: settingsStore.cloudModelName,
                apiKey: settingsStore.cloudAPIKey
            )
            return try await cloudEngine.generateSuggestions(
                input: input,
                defaultProfile: settingsStore.defaultProfile
            )
        }
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
