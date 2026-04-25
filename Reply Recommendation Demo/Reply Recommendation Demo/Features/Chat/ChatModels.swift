import Foundation

enum ConversationMode: String, CaseIterable, Identifiable {
    case template
    case simulation

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .template: return "Template"
        case .simulation: return "Simulation"
        }
    }
}

struct ChatMessageItem: Identifiable, Equatable {
    let id: UUID
    let speakerId: String
    let speakerName: String
    let text: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        speakerId: String,
        speakerName: String,
        text: String,
        createdAt: Date
    ) {
        self.id = id
        self.speakerId = speakerId
        self.speakerName = speakerName
        self.text = text
        self.createdAt = createdAt
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

struct SuggestionSlotItem: Identifiable, Equatable {
    enum State: Equatable {
        case placeholder
        case ready(ReplySuggestionItem)
    }

    static let orderedLabels = ["Natural", "Polite", "Like You"]

    let label: String
    var state: State

    var id: String { label }

    var suggestion: ReplySuggestionItem? {
        guard case .ready(let item) = state else { return nil }
        return item
    }

    var isPlaceholder: Bool {
        if case .placeholder = state {
            return true
        }
        return false
    }

    static func placeholderSlots() -> [SuggestionSlotItem] {
        orderedLabels.map { SuggestionSlotItem(label: $0, state: .placeholder) }
    }
}

struct DemoConversationThread {
    let title: String
    let subtitle: String
    let defaultComposerParticipantID: String
    let replyTo: String
    let initialDraft: String?
    let participants: [Participant]
    let conversationProfile: Profile?
    let messages: [ChatMessageItem]
}

enum DemoScenario: String, CaseIterable, Identifiable {
    case weekendPlans
    case hackathonTeam
    case socialReplyDinner
    case socialReplyLunch
    case socialReplySupport
    case socialReplySlides
    case socialReplyInternship

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .weekendPlans: return "Weekend plans"
        case .hackathonTeam: return "Hackathon team"
        case .socialReplyDinner: return "Dinner timing"
        case .socialReplyLunch: return "Lunch invite"
        case .socialReplySupport: return "Supportive reply"
        case .socialReplySlides: return "Revised slides"
        case .socialReplyInternship: return "Internship news"
        }
    }

    func makeThread(referenceDate: Date = Date()) -> DemoConversationThread {
        switch self {
        case .weekendPlans:
            return DemoConversationThread(
                title: "Alice",
                subtitle: "Coffee catch-up",
                defaultComposerParticipantID: "me",
                replyTo: "alice",
                initialDraft: nil,
                participants: [
                    Participant(id: "alice", name: "Alice", isSelf: false, relationship: "friend"),
                    Participant(id: "me", name: "Me", isSelf: true, relationship: "self"),
                ],
                conversationProfile: Profile(tone: "friendly", length: "short"),
                messages: [
                    ChatMessageItem(
                        speakerId: "alice",
                        speakerName: "Alice",
                        text: "hey! still down to grab coffee this weekend?",
                        createdAt: referenceDate.addingTimeInterval(-540)
                    ),
                    ChatMessageItem(
                        speakerId: "me",
                        speakerName: "Me",
                        text: "yeah definitely, saturday is probably easiest",
                        createdAt: referenceDate.addingTimeInterval(-420)
                    ),
                    ChatMessageItem(
                        speakerId: "alice",
                        speakerName: "Alice",
                        text: "perfect, want to do verve around 11 or somewhere closer to you?",
                        createdAt: referenceDate.addingTimeInterval(-120)
                    ),
                ]
            )

        case .hackathonTeam:
            return DemoConversationThread(
                title: "Demo Squad",
                subtitle: "Hackathon group",
                defaultComposerParticipantID: "me",
                replyTo: "maya",
                initialDraft: nil,
                participants: [
                    Participant(id: "maya", name: "Maya", isSelf: false, relationship: "teammate"),
                    Participant(id: "leo", name: "Leo", isSelf: false, relationship: "teammate"),
                    Participant(id: "me", name: "Me", isSelf: true, relationship: "self"),
                ],
                conversationProfile: Profile(tone: "neutral", length: "medium"),
                messages: [
                    ChatMessageItem(
                        speakerId: "leo",
                        speakerName: "Leo",
                        text: "i pushed the Swift backend conversion and the parser looks okay on my smoke tests",
                        createdAt: referenceDate.addingTimeInterval(-760)
                    ),
                    ChatMessageItem(
                        speakerId: "maya",
                        speakerName: "Maya",
                        text: "nice. can we get the frontend demo flow wired before standup so we can record a backup clip?",
                        createdAt: referenceDate.addingTimeInterval(-500)
                    ),
                    ChatMessageItem(
                        speakerId: "me",
                        speakerName: "Me",
                        text: "i'm on the chat UI now",
                        createdAt: referenceDate.addingTimeInterval(-220)
                    ),
                    ChatMessageItem(
                        speakerId: "maya",
                        speakerName: "Maya",
                        text: "awesome, if local llama is flaky let's keep a mock fallback so the demo doesn't stall",
                        createdAt: referenceDate.addingTimeInterval(-110)
                    ),
                ]
            )

        case .socialReplyDinner:
            return DemoConversationThread(
                title: "Dinner Plan",
                subtitle: "Imported social sample",
                defaultComposerParticipantID: "me",
                replyTo: "other",
                initialDraft: "maybe 20 mins late traffic bad",
                participants: [
                    Participant(id: "other", name: "Other", isSelf: false, relationship: "friend"),
                    Participant(id: "me", name: "Me", isSelf: true, relationship: "self"),
                ],
                conversationProfile: Profile(tone: "warm", length: "short"),
                messages: [
                    ChatMessageItem(
                        speakerId: "other",
                        speakerName: "Other",
                        text: "hey are you still coming to dinner tonight?",
                        createdAt: referenceDate.addingTimeInterval(-540)
                    ),
                    ChatMessageItem(
                        speakerId: "me",
                        speakerName: "Me",
                        text: "yeah i think so",
                        createdAt: referenceDate.addingTimeInterval(-360)
                    ),
                    ChatMessageItem(
                        speakerId: "other",
                        speakerName: "Other",
                        text: "cool, what time should i expect you?",
                        createdAt: referenceDate.addingTimeInterval(-120)
                    ),
                ]
            )

        case .socialReplyLunch:
            return DemoConversationThread(
                title: "Lunch Tomorrow",
                subtitle: "Imported social sample",
                defaultComposerParticipantID: "me",
                replyTo: "other",
                initialDraft: "kind of tired dont really want go",
                participants: [
                    Participant(id: "other", name: "Other", isSelf: false, relationship: "friend"),
                    Participant(id: "me", name: "Me", isSelf: true, relationship: "self"),
                ],
                conversationProfile: Profile(tone: "polite", length: "short"),
                messages: [
                    ChatMessageItem(
                        speakerId: "other",
                        speakerName: "Other",
                        text: "want to grab lunch tomorrow?",
                        createdAt: referenceDate.addingTimeInterval(-540)
                    ),
                    ChatMessageItem(
                        speakerId: "me",
                        speakerName: "Me",
                        text: "maybe, depends on work",
                        createdAt: referenceDate.addingTimeInterval(-360)
                    ),
                    ChatMessageItem(
                        speakerId: "other",
                        speakerName: "Other",
                        text: "no worries, just let me know later tonight",
                        createdAt: referenceDate.addingTimeInterval(-120)
                    ),
                ]
            )

        case .socialReplySupport:
            return DemoConversationThread(
                title: "Checking In",
                subtitle: "Imported social sample",
                defaultComposerParticipantID: "me",
                replyTo: "other",
                initialDraft: "its okay not all your fault",
                participants: [
                    Participant(id: "other", name: "Other", isSelf: false, relationship: "friend"),
                    Participant(id: "me", name: "Me", isSelf: true, relationship: "self"),
                ],
                conversationProfile: Profile(tone: "gentle", length: "medium"),
                messages: [
                    ChatMessageItem(
                        speakerId: "other",
                        speakerName: "Other",
                        text: "i honestly think i messed everything up",
                        createdAt: referenceDate.addingTimeInterval(-540)
                    ),
                    ChatMessageItem(
                        speakerId: "me",
                        speakerName: "Me",
                        text: "what happened?",
                        createdAt: referenceDate.addingTimeInterval(-360)
                    ),
                    ChatMessageItem(
                        speakerId: "other",
                        speakerName: "Other",
                        text: "i said the wrong thing and now everyone is upset with me",
                        createdAt: referenceDate.addingTimeInterval(-120)
                    ),
                ]
            )

        case .socialReplySlides:
            return DemoConversationThread(
                title: "Work Follow-up",
                subtitle: "Imported social sample",
                defaultComposerParticipantID: "me",
                replyTo: "other",
                initialDraft: "yes i can send before 9",
                participants: [
                    Participant(id: "other", name: "Other", isSelf: false, relationship: "coworker"),
                    Participant(id: "me", name: "Me", isSelf: true, relationship: "self"),
                ],
                conversationProfile: Profile(tone: "professional", length: "short"),
                messages: [
                    ChatMessageItem(
                        speakerId: "other",
                        speakerName: "Other",
                        text: "could you send me the revised slides by tonight?",
                        createdAt: referenceDate.addingTimeInterval(-540)
                    ),
                    ChatMessageItem(
                        speakerId: "me",
                        speakerName: "Me",
                        text: "yes, i'm still working on them",
                        createdAt: referenceDate.addingTimeInterval(-360)
                    ),
                    ChatMessageItem(
                        speakerId: "other",
                        speakerName: "Other",
                        text: "thank you, that would really help",
                        createdAt: referenceDate.addingTimeInterval(-120)
                    ),
                ]
            )

        case .socialReplyInternship:
            return DemoConversationThread(
                title: "Big News",
                subtitle: "Imported social sample",
                defaultComposerParticipantID: "me",
                replyTo: "other",
                initialDraft: "thats amazing proud of you",
                participants: [
                    Participant(id: "other", name: "Other", isSelf: false, relationship: "friend"),
                    Participant(id: "me", name: "Me", isSelf: true, relationship: "self"),
                ],
                conversationProfile: Profile(tone: "enthusiastic", length: "short"),
                messages: [
                    ChatMessageItem(
                        speakerId: "other",
                        speakerName: "Other",
                        text: "i got the internship!",
                        createdAt: referenceDate.addingTimeInterval(-540)
                    ),
                    ChatMessageItem(
                        speakerId: "me",
                        speakerName: "Me",
                        text: "no way",
                        createdAt: referenceDate.addingTimeInterval(-360)
                    ),
                    ChatMessageItem(
                        speakerId: "other",
                        speakerName: "Other",
                        text: "yes!! i literally screamed when i saw the email",
                        createdAt: referenceDate.addingTimeInterval(-120)
                    ),
                ]
            )
        }
    }
}

enum SimulationConversation {
    static let leftParticipantID = "sim-left"
    static let rightParticipantID = "sim-right"

    static func makeParticipants() -> [Participant] {
        [
            Participant(id: leftParticipantID, name: "Other", relationship: "friend"),
            Participant(id: rightParticipantID, name: "Me", relationship: "self"),
        ]
    }
}
