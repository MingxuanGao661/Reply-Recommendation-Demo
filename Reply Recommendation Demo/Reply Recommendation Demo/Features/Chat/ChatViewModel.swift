import Combine
import Foundation

@MainActor
final class ChatViewModel: ObservableObject {
    @Published private(set) var messages: [ChatMessageItem]
    @Published private(set) var participants: [Participant]
    @Published var draftText: String
    @Published private(set) var suggestionSlots: [SuggestionSlotItem]
    @Published private(set) var isGenerating: Bool
    @Published private(set) var isLoadingMessages: Bool
    @Published private(set) var isSending: Bool
    @Published private(set) var errorMessage: String?
    @Published private(set) var metrics: InferenceMetrics?
    @Published private(set) var inlineSuggestion: ReplySuggestionItem?
    @Published private(set) var inlineMetrics: InferenceMetrics?
    @Published private(set) var engineStatusText: String
    @Published var threadToneOverride: ThreadToneOverride
    @Published var threadLengthOverride: ThreadLengthOverride
    @Published private(set) var activeComposerParticipantID: String
    @Published var selectedReplyMessageID: UUID?

    let threadID: UUID

    private let thread: DemoChatThreadRecord
    private let settingsStore: AppSettingsStore
    private let chatService: DemoChatServiceProtocol
    private let senderDeviceID: String
    private let onMessageReceived: ((DemoChatMessageRecord) -> Void)?
    private let onMessageDeleted: ((UUID) -> Void)?
    private var realtimeSubscription: DemoChatRealtimeSubscription?
    private var pollingTask: Task<Void, Never>?
    private var cachedLocalEngine: LocalReplyEngine?
    private var cachedLocalModelResource: String?
    /// Fingerprint of bundled vs user LoRA resolution so cache invalidates when either changes.
    private var cachedLocalLoraSignature: String?
    private let mockEngine = MockReplyEngine()
    private var cancellables = Set<AnyCancellable>()
    private var hasBootstrapped = false
    private let contextWindowSize = 7
    private let inlineIdleDelayNs: UInt64 = 200_000_000
    private var inlineDebounceTask: Task<Void, Never>?
    private var inlineRequestGeneration = 0

    init(
        threadItem: DemoThreadListItem? = nil,
        settingsStore: AppSettingsStore,
        chatService: DemoChatServiceProtocol,
        senderDeviceID: String? = nil,
        onMessageReceived: ((DemoChatMessageRecord) -> Void)? = nil,
        onMessageDeleted: ((UUID) -> Void)? = nil
    ) {
        let resolvedThreadItem = threadItem ?? DemoScenario.weekendPlans.offlineThreadListItem()
        self.thread = resolvedThreadItem.thread
        self.threadID = resolvedThreadItem.id
        self.settingsStore = settingsStore
        self.chatService = chatService
        self.senderDeviceID = senderDeviceID ?? settingsStore.demoSenderDeviceID
        self.onMessageReceived = onMessageReceived
        self.onMessageDeleted = onMessageDeleted

        messages = resolvedThreadItem.messages.map(\.chatMessageItem)
        participants = resolvedThreadItem.participants.map(\.participant)
        draftText = resolvedThreadItem.thread.initialDraft ?? ""
        suggestionSlots = []
        isGenerating = false
        isLoadingMessages = false
        isSending = false
        errorMessage = nil
        metrics = nil
        inlineSuggestion = nil
        inlineMetrics = nil
        activeComposerParticipantID = settingsStore.demoComposerParticipantID(for: resolvedThreadItem.id)
            ?? resolvedThreadItem.thread.defaultComposerParticipantID
        threadToneOverride = ThreadToneOverride(
            profileTone: resolvedThreadItem.thread.profileTone
        )
        threadLengthOverride = ThreadLengthOverride(
            profileLength: resolvedThreadItem.thread.profileLength
        )

        let initialModelName = settingsStore.bundledLlamaModel.resourceName
        let initialLora = settingsStore.resolvedLocalLoraConfiguration()
        let initialPersonal = Self.personalGeneralInferenceEnabled(settingsStore: settingsStore)
        let initialLocalEngine = LocalReplyEngine(
            modelResourceName: initialModelName,
            loraResourceName: initialLora.bundledResourceName,
            loraAdapterFilePath: initialLora.userAdapterPath,
            usePersonalLoraGeneralInference: initialPersonal
        )
        cachedLocalEngine = initialLocalEngine
        cachedLocalModelResource = initialModelName
        cachedLocalLoraSignature = Self.localLoraSignature(
            model: initialModelName,
            bundled: initialLora.bundledResourceName,
            userPath: initialLora.userAdapterPath,
            personalGeneral: initialPersonal
        )
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

        settingsStore.$loraAdapterEnabled
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.invalidateLocalEngineCache()
                self.refreshEngineStatus()
            }
            .store(in: &cancellables)

        settingsStore.$userTrainedLoraAdapterEnabled
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.invalidateLocalEngineCache()
                self.refreshEngineStatus()
            }
            .store(in: &cancellables)

        settingsStore.$userTrainedLoraAdapterPath
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.invalidateLocalEngineCache()
                self.refreshEngineStatus()
            }
            .store(in: &cancellables)

        settingsStore.$localInlineCompletionEnabled
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if !enabled {
                    self.inlineDebounceTask?.cancel()
                    self.inlineDebounceTask = nil
                    self.inlineSuggestion = nil
                    self.inlineMetrics = nil
                }
            }
            .store(in: &cancellables)
    }

    private static func localLoraSignature(
        model: String,
        bundled: String?,
        userPath: String?,
        personalGeneral: Bool
    ) -> String {
        "\(model)|\(bundled ?? "-")|\(userPath ?? "-")|pg:\(personalGeneral ? "1" : "0")"
    }

    /// User-trained LoRA is on **and** a valid adapter path is resolved → general threads use single-reply prompts.
    private static func personalGeneralInferenceEnabled(settingsStore: AppSettingsStore) -> Bool {
        let lor = settingsStore.resolvedLocalLoraConfiguration()
        return settingsStore.userTrainedLoraAdapterEnabled && lor.userAdapterPath != nil
    }

    var threadTitle: String { thread.title }
    var threadSubtitle: String { thread.subtitle }

    var backendBadgeText: String {
        resolvedBackendMode.statusBadgeText
    }

    var isLocalBackendSelected: Bool {
        resolvedBackendMode == .local
    }

    var canSendDraft: Bool {
        !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
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
        await loadMessages()
        await subscribeToRealtime()
        startPollingForNewMessages()
        warmUpLocalEngineIfNeeded()
        warmUpInlineLocalEngineIfNeeded()
    }

    func teardown() {
        inlineDebounceTask?.cancel()
        inlineDebounceTask = nil
        realtimeSubscription?.cancel()
        realtimeSubscription = nil
        pollingTask?.cancel()
        pollingTask = nil
    }

    func loadMessages() async {
        guard chatService.isConfigured else {
            errorMessage = DemoChatServiceError.notConfigured.localizedDescription
            return
        }
        isLoadingMessages = true
        defer { isLoadingMessages = false }

        do {
            let records = try await chatService.fetchMessages(threadID: threadID)
            messages = records.map(\.chatMessageItem)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
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
                senderDeviceID: messages[messageIndex].senderDeviceID,
                clientMessageID: messages[messageIndex].clientMessageID,
                isSeeded: messages[messageIndex].isSeeded,
                createdAt: messages[messageIndex].createdAt
            )
        }

        clearSuggestionState()
    }

    func setActiveComposerParticipant(_ participantID: String) {
        guard participants.contains(where: { $0.id == participantID }) else { return }
        activeComposerParticipantID = participantID
        settingsStore.setDemoComposerParticipantID(participantID, for: threadID)
        clearSuggestionState()
    }

    func insertSuggestion(_ suggestion: ReplySuggestionItem) {
        draftText = suggestion.text
        inlineSuggestion = nil
        inlineMetrics = nil
    }

    func acceptInlineSuggestion() {
        guard let inlineSuggestion else { return }
        draftText = inlineSuggestion.text
        self.inlineSuggestion = nil
        self.inlineMetrics = nil
    }

    func clearError() {
        errorMessage = nil
    }

    /// Selects a message as the reply target. Tapping the same message again deselects it.
    func selectReplyTarget(messageID: UUID) {
        selectedReplyMessageID = (selectedReplyMessageID == messageID) ? nil : messageID
    }

    func clearReplyTarget() {
        selectedReplyMessageID = nil
    }

    /// The message currently pinned as the reply target (nil if none selected).
    var selectedReplyMessage: ChatMessageItem? {
        guard let id = selectedReplyMessageID else { return nil }
        return messages.first { $0.id == id }
    }

    func sendDraft() async {
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }
        guard chatService.isConfigured else {
            errorMessage = DemoChatServiceError.notConfigured.localizedDescription
            return
        }
        guard let sender = participants.first(where: { $0.id == activeComposerParticipantID }) else {
            return
        }

        let clientMessageID = UUID()
        let optimistic = DemoChatMessageRecord(
            id: clientMessageID,
            threadID: threadID,
            speakerID: sender.id,
            speakerName: displayName(for: sender),
            content: trimmed,
            senderDeviceID: senderDeviceID,
            clientMessageID: clientMessageID,
            isSeeded: false,
            seedMessageOrder: nil,
            createdAt: Date()
        )

        draftText = ""
        selectedReplyMessageID = nil
        clearSuggestionState()
        mergeMessageRecord(optimistic)
        onMessageReceived?(optimistic)

        isSending = true
        defer { isSending = false }

        do {
            let saved = try await chatService.sendMessage(
                threadID: threadID,
                speakerID: sender.id,
                speakerName: displayName(for: sender),
                text: trimmed,
                senderDeviceID: senderDeviceID,
                clientMessageID: clientMessageID
            )
            mergeMessageRecord(saved)
            onMessageReceived?(saved)
        } catch {
            messages.removeAll { $0.clientMessageID == clientMessageID || $0.id == clientMessageID }
            draftText = trimmed
            errorMessage = error.localizedDescription
        }
    }

    func canDeleteMessage(_ message: ChatMessageItem) -> Bool {
        !message.isSeeded
    }

    func deleteMessage(_ message: ChatMessageItem) async {
        guard canDeleteMessage(message) else { return }

        let removedIndex = messages.firstIndex { $0.id == message.id }
        let removedMessage = removedIndex.map { messages[$0] }
        messages.removeAll { $0.id == message.id }
        if selectedReplyMessageID == message.id {
            selectedReplyMessageID = nil
        }
        clearSuggestionState()
        onMessageDeleted?(message.id)

        guard chatService.isConfigured else {
            if let removedIndex, let removedMessage {
                messages.insert(removedMessage, at: min(removedIndex, messages.count))
            }
            errorMessage = DemoChatServiceError.notConfigured.localizedDescription
            return
        }

        do {
            try await chatService.deleteMessage(messageID: message.id)
            errorMessage = nil
        } catch {
            if let removedIndex, let removedMessage,
               !messages.contains(where: { $0.id == removedMessage.id }) {
                messages.insert(removedMessage, at: min(removedIndex, messages.count))
                messages.sort { $0.createdAt < $1.createdAt }
                onMessageReceived?(
                    DemoChatMessageRecord(
                        id: removedMessage.id,
                        threadID: threadID,
                        speakerID: removedMessage.speakerId,
                        speakerName: removedMessage.speakerName,
                        content: removedMessage.text,
                        senderDeviceID: removedMessage.senderDeviceID,
                        clientMessageID: removedMessage.clientMessageID,
                        isSeeded: removedMessage.isSeeded,
                        seedMessageOrder: nil,
                        createdAt: removedMessage.createdAt
                    )
                )
            }
            errorMessage = error.localizedDescription
        }
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
        inlineDebounceTask?.cancel()
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
        if message.senderDeviceID == senderDeviceID {
            return true
        }
        if message.isSeeded {
            return message.speakerId == activeComposerParticipantID
        }
        return false
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

    /// Triggers a background model load for the local engine so the first real generation has no cold-start delay.
    /// No-op when backend is not local, in Xcode Preview, or model is already loaded.
    func warmUpLocalEngineIfNeeded() {
        guard settingsStore.backendMode == .local,
              !settingsStore.isRunningInXcodePreview else { return }
        localEngineForCurrentSettings().warmUp()
    }

    func warmUpInlineLocalEngineIfNeeded() {
        guard settingsStore.localInlineCompletionEnabled,
              settingsStore.backendMode == .local,
              !settingsStore.isRunningInXcodePreview else { return }
        localEngineForCurrentSettings().warmUp()
    }

    /// The suffix portion of the current inline suggestion that extends beyond the draft.
    /// Used by the UI to render ghost text after the cursor.
    var inlineGhostSuffix: String? {
        guard let suggestion = inlineSuggestion else { return nil }
        let draft = draftText
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let suggText = suggestion.text
        // Case-insensitive prefix match so ghost stays visible even with different capitalisation.
        if suggText.lowercased().hasPrefix(draft.lowercased()) {
            let suffix = String(suggText.dropFirst(draft.count))
            return suffix.isEmpty ? nil : suffix
        }
        return nil
    }

    func scheduleInlineSuggestionGeneration() {
        guard settingsStore.localInlineCompletionEnabled else {
            inlineDebounceTask?.cancel()
            inlineDebounceTask = nil
            inlineSuggestion = nil
            inlineMetrics = nil
            logInlineDebug("skip disabled thread=\(threadID)")
            return
        }
        let trimmedDraft = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDraft.isEmpty else {
            inlineDebounceTask?.cancel()
            inlineSuggestion = nil
            inlineMetrics = nil
            logInlineDebug("skip empty draft thread=\(threadID)")
            return
        }

        // If the existing suggestion is still a valid completion of the new draft,
        // keep it — the ghost suffix updates automatically via the computed property.
        if let existing = inlineSuggestion,
           existing.text.lowercased().hasPrefix(trimmedDraft.lowercased()) {
            logInlineDebug("reuse existing suggestion thread=\(threadID) draftChars=\(trimmedDraft.count)")
            return
        }

        // Draft has diverged from the suggestion. Clear and schedule fresh generation.
        inlineDebounceTask?.cancel()
        inlineRequestGeneration += 1
        let requestGeneration = inlineRequestGeneration
        inlineSuggestion = nil
        inlineMetrics = nil
        guard !isGenerating else {
            logInlineDebug("skip panel generation active thread=\(threadID) draftChars=\(trimmedDraft.count)")
            return
        }

        logInlineDebug("schedule thread=\(threadID) draftChars=\(trimmedDraft.count)")
        inlineDebounceTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: inlineIdleDelayNs)
                guard !Task.isCancelled else { return }
                await generateInlineSuggestion(requestGeneration: requestGeneration)
            } catch {
                return
            }
        }
    }

    func generateInlineSuggestion(requestGeneration: Int? = nil) async {
        guard settingsStore.localInlineCompletionEnabled else { return }
        let trimmedDraft = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDraft.isEmpty else {
            inlineSuggestion = nil
            inlineMetrics = nil
            return
        }
        let input = makeConversationInput()
        let requestedDraft = draftText
        logInlineDebug("generate start thread=\(threadID) draftChars=\(trimmedDraft.count)")

        // Try the primary inline engine first; fall back to mock so the UI always shows
        // something rather than silently failing (e.g. when the local model is not bundled).
        let engines: [any ReplySuggestionEngine] = [resolveInlineEngine(), mockEngine]
        for engine in engines {
            guard !Task.isCancelled else { return }
            do {
                let engineName = String(describing: type(of: engine))
                logInlineDebug("trying engine=\(engineName) thread=\(threadID)")
                let result = try await engine.generateInlineSuggestion(
                    input: input,
                    defaultProfile: settingsStore.defaultProfile
                )
                guard !Task.isCancelled else { return }
                if let requestGeneration,
                   requestGeneration != inlineRequestGeneration {
                    logInlineDebug("discard stale generation thread=\(threadID)")
                    return
                }
                guard draftText == requestedDraft else {
                    logInlineDebug("discard draft changed thread=\(threadID)")
                    return
                }
                if let normalized = normalizeSingleSuggestion(result.suggestion) {
                    guard let suffix = visibleInlineSuffix(for: normalized.text, draft: draftText) else {
                        logInlineDebug(
                            "reject no visible suffix engine=\(engineName) thread=\(threadID) suggestionChars=\(normalized.text.count)"
                        )
                        continue
                    }
                    inlineSuggestion = normalized
                    inlineMetrics = result.metrics
                    logInlineDebug(
                        "accepted engine=\(engineName) thread=\(threadID) latencyMs=\(Int(result.metrics.latencyMs)) suggestionChars=\(normalized.text.count) ghostSuffixChars=\(suffix.count)"
                    )
                    return
                }
                logInlineDebug("normalized empty engine=\(engineName) thread=\(threadID)")
            } catch {
                logInlineDebug("engine failed thread=\(threadID) error=\(error.localizedDescription)")
                // Try next engine in the fallback chain.
                continue
            }
        }
        logInlineDebug("all engines failed thread=\(threadID)")
    }

    private func logInlineDebug(_ message: String) {
        NSLog("[inline-debug] %@", message)
    }

    private func visibleInlineSuffix(for suggestionText: String, draft: String) -> String? {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              suggestionText.lowercased().hasPrefix(draft.lowercased()) else {
            return nil
        }
        let suffix = String(suggestionText.dropFirst(draft.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return suffix.isEmpty ? nil : suffix
    }

    private func subscribeToRealtime() async {
        realtimeSubscription?.cancel()
        realtimeSubscription = await chatService.subscribeToMessages(
            threadID: threadID,
            onMessage: { [weak self] message in
                guard let self else { return }
                self.mergeMessageRecord(message)
            },
            onDelete: { [weak self] messageID in
                guard let self else { return }
                self.removeMessage(id: messageID)
            }
        )
    }

    private func startPollingForNewMessages() {
        pollingTask?.cancel()
        guard chatService.isConfigured else { return }
        pollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                let since = self.messages.last?.createdAt ?? .distantPast
                do {
                    let fresh = try await self.chatService.fetchNewMessages(
                        threadID: self.threadID,
                        since: since
                    )
                    for message in fresh {
                        self.mergeMessageRecord(message)
                    }
                } catch {
                    continue
                }
            }
        }
    }

    private func mergeMessageRecord(_ record: DemoChatMessageRecord) {
        let item = record.chatMessageItem
        if let index = messages.firstIndex(where: {
            $0.id == item.id
                || (item.clientMessageID != nil && $0.clientMessageID == item.clientMessageID)
        }) {
            messages[index] = item
        } else {
            messages.append(item)
        }
        messages.sort { $0.createdAt < $1.createdAt }
    }

    private func removeMessage(id: UUID) {
        messages.removeAll { $0.id == id }
        if selectedReplyMessageID == id {
            selectedReplyMessageID = nil
        }
        clearSuggestionState()
        onMessageDeleted?(id)
    }

    private var hasReadySuggestion: Bool {
        suggestionSlots.contains { $0.suggestion != nil }
    }

    private var currentSuggestionLabels: [String] {
        makeConversationInput().suggestionThemeSet.labels
    }

    private func localEngineForCurrentSettings() -> LocalReplyEngine {
        let name = settingsStore.bundledLlamaModel.resourceName
        let lor = settingsStore.resolvedLocalLoraConfiguration()
        let personal = Self.personalGeneralInferenceEnabled(settingsStore: settingsStore)
        let sig = Self.localLoraSignature(
            model: name,
            bundled: lor.bundledResourceName,
            userPath: lor.userAdapterPath,
            personalGeneral: personal
        )
        if cachedLocalModelResource == name,
           cachedLocalLoraSignature == sig,
           let cached = cachedLocalEngine {
            return cached
        }
        let engine = LocalReplyEngine(
            modelResourceName: name,
            loraResourceName: lor.bundledResourceName,
            loraAdapterFilePath: lor.userAdapterPath,
            usePersonalLoraGeneralInference: personal
        )
        cachedLocalEngine = engine
        cachedLocalModelResource = name
        cachedLocalLoraSignature = sig
        return engine
    }

    private func invalidateLocalEngineCache() {
        inlineDebounceTask?.cancel()
        inlineDebounceTask = nil
        cachedLocalEngine = nil
        cachedLocalModelResource = nil
        cachedLocalLoraSignature = nil
        inlineSuggestion = nil
        inlineMetrics = nil
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

    private func resolveInlineEngine() -> any ReplySuggestionEngine {
        switch settingsStore.backendMode {
        case .mock:
            return mockEngine
        case .local:
            if settingsStore.isRunningInXcodePreview { return mockEngine }
            return localEngineForCurrentSettings()
        case .cloud:
            // Keep inline path on-device for lower latency.
            if settingsStore.isRunningInXcodePreview { return mockEngine }
            return localEngineForCurrentSettings()
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
        inlineSuggestion = nil
        inlineMetrics = nil
        errorMessage = nil
    }

    private func makeConversationInput() -> ConversationInput {
        let windowMessages = messagesForSuggestionContext()
        let conversation = windowMessages.map { message in
            Message(speaker: message.speakerId, text: message.text)
        }

        let explicitTarget: Message?
        if let pinned = selectedReplyMessage {
            explicitTarget = Message(speaker: pinned.speakerId, text: pinned.text)
        } else {
            explicitTarget = nil
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
            },
            explicitReplyTarget: explicitTarget
        )
    }

    /// Rolling context: last `contextWindowSize` messages by default; if a message is pinned as
    /// the reply target, use the `contextWindowSize` messages before that bubble.
    private func messagesForSuggestionContext() -> [ChatMessageItem] {
        if let pinned = selectedReplyMessage,
           let index = messages.firstIndex(where: { $0.id == pinned.id }) {
            guard index > 0 else { return [] }
            return Array(messages[..<index].suffix(contextWindowSize))
        }
        return Array(messages.suffix(contextWindowSize))
    }

    private var currentReplyTargetID: String? {
        if let pinned = selectedReplyMessage {
            return pinned.speakerId
        }
        if participants.count == 2 {
            return participants.first(where: { $0.id != activeComposerParticipantID })?.id
        }
        if let lastOther = messages.last(where: { $0.speakerId != activeComposerParticipantID }) {
            return lastOther.speakerId
        }
        return thread.replyToParticipantID
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
