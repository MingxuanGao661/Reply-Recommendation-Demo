import Foundation

struct ChatMessageItem: Identifiable, Equatable {
    let id: UUID
    let speakerId: String
    let speakerName: String
    let text: String
    let createdAt: Date
    let isSelf: Bool

    init(
        id: UUID = UUID(),
        speakerId: String,
        speakerName: String,
        text: String,
        createdAt: Date,
        isSelf: Bool
    ) {
        self.id = id
        self.speakerId = speakerId
        self.speakerName = speakerName
        self.text = text
        self.createdAt = createdAt
        self.isSelf = isSelf
    }
}

struct ReplySuggestionItem: Identifiable, Equatable {
    let id = UUID()
    let label: String
    let text: String

    init(suggestion: Suggestion) {
        label = suggestion.label
        text = suggestion.text
    }
}

struct DemoConversationThread {
    let title: String
    let subtitle: String
    let selfId: String
    let replyTo: String
    let participants: [Participant]
    let conversationProfile: Profile?
    let messages: [ChatMessageItem]
}

enum DemoScenario: String, CaseIterable, Identifiable {
    case weekendPlans
    case hackathonTeam

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .weekendPlans: return "Weekend plans"
        case .hackathonTeam: return "Hackathon team"
        }
    }

    func makeThread(referenceDate: Date = Date()) -> DemoConversationThread {
        switch self {
        case .weekendPlans:
            return DemoConversationThread(
                title: "Alice",
                subtitle: "Coffee catch-up",
                selfId: "me",
                replyTo: "alice",
                participants: [
                    Participant(id: "me", name: "Me", isSelf: true, relationship: "self"),
                    Participant(id: "alice", name: "Alice", isSelf: false, relationship: "friend"),
                ],
                conversationProfile: Profile(tone: "friendly", length: "short"),
                messages: [
                    ChatMessageItem(
                        speakerId: "alice",
                        speakerName: "Alice",
                        text: "hey! still down to grab coffee this weekend?",
                        createdAt: referenceDate.addingTimeInterval(-540),
                        isSelf: false
                    ),
                    ChatMessageItem(
                        speakerId: "me",
                        speakerName: "Me",
                        text: "yeah definitely, saturday is probably easiest",
                        createdAt: referenceDate.addingTimeInterval(-420),
                        isSelf: true
                    ),
                    ChatMessageItem(
                        speakerId: "alice",
                        speakerName: "Alice",
                        text: "perfect, want to do verve around 11 or somewhere closer to you?",
                        createdAt: referenceDate.addingTimeInterval(-120),
                        isSelf: false
                    ),
                ]
            )

        case .hackathonTeam:
            return DemoConversationThread(
                title: "Demo Squad",
                subtitle: "Hackathon group",
                selfId: "me",
                replyTo: "maya",
                participants: [
                    Participant(id: "me", name: "Me", isSelf: true, relationship: "self"),
                    Participant(id: "maya", name: "Maya", isSelf: false, relationship: "teammate"),
                    Participant(id: "leo", name: "Leo", isSelf: false, relationship: "teammate"),
                ],
                conversationProfile: Profile(tone: "neutral", length: "medium"),
                messages: [
                    ChatMessageItem(
                        speakerId: "leo",
                        speakerName: "Leo",
                        text: "i pushed the Swift backend conversion and the parser looks okay on my smoke tests",
                        createdAt: referenceDate.addingTimeInterval(-760),
                        isSelf: false
                    ),
                    ChatMessageItem(
                        speakerId: "maya",
                        speakerName: "Maya",
                        text: "nice. can we get the frontend demo flow wired before standup so we can record a backup clip?",
                        createdAt: referenceDate.addingTimeInterval(-500),
                        isSelf: false
                    ),
                    ChatMessageItem(
                        speakerId: "me",
                        speakerName: "Me",
                        text: "i'm on the chat UI now",
                        createdAt: referenceDate.addingTimeInterval(-220),
                        isSelf: true
                    ),
                    ChatMessageItem(
                        speakerId: "maya",
                        speakerName: "Maya",
                        text: "awesome, if local llama is flaky let's keep a mock fallback so the demo doesn't stall",
                        createdAt: referenceDate.addingTimeInterval(-110),
                        isSelf: false
                    ),
                ]
            )
        }
    }
}
