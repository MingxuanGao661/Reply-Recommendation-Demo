import XCTest
@testable import Reply_Recommendation_Demo

@MainActor
final class ChatViewModelTests: XCTestCase {
    func testThreadListMapsSeededScenarioThreads() async {
        let service = MockDemoChatService(items: DemoScenario.offlineThreadListItems())
        let viewModel = ThreadListViewModel(service: service)

        await viewModel.loadThreads()

        XCTAssertEqual(viewModel.threads.count, DemoScenario.allCases.count)
        XCTAssertEqual(viewModel.threads.first?.thread.scenarioKey, DemoScenario.weekendPlans.rawValue)
        XCTAssertEqual(viewModel.threads.first?.title, "Alice")
        XCTAssertEqual(viewModel.selectedThreadID, viewModel.threads.first?.id)
    }

    func testSupabaseDecoderHandlesPlainAndFractionalTimestamps() throws {
        let threadID = UUID()
        let firstID = UUID()
        let secondID = UUID()
        let json = """
        [
          {
            "id": "\(firstID.uuidString)",
            "thread_id": "\(threadID.uuidString)",
            "speaker_id": "alice",
            "speaker_name": "Alice",
            "content": "plain timestamp",
            "sender_device_id": null,
            "client_message_id": null,
            "is_seeded": true,
            "seed_message_order": 0,
            "created_at": "2026-04-25T00:00:00Z"
          },
          {
            "id": "\(secondID.uuidString)",
            "thread_id": "\(threadID.uuidString)",
            "speaker_id": "me",
            "speaker_name": "Me",
            "content": "fractional timestamp",
            "sender_device_id": "device",
            "client_message_id": null,
            "is_seeded": false,
            "seed_message_order": null,
            "created_at": "2026-04-25T00:00:01.123456Z"
          }
        ]
        """

        let records = try SupabaseJSONCoders.decoder().decode(
            [DemoChatMessageRecord].self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(records.map(\.id), [firstID, secondID])
        XCTAssertEqual(records[1].content, "fractional timestamp")
    }

    func testSendDraftTrimsOptimisticallyAppendsAndDedupesConfirmedMessage() async throws {
        let item = DemoScenario.weekendPlans.offlineThreadListItem()
        let service = MockDemoChatService(items: [item])
        let viewModel = ChatViewModel(
            threadItem: item,
            settingsStore: makeSettingsStore(),
            chatService: service,
            senderDeviceID: "test-device"
        )
        let initialCount = viewModel.messages.count

        viewModel.draftText = "  see you at 11  "
        await viewModel.sendDraft()

        XCTAssertEqual(service.sentTexts, ["see you at 11"])
        XCTAssertEqual(viewModel.draftText, "")
        XCTAssertEqual(viewModel.messages.count, initialCount + 1)
        XCTAssertEqual(viewModel.messages.last?.text, "see you at 11")
        XCTAssertEqual(viewModel.messages.last?.senderDeviceID, "test-device")
        XCTAssertNotEqual(viewModel.messages.last?.id, service.lastClientMessageID)
    }

    func testRealtimeInsertForActiveThreadAppearsOnce() async {
        let item = DemoScenario.weekendPlans.offlineThreadListItem()
        let service = MockDemoChatService(items: [item])
        let viewModel = ChatViewModel(
            threadItem: item,
            settingsStore: makeSettingsStore(),
            chatService: service,
            senderDeviceID: "test-device"
        )
        await viewModel.bootstrapIfNeeded()

        let message = makeMessage(
            threadID: item.id,
            speakerID: "alice",
            speakerName: "Alice",
            content: "realtime hello"
        )
        service.emit(message)
        service.emit(message)

        XCTAssertEqual(viewModel.messages.filter { $0.id == message.id }.count, 1)
    }

    func testRealtimeInsertForInactiveThreadUpdatesThreadListPreview() async {
        let items = [
            DemoScenario.weekendPlans.offlineThreadListItem(),
            DemoScenario.hackathonTeam.offlineThreadListItem(),
        ]
        let service = MockDemoChatService(items: items)
        let viewModel = ThreadListViewModel(service: service)
        await viewModel.loadThreads()

        let inactiveMessage = makeMessage(
            threadID: items[1].id,
            speakerID: "maya",
            speakerName: "Maya",
            content: "inactive thread ping"
        )
        service.emit(inactiveMessage)

        let inactiveThread = viewModel.threads.first { $0.id == items[1].id }
        XCTAssertEqual(inactiveThread?.lastMessage?.content, "inactive thread ping")
        XCTAssertEqual(inactiveThread?.unreadCount, 1)
    }

    func testSmartReplyContextUsesSelectedThreadMessages() {
        let item = DemoScenario.groupHike.offlineThreadListItem()
        let viewModel = ChatViewModel(
            threadItem: item,
            settingsStore: makeSettingsStore(),
            chatService: MockDemoChatService(items: [item])
        )

        let input = viewModel.currentConversationInput()

        XCTAssertEqual(input.selfId, "me")
        XCTAssertEqual(input.replyTo, "mia")
        XCTAssertTrue(input.conversation.suffix(1).contains { $0.text.contains("drive from your place") })
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

    private func makeMessage(
        threadID: UUID,
        speakerID: String,
        speakerName: String,
        content: String
    ) -> DemoChatMessageRecord {
        DemoChatMessageRecord(
            id: UUID(),
            threadID: threadID,
            speakerID: speakerID,
            speakerName: speakerName,
            content: content,
            senderDeviceID: nil,
            clientMessageID: nil,
            isSeeded: false,
            seedMessageOrder: nil,
            createdAt: Date()
        )
    }
}

@MainActor
private final class MockDemoChatService: DemoChatServiceProtocol {
    var isConfigured = true
    var sentTexts: [String] = []
    var lastClientMessageID: UUID?

    private var items: [DemoThreadListItem]
    private var subscriptions: [UUID: [(DemoChatMessageRecord) -> Void]] = [:]

    init(items: [DemoThreadListItem]) {
        self.items = items
    }

    func fetchThreadList() async throws -> [DemoThreadListItem] {
        items
    }

    func fetchMessages(threadID: UUID) async throws -> [DemoChatMessageRecord] {
        items.first { $0.id == threadID }?.messages ?? []
    }

    func fetchNewMessages(threadID: UUID, since: Date) async throws -> [DemoChatMessageRecord] {
        (items.first { $0.id == threadID }?.messages ?? []).filter { $0.createdAt > since }
    }

    func sendMessage(
        threadID: UUID,
        speakerID: String,
        speakerName: String,
        text: String,
        senderDeviceID: String,
        clientMessageID: UUID
    ) async throws -> DemoChatMessageRecord {
        sentTexts.append(text)
        lastClientMessageID = clientMessageID
        let saved = DemoChatMessageRecord(
            id: UUID(),
            threadID: threadID,
            speakerID: speakerID,
            speakerName: speakerName,
            content: text,
            senderDeviceID: senderDeviceID,
            clientMessageID: clientMessageID,
            isSeeded: false,
            seedMessageOrder: nil,
            createdAt: Date().addingTimeInterval(1)
        )
        if let index = items.firstIndex(where: { $0.id == threadID }) {
            items[index].messages.append(saved)
        }
        return saved
    }

    func subscribeToMessages(
        threadID: UUID,
        onMessage: @escaping (DemoChatMessageRecord) -> Void
    ) async -> DemoChatRealtimeSubscription? {
        subscriptions[threadID, default: []].append(onMessage)
        return DemoChatRealtimeSubscription { }
    }

    func emit(_ message: DemoChatMessageRecord) {
        subscriptions[message.threadID]?.forEach { $0(message) }
    }
}
