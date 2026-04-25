import Foundation
import Realtime
import Supabase

enum DemoChatServiceError: LocalizedError {
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Supabase is missing the SocialDraft anon key. Set SOCIALDRAFT_SUPABASE_ANON_KEY in SupabaseClientProvider."
        }
    }
}

protocol DemoChatServiceProtocol {
    var isConfigured: Bool { get }

    func fetchThreadList() async throws -> [DemoThreadListItem]
    func fetchMessages(threadID: UUID) async throws -> [DemoChatMessageRecord]
    func fetchNewMessages(threadID: UUID, since: Date) async throws -> [DemoChatMessageRecord]
    func sendMessage(
        threadID: UUID,
        speakerID: String,
        speakerName: String,
        text: String,
        senderDeviceID: String,
        clientMessageID: UUID
    ) async throws -> DemoChatMessageRecord
    func subscribeToMessages(
        threadID: UUID,
        onMessage: @escaping (DemoChatMessageRecord) -> Void
    ) async -> DemoChatRealtimeSubscription?
}

final class DemoChatRealtimeSubscription {
    private var cancelHandler: (() -> Void)?

    init(cancelHandler: @escaping () -> Void) {
        self.cancelHandler = cancelHandler
    }

    func cancel() {
        cancelHandler?()
        cancelHandler = nil
    }

    deinit {
        cancel()
    }
}

final class DemoChatService: DemoChatServiceProtocol {
    static let shared = DemoChatService()

    private let client: SupabaseClient
    private let provider: SupabaseClientProvider
    private let decoder = SupabaseJSONCoders.decoder()
    private let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    var isConfigured: Bool { provider.isConfigured }

    init(provider: SupabaseClientProvider = .shared) {
        self.provider = provider
        client = provider.client
    }

    func fetchThreadList() async throws -> [DemoThreadListItem] {
        try requireConfiguration()

        let threadsResponse = try await client
            .from("demo_chat_threads")
            .select("id,scenario_key,display_order,title,subtitle,default_composer_participant_id,reply_to_participant_id,initial_draft,profile_tone,profile_length,created_at,updated_at")
            .order("display_order", ascending: true)
            .execute()
        let threads = try decoder.decode([DemoChatThreadRecord].self, from: threadsResponse.data)
        guard !threads.isEmpty else { return [] }

        let threadIDs = threads.map { $0.id.uuidString }
        let participantsResponse = try await client
            .from("demo_chat_thread_participants")
            .select("id,thread_id,participant_id,display_name,relationship,is_self,sort_order,created_at")
            .in("thread_id", values: threadIDs)
            .order("sort_order", ascending: true)
            .execute()
        let participants = try decoder.decode([DemoChatParticipantRecord].self, from: participantsResponse.data)

        let messagesResponse = try await client
            .from("demo_chat_messages")
            .select("id,thread_id,speaker_id,speaker_name,content,sender_device_id,client_message_id,is_seeded,seed_message_order,created_at")
            .in("thread_id", values: threadIDs)
            .order("created_at", ascending: true)
            .execute()
        let messages = try decoder.decode([DemoChatMessageRecord].self, from: messagesResponse.data)

        let participantsByThread = Dictionary(grouping: participants, by: \.threadID)
        let messagesByThread = Dictionary(grouping: messages, by: \.threadID)

        return threads.map { thread in
            DemoThreadListItem(
                thread: thread,
                participants: participantsByThread[thread.id] ?? [],
                messages: messagesByThread[thread.id] ?? [],
                unreadCount: 0
            )
        }
    }

    func fetchMessages(threadID: UUID) async throws -> [DemoChatMessageRecord] {
        try requireConfiguration()
        let response = try await client
            .from("demo_chat_messages")
            .select("id,thread_id,speaker_id,speaker_name,content,sender_device_id,client_message_id,is_seeded,seed_message_order,created_at")
            .eq("thread_id", value: threadID.uuidString)
            .order("created_at", ascending: true)
            .execute()
        return try decoder.decode([DemoChatMessageRecord].self, from: response.data)
    }

    func fetchNewMessages(threadID: UUID, since: Date) async throws -> [DemoChatMessageRecord] {
        try requireConfiguration()
        let response = try await client
            .from("demo_chat_messages")
            .select("id,thread_id,speaker_id,speaker_name,content,sender_device_id,client_message_id,is_seeded,seed_message_order,created_at")
            .eq("thread_id", value: threadID.uuidString)
            .gt("created_at", value: iso8601.string(from: since))
            .order("created_at", ascending: true)
            .execute()
        return try decoder.decode([DemoChatMessageRecord].self, from: response.data)
    }

    func sendMessage(
        threadID: UUID,
        speakerID: String,
        speakerName: String,
        text: String,
        senderDeviceID: String,
        clientMessageID: UUID
    ) async throws -> DemoChatMessageRecord {
        try requireConfiguration()
        struct NewMessage: Encodable {
            let thread_id: UUID
            let speaker_id: String
            let speaker_name: String
            let content: String
            let sender_device_id: String
            let client_message_id: UUID
        }

        let payload = NewMessage(
            thread_id: threadID,
            speaker_id: speakerID,
            speaker_name: speakerName,
            content: text,
            sender_device_id: senderDeviceID,
            client_message_id: clientMessageID
        )
        let response = try await client
            .from("demo_chat_messages")
            .insert(payload)
            .select("id,thread_id,speaker_id,speaker_name,content,sender_device_id,client_message_id,is_seeded,seed_message_order,created_at")
            .single()
            .execute()
        return try decoder.decode(DemoChatMessageRecord.self, from: response.data)
    }

    func subscribeToMessages(
        threadID: UUID,
        onMessage: @escaping (DemoChatMessageRecord) -> Void
    ) async -> DemoChatRealtimeSubscription? {
        guard isConfigured else { return nil }

        let channel = client.realtimeV2.channel(
            "demo-chat-\(threadID.uuidString)-\(UUID().uuidString)"
        )
        let insertStream = channel.postgresChange(
            InsertAction.self,
            schema: "public",
            table: "demo_chat_messages"
        )

        do {
            try await channel.subscribeWithError()
        } catch {
            return nil
        }

        let task = Task { [decoder] in
            for await insertion in insertStream {
                do {
                    let message = try insertion.decodeRecord(
                        as: DemoChatMessageRecord.self,
                        decoder: decoder
                    )
                    guard message.threadID == threadID else { continue }
                    await MainActor.run {
                        onMessage(message)
                    }
                } catch {
                    continue
                }
            }
        }

        return DemoChatRealtimeSubscription { [client] in
            task.cancel()
            Task {
                await channel.unsubscribe()
                await client.removeChannel(channel)
            }
        }
    }

    private func requireConfiguration() throws {
        guard isConfigured else { throw DemoChatServiceError.notConfigured }
    }
}
