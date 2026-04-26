import Combine
import Foundation

@MainActor
final class ThreadListViewModel: ObservableObject {
    @Published private(set) var threads: [DemoThreadListItem] = []
    @Published var selectedThreadID: UUID?
    @Published private(set) var isLoading = false
    @Published private(set) var isCreatingThread = false
    @Published private(set) var errorMessage: String?

    private let service: DemoChatServiceProtocol
    private var subscriptions: [UUID: DemoChatRealtimeSubscription] = [:]

    init(service: DemoChatServiceProtocol) {
        self.service = service
    }

    var selectedThreadItem: DemoThreadListItem? {
        guard let selectedThreadID else { return threads.first }
        return threads.first { $0.id == selectedThreadID }
    }

    func loadThreads() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let loadedThreads = try await service.fetchThreadList()
            threads = loadedThreads
            errorMessage = nil
        } catch {
            threads = DemoScenario.offlineThreadListItems()
            errorMessage = error.localizedDescription
        }

        if selectedThreadID == nil || !threads.contains(where: { $0.id == selectedThreadID }) {
            selectedThreadID = threads.first?.id
        }
        markSelectedThreadRead()
        await startRealtimeSubscriptions()
    }

    func selectThread(_ threadID: UUID?) {
        selectedThreadID = threadID
        markSelectedThreadRead()
    }

    func createThread(_ draft: DemoNewThreadDraft) async -> Bool {
        guard !isCreatingThread else { return false }
        guard service.isConfigured else {
            errorMessage = DemoChatServiceError.notConfigured.localizedDescription
            return false
        }

        isCreatingThread = true
        defer { isCreatingThread = false }

        do {
            let thread = try await service.createThread(draft)
            threads.append(thread)
            threads.sort { $0.thread.displayOrder < $1.thread.displayOrder }
            selectedThreadID = thread.id
            errorMessage = nil
            await startRealtimeSubscriptions()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func ingest(_ message: DemoChatMessageRecord) {
        guard let index = threads.firstIndex(where: { $0.id == message.threadID }) else { return }

        if let existingIndex = threads[index].messages.firstIndex(where: {
            $0.id == message.id || $0.clientMessageID == message.clientMessageID
        }) {
            threads[index].messages[existingIndex] = message
        } else {
            threads[index].messages.append(message)
        }
        threads[index].messages.sort { $0.createdAt < $1.createdAt }

        if message.threadID == selectedThreadID {
            threads[index].unreadCount = 0
        } else {
            threads[index].unreadCount += 1
        }
    }

    func removeMessage(id messageID: UUID) {
        guard let index = threads.firstIndex(where: { thread in
            thread.messages.contains { $0.id == messageID }
        }) else { return }
        threads[index].messages.removeAll { $0.id == messageID }
        if threads[index].id == selectedThreadID {
            threads[index].unreadCount = 0
        }
    }

    private func markSelectedThreadRead() {
        guard let selectedThreadID,
              let index = threads.firstIndex(where: { $0.id == selectedThreadID }) else { return }
        threads[index].unreadCount = 0
    }

    private func startRealtimeSubscriptions() async {
        subscriptions.values.forEach { $0.cancel() }
        subscriptions = [:]
        guard service.isConfigured else { return }

        for thread in threads {
            let subscription = await service.subscribeToMessages(
                threadID: thread.id,
                onMessage: { [weak self] message in
                    self?.ingest(message)
                },
                onDelete: { [weak self] messageID in
                    self?.removeMessage(id: messageID)
                }
            )
            subscriptions[thread.id] = subscription
        }
    }
}
