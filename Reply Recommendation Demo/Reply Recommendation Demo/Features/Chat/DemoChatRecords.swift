import Foundation

struct DemoChatThreadRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let scenarioKey: String
    let displayOrder: Int
    let title: String
    let subtitle: String
    let defaultComposerParticipantID: String
    let replyToParticipantID: String?
    let initialDraft: String?
    let profileTone: String?
    let profileLength: String?
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case scenarioKey = "scenario_key"
        case displayOrder = "display_order"
        case title
        case subtitle
        case defaultComposerParticipantID = "default_composer_participant_id"
        case replyToParticipantID = "reply_to_participant_id"
        case initialDraft = "initial_draft"
        case profileTone = "profile_tone"
        case profileLength = "profile_length"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct DemoChatParticipantRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let threadID: UUID
    let participantID: String
    let displayName: String
    let relationship: String?
    let isSelf: Bool
    let sortOrder: Int
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case threadID = "thread_id"
        case participantID = "participant_id"
        case displayName = "display_name"
        case relationship
        case isSelf = "is_self"
        case sortOrder = "sort_order"
        case createdAt = "created_at"
    }

    var participant: Participant {
        Participant(
            id: participantID,
            name: displayName,
            isSelf: isSelf,
            relationship: relationship
        )
    }
}

struct DemoChatMessageRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let threadID: UUID
    let speakerID: String
    let speakerName: String
    let content: String
    let senderDeviceID: String?
    let clientMessageID: UUID?
    let isSeeded: Bool
    let seedMessageOrder: Int?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case threadID = "thread_id"
        case speakerID = "speaker_id"
        case speakerName = "speaker_name"
        case content
        case senderDeviceID = "sender_device_id"
        case clientMessageID = "client_message_id"
        case isSeeded = "is_seeded"
        case seedMessageOrder = "seed_message_order"
        case createdAt = "created_at"
    }

    var chatMessageItem: ChatMessageItem {
        ChatMessageItem(
            id: id,
            speakerId: speakerID,
            speakerName: speakerName,
            text: content,
            senderDeviceID: senderDeviceID,
            clientMessageID: clientMessageID,
            isSeeded: isSeeded,
            createdAt: createdAt
        )
    }
}

struct DemoThreadListItem: Identifiable, Equatable {
    let thread: DemoChatThreadRecord
    let participants: [DemoChatParticipantRecord]
    var messages: [DemoChatMessageRecord]
    var unreadCount: Int

    var id: UUID { thread.id }

    var lastMessage: DemoChatMessageRecord? {
        messages.max { $0.createdAt < $1.createdAt }
    }

    var title: String { thread.title }
    var subtitle: String { thread.subtitle }

    func replacingMessages(_ newMessages: [DemoChatMessageRecord]) -> DemoThreadListItem {
        var copy = self
        copy.messages = newMessages.sorted { $0.createdAt < $1.createdAt }
        return copy
    }
}

struct DemoNewThreadParticipant: Equatable {
    let participantID: String
    let displayName: String
    let relationship: String?
    let isSelf: Bool
}

struct DemoNewThreadDraft: Equatable {
    let title: String
    let subtitle: String
    let defaultComposerParticipantID: String
    let replyToParticipantID: String?
    let participants: [DemoNewThreadParticipant]
}

extension DemoScenario {
    var offlineThreadID: UUID {
        switch self {
        case .weekendPlans: return UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        case .hackathonTeam: return UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        case .socialReplyDinner: return UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        case .socialReplyLunch: return UUID(uuidString: "10000000-0000-0000-0000-000000000004")!
        case .socialReplySupport: return UUID(uuidString: "10000000-0000-0000-0000-000000000005")!
        case .socialReplySlides: return UUID(uuidString: "10000000-0000-0000-0000-000000000006")!
        case .socialReplyInternship: return UUID(uuidString: "10000000-0000-0000-0000-000000000007")!
        case .roadTrip: return UUID(uuidString: "10000000-0000-0000-0000-000000000008")!
        case .movieNight: return UUID(uuidString: "10000000-0000-0000-0000-000000000009")!
        case .groupHike: return UUID(uuidString: "10000000-0000-0000-0000-000000000010")!
        case .projectDeadline: return UUID(uuidString: "10000000-0000-0000-0000-000000000011")!
        }
    }

    func offlineThreadListItem(referenceDate: Date = Date(timeIntervalSince1970: 1_776_739_200)) -> DemoThreadListItem {
        let sourceThread = makeThread(referenceDate: referenceDate)
        let threadID = offlineThreadID
        let threadRecord = DemoChatThreadRecord(
            id: threadID,
            scenarioKey: rawValue,
            displayOrder: Self.allCases.firstIndex(of: self) ?? 0,
            title: sourceThread.title,
            subtitle: sourceThread.subtitle,
            defaultComposerParticipantID: sourceThread.defaultComposerParticipantID,
            replyToParticipantID: sourceThread.replyTo,
            initialDraft: sourceThread.initialDraft,
            profileTone: sourceThread.conversationProfile?.tone,
            profileLength: sourceThread.conversationProfile?.length,
            createdAt: referenceDate,
            updatedAt: referenceDate
        )
        let participantRecords = sourceThread.participants.enumerated().map { index, participant in
            DemoChatParticipantRecord(
                id: UUID(uuidString: String(format: "20000000-0000-0000-0000-%012d", displayOrderSeed * 100 + index)) ?? UUID(),
                threadID: threadID,
                participantID: participant.id,
                displayName: participant.name,
                relationship: participant.relationship,
                isSelf: participant.isSelf ?? (participant.id == sourceThread.defaultComposerParticipantID),
                sortOrder: index,
                createdAt: referenceDate
            )
        }
        let messageRecords = sourceThread.messages.enumerated().map { index, message in
            DemoChatMessageRecord(
                id: UUID(uuidString: String(format: "30000000-0000-0000-0000-%012d", displayOrderSeed * 100 + index)) ?? UUID(),
                threadID: threadID,
                speakerID: message.speakerId,
                speakerName: message.speakerName,
                content: message.text,
                senderDeviceID: nil,
                clientMessageID: nil,
                isSeeded: true,
                seedMessageOrder: index,
                createdAt: message.createdAt
            )
        }
        return DemoThreadListItem(
            thread: threadRecord,
            participants: participantRecords,
            messages: messageRecords,
            unreadCount: 0
        )
    }

    private var displayOrderSeed: Int {
        (Self.allCases.firstIndex(of: self) ?? 0) + 1
    }

    static func offlineThreadListItems() -> [DemoThreadListItem] {
        allCases.map { $0.offlineThreadListItem() }
    }
}
