import Combine
import Foundation

@MainActor
final class ChatViewModel: ObservableObject {
    @Published private(set) var conversationMode: ConversationMode
    @Published private(set) var scenario: DemoScenario
    @Published private(set) var messages: [ChatMessageItem]
    @Published private(set) var participants: [Participant]
    @Published var draftText: String
    @Published private(set) var suggestionSlots: [SuggestionSlotItem]
    @Published private(set) var isGenerating: Bool
    @Published private(set) var errorMessage: String?
    @Published private(set) var metrics: InferenceMetrics?
    @Published private(set) var engineStatusText: String
    @Published var threadToneOverride: ThreadToneOverride
    @Published var threadLengthOverride: ThreadLengthOverride
    @Published private(set) var activeComposerParticipantID: String

    private let settingsStore: AppSettingsStore
    private var cachedLocalEngine: LocalReplyEngine?
    private var cachedLocalModelResource: String?
    private let mockEngine = MockReplyEngine()
    private var cancellables = Set<AnyCancellable>()
    private var hasBootstrapped = false
    private let contextWindowSize = 10

    private var templateThreadTitle: String
    private var templateThreadSubtitle: String
    private var templateReplyTargetID: String?

    init(
        scenario: DemoScenario = .weekendPlans,
        settingsStore: AppSettingsStore
    ) {
        self.settingsStore = settingsStore
        self.scenario = scenario
        conversationMode = .template
        draftText = ""
        suggestionSlots = []
        isGenerating = false
        errorMessage = nil
        metrics = nil

        let thread = scenario.makeThread()
        templateThreadTitle = thread.title
        templateThreadSubtitle = thread.subtitle
        templateReplyTargetID = thread.replyTo
        participants = thread.participants
        messages = thread.messages
        activeComposerParticipantID = thread.defaultComposerParticipantID
        draftText = thread.initialDraft ?? ""
        threadToneOverride = ThreadToneOverride(
            profileTone: thread.conversationProfile?.tone
        )
        threadLengthOverride = ThreadLengthOverride(
            profileLength: thread.conversationProfile?.length
        )

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

    var threadTitle: String {
        switch conversationMode {
        case .template:
            templateThreadTitle
        case .simulation:
            "Two-User Simulation"
        }
    }

    var threadSubtitle: String {
        switch conversationMode {
        case .template:
            templateThreadSubtitle
        case .simulation:
            participantSummary
        }
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

    var trailingParticipantID: String? {
        participants.last?.id
    }

    var shouldShowComposerParticipantPicker: Bool {
        participants.count == 2
    }

    var participantSummary: String {
        participants
            .prefix(2)
            .map { displayName(for: $0) }
            .joined(separator: " and ")
    }

    func bootstrapIfNeeded() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        engineStatusText = localEngineForCurrentSettings().statusDescription
        await generateSuggestions()
    }

    func setConversationMode(_ newMode: ConversationMode) {
        guard conversationMode != newMode else { return }
        conversationMode = newMode
        switch newMode {
        case .template:
            applyTemplateScenario(scenario)
        case .simulation:
            seedSimulationConversation()
        }
    }

    func applyScenario(_ newScenario: DemoScenario) {
        scenario = newScenario
        guard conversationMode == .template else { return }
        applyTemplateScenario(newScenario)
    }

    func updateParticipantName(_ name: String, for participantID: String) {
        guard let index = participants.firstIndex(where: { $0.id == participantID }) else {
            return
        }
        participants[index] = Participant(
            id: participants[index].id,
            name: name,
            relationship: participants[index].relationship
        )

        for messageIndex in messages.indices where messages[messageIndex].speakerId == participantID {
            messages[messageIndex] = ChatMessageItem(
                id: messages[messageIndex].id,
                speakerId: messages[messageIndex].speakerId,
                speakerName: displayName(for: participants[index]),
                text: messages[messageIndex].text,
                createdAt: messages[messageIndex].createdAt
            )
        }

        clearSuggestionState()
    }

    func setActiveComposerParticipant(_ participantID: String) {
        guard participants.contains(where: { $0.id == participantID }) else { return }
        activeComposerParticipantID = participantID
        clearSuggestionState()
    }

    func resetSimulationConversation() {
        guard conversationMode == .simulation else { return }
        messages = []
        draftText = ""
        if !participants.contains(where: { $0.id == activeComposerParticipantID }),
           let fallback = participants.last?.id {
            activeComposerParticipantID = fallback
        }
        clearSuggestionState()
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
        guard let sender = participants.first(where: { $0.id == activeComposerParticipantID }) else {
            return
        }

        messages.append(
            ChatMessageItem(
                speakerId: sender.id,
                speakerName: displayName(for: sender),
                text: trimmed,
                createdAt: Date()
            )
        )
        draftText = ""
        clearSuggestionState()
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
        suggestionSlots = SuggestionSlotItem.placeholderSlots(labels: currentSuggestionLabels)
        metrics = nil
        errorMessage = nil
        refreshEngineStatus()
        defer {
            isGenerating = false
            refreshEngineStatus()
        }

        let input = makeConversationInput()
        let appendSuggestion: (Suggestion) -> Void = { [weak self] suggestion in
            guard let self else { return }
            let applySuggestion = {
                if let item = self.normalizeSingleSuggestion(suggestion) {
                    self.replaceSuggestionSlot(with: item)
                }
            }

            if Thread.isMainThread {
                applySuggestion()
            } else {
                DispatchQueue.main.sync {
                    applySuggestion()
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
            if !hasReadySuggestion {
                throw ReplySuggestionEngineError.emptySuggestions
            }
        } catch {
            guard settingsStore.safeDemoModeEnabled,
                  settingsStore.backendMode != .mock else {
                suggestionSlots = []
                metrics = nil
                errorMessage = error.localizedDescription
                return
            }

            suggestionSlots = SuggestionSlotItem.placeholderSlots(labels: currentSuggestionLabels)
            do {
                let metricsResult = try await mockEngine.generateSuggestionsProgressive(
                    input: input,
                    defaultProfile: settingsStore.defaultProfile,
                    onSuggestionReady: appendSuggestion
                )
                metrics = metricsResult
                if !hasReadySuggestion {
                    throw ReplySuggestionEngineError.emptySuggestions
                }
                errorMessage = "Fallback to Mock: \(error.localizedDescription)"
            } catch {
                suggestionSlots = []
                metrics = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    func isTrailingMessage(_ message: ChatMessageItem) -> Bool {
        message.speakerId == trailingParticipantID
    }

    func displayName(for participantID: String) -> String {
        guard let participant = participants.first(where: { $0.id == participantID }) else {
            return participantID
        }
        return displayName(for: participant)
    }

    func currentConversationInput() -> ConversationInput {
        makeConversationInput()
    }

    private var hasReadySuggestion: Bool {
        suggestionSlots.contains { $0.suggestion != nil }
    }

    private var currentSuggestionLabels: [String] {
        makeConversationInput().suggestionThemeSet.labels
    }

    private func applyTemplateScenario(_ scenario: DemoScenario) {
        let thread = scenario.makeThread()
        templateThreadTitle = thread.title
        templateThreadSubtitle = thread.subtitle
        templateReplyTargetID = thread.replyTo
        participants = thread.participants
        messages = thread.messages
        activeComposerParticipantID = thread.defaultComposerParticipantID
        draftText = thread.initialDraft ?? ""
        threadToneOverride = ThreadToneOverride(
            profileTone: thread.conversationProfile?.tone
        )
        threadLengthOverride = ThreadLengthOverride(
            profileLength: thread.conversationProfile?.length
        )
        clearSuggestionState()
    }

    private func seedSimulationConversation() {
        participants = SimulationConversation.makeParticipants()
        messages = []
        draftText = ""
        activeComposerParticipantID = SimulationConversation.rightParticipantID
        clearSuggestionState()
    }

    /// Triggers a background model load for the local engine so the first real generation has no cold-start delay.
    /// No-op when backend is not local, in Xcode Preview, or model is already loaded.
    func warmUpLocalEngineIfNeeded() {
        guard settingsStore.backendMode == .local,
              !settingsStore.isRunningInXcodePreview else { return }
        localEngineForCurrentSettings().warmUp()
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

    private func normalizeSuggestionLabel(_ label: String) -> String {
        let normalized = label
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let themeSet = makeConversationInput().suggestionThemeSet

        switch themeSet {
        case .replyStyles:
            switch normalized {
            case "direct", "clear", "concise", "natural", "normal":
                return "Direct"
            case "friendly", "warm", "kind", "kinder", "polite":
                return "Friendly"
            case "thoughtful", "considerate", "reflective", "like you", "likeyou", "casual":
                return "Thoughtful"
            case "label", "text", "option":
                return "Direct"
            default:
                return label.isEmpty ? "Direct" : label.capitalized
            }
        case .decisionReply:
            switch normalized {
            case "agree", "yes", "accept", "accepted":
                return "Agree"
            case "soft decline", "decline", "no", "pass":
                return "Soft Decline"
            case "delay", "later", "defer", "defer decision", "maybe":
                return "Delay"
            case "label", "text", "option":
                return "Agree"
            default:
                return label.isEmpty ? "Agree" : label.capitalized
            }
        }
    }

    private var resolvedBackendMode: ReplyBackendMode {
        if settingsStore.backendMode == .local,
           settingsStore.isRunningInXcodePreview {
            return .mock
        }
        return settingsStore.backendMode
    }

    private func replaceSuggestionSlot(with item: ReplySuggestionItem) {
        if let index = suggestionSlots.firstIndex(where: { $0.label == item.label }) {
            suggestionSlots[index].state = .ready(item)
            return
        }
        if let index = suggestionSlots.firstIndex(where: { $0.isPlaceholder }) {
            suggestionSlots[index] = SuggestionSlotItem(label: item.label, state: .ready(item))
            return
        }
        suggestionSlots.append(
            SuggestionSlotItem(label: item.label, state: .ready(item))
        )
    }

    private func clearSuggestionState() {
        suggestionSlots = []
        metrics = nil
        errorMessage = nil
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
            selfId: activeComposerParticipantID,
            replyTo: currentReplyTargetID,
            participants: participants.map { participant in
                Participant(
                    id: participant.id,
                    name: displayName(for: participant),
                    isSelf: participant.id == activeComposerParticipantID,
                    relationship: participant.relationship
                )
            }
        )
    }

    private var currentReplyTargetID: String? {
        if participants.count == 2 {
            return participants.first(where: { $0.id != activeComposerParticipantID })?.id
        }
        return templateReplyTargetID
    }

    private func displayName(for participant: Participant) -> String {
        let trimmed = participant.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if participant.id == SimulationConversation.leftParticipantID {
                return "Person 1"
            }
            if participant.id == SimulationConversation.rightParticipantID {
                return "Person 2"
            }
            return participant.id
        }
        return trimmed
    }
}
