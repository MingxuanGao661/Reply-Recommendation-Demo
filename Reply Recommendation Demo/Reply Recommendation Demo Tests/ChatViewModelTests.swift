import XCTest
@testable import Reply_Recommendation_Demo

@MainActor
final class ChatViewModelTests: XCTestCase {
    func testSimulationModeStartsBlankWithTwoParticipants() {
        let viewModel = ChatViewModel(settingsStore: makeSettingsStore())

        viewModel.setConversationMode(.simulation)

        XCTAssertEqual(viewModel.conversationMode, .simulation)
        XCTAssertEqual(viewModel.messages, [])
        XCTAssertEqual(
            viewModel.participants.map(\.id),
            [
                SimulationConversation.leftParticipantID,
                SimulationConversation.rightParticipantID,
            ]
        )
        XCTAssertEqual(
            viewModel.activeComposerParticipantID,
            SimulationConversation.rightParticipantID
        )
    }

    func testTemplateScenariosStillSeedExistingThreads() {
        let viewModel = ChatViewModel(settingsStore: makeSettingsStore())

        XCTAssertEqual(viewModel.conversationMode, .template)
        XCTAssertEqual(viewModel.scenario, .weekendPlans)
        XCTAssertEqual(viewModel.messages.count, 3)
        XCTAssertEqual(viewModel.threadTitle, "Alice")

        viewModel.applyScenario(.hackathonTeam)

        XCTAssertEqual(viewModel.scenario, .hackathonTeam)
        XCTAssertEqual(viewModel.messages.count, 4)
        XCTAssertEqual(viewModel.threadTitle, "Demo Squad")
        XCTAssertEqual(viewModel.participants.count, 3)
    }

    func testSwitchingActiveComposerUpdatesConversationInputAndOutgoingMessages() {
        let viewModel = ChatViewModel(settingsStore: makeSettingsStore())

        viewModel.setConversationMode(.simulation)
        viewModel.setActiveComposerParticipant(SimulationConversation.leftParticipantID)

        var input = viewModel.currentConversationInput()
        XCTAssertEqual(input.selfId, SimulationConversation.leftParticipantID)
        XCTAssertEqual(input.replyTo, SimulationConversation.rightParticipantID)

        viewModel.draftText = "I'll take the left side."
        viewModel.sendDraft()

        XCTAssertEqual(
            viewModel.messages.last?.speakerId,
            SimulationConversation.leftParticipantID
        )

        viewModel.setActiveComposerParticipant(SimulationConversation.rightParticipantID)
        input = viewModel.currentConversationInput()
        XCTAssertEqual(input.selfId, SimulationConversation.rightParticipantID)
        XCTAssertEqual(input.replyTo, SimulationConversation.leftParticipantID)
    }

    func testGenerateSuggestionsSeedsPlaceholdersThenResolvesSlots() async {
        let viewModel = ChatViewModel(settingsStore: makeSettingsStore())

        let generationTask = Task {
            await viewModel.generateSuggestions()
        }

        await Task.yield()

        XCTAssertEqual(
            viewModel.suggestionSlots.map(\.label),
            SuggestionThemeSet.replyStyleLabels
        )
        XCTAssertTrue(viewModel.suggestionSlots.allSatisfy { $0.isPlaceholder })

        await generationTask.value

        XCTAssertEqual(viewModel.suggestionSlots.count, 3)
        XCTAssertTrue(viewModel.suggestionSlots.allSatisfy { $0.suggestion != nil })
    }

    func testDecisionQuestionsUseAgreeDeclineDelaySlots() async {
        let viewModel = ChatViewModel(settingsStore: makeSettingsStore())

        viewModel.setConversationMode(.simulation)
        viewModel.setActiveComposerParticipant(SimulationConversation.leftParticipantID)
        viewModel.draftText = "are you free for dinner tonight?"
        viewModel.sendDraft()
        viewModel.setActiveComposerParticipant(SimulationConversation.rightParticipantID)

        let generationTask = Task {
            await viewModel.generateSuggestions()
        }

        await Task.yield()

        XCTAssertEqual(
            viewModel.suggestionSlots.map(\.label),
            SuggestionThemeSet.decisionLabels
        )

        await generationTask.value

        XCTAssertEqual(
            viewModel.suggestionSlots.map(\.label),
            SuggestionThemeSet.decisionLabels
        )
        XCTAssertTrue(viewModel.suggestionSlots.allSatisfy { $0.suggestion != nil })
    }

    private func makeSettingsStore() -> AppSettingsStore {
        let suiteName = "ChatViewModelTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create isolated test defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)

        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.backendMode = .mock
        settingsStore.safeDemoModeEnabled = true
        return settingsStore
    }
}
