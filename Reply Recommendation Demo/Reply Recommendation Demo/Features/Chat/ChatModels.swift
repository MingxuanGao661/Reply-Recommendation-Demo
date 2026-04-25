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

    static func placeholderSlots(labels: [String]) -> [SuggestionSlotItem] {
        labels.map { SuggestionSlotItem(label: $0, state: .placeholder) }
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
    // Long-context test scenarios
    case roadTrip
    case movieNight
    case groupHike
    case projectDeadline

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
        case .roadTrip: return "Road trip (12 msgs)"
        case .movieNight: return "Movie night (11 msgs · decision)"
        case .groupHike: return "Group hike (13 msgs · multi)"
        case .projectDeadline: return "Project deadline (12 msgs · multi + draft)"
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

        // MARK: - Long-context test scenarios

        case .roadTrip:
            // Single-person · 12 messages · no draft · normal reply
            return DemoConversationThread(
                title: "Ryan",
                subtitle: "Road trip planning",
                defaultComposerParticipantID: "me",
                replyTo: "ryan",
                initialDraft: nil,
                participants: [
                    Participant(id: "ryan", name: "Ryan", isSelf: false, relationship: "friend"),
                    Participant(id: "me", name: "Me", isSelf: true, relationship: "self"),
                ],
                conversationProfile: Profile(tone: "friendly", length: "medium"),
                messages: [
                    ChatMessageItem(speakerId: "ryan", speakerName: "Ryan",
                        text: "yo you still down for that road trip this weekend?",
                        createdAt: referenceDate.addingTimeInterval(-5400)),
                    ChatMessageItem(speakerId: "me", speakerName: "Me",
                        text: "yeah 100%, been looking forward to it",
                        createdAt: referenceDate.addingTimeInterval(-5200)),
                    ChatMessageItem(speakerId: "ryan", speakerName: "Ryan",
                        text: "nice. i was thinking big sur, you up for that?",
                        createdAt: referenceDate.addingTimeInterval(-5000)),
                    ChatMessageItem(speakerId: "me", speakerName: "Me",
                        text: "big sur is perfect, when were you thinking to leave?",
                        createdAt: referenceDate.addingTimeInterval(-4700)),
                    ChatMessageItem(speakerId: "ryan", speakerName: "Ryan",
                        text: "saturday morning? like 8 or 9 to beat traffic",
                        createdAt: referenceDate.addingTimeInterval(-4400)),
                    ChatMessageItem(speakerId: "me", speakerName: "Me",
                        text: "9:30 is probably better, traffic usually clears by then",
                        createdAt: referenceDate.addingTimeInterval(-4100)),
                    ChatMessageItem(speakerId: "ryan", speakerName: "Ryan",
                        text: "makes sense. you good to drive? my car's been acting up",
                        createdAt: referenceDate.addingTimeInterval(-3700)),
                    ChatMessageItem(speakerId: "me", speakerName: "Me",
                        text: "yeah i can drive, i'll fill up the night before",
                        createdAt: referenceDate.addingTimeInterval(-3300)),
                    ChatMessageItem(speakerId: "ryan", speakerName: "Ryan",
                        text: "legend. i'll handle snacks and the aux then",
                        createdAt: referenceDate.addingTimeInterval(-2800)),
                    ChatMessageItem(speakerId: "me", speakerName: "Me",
                        text: "deal. want to book a campsite or just figure it out when we get there?",
                        createdAt: referenceDate.addingTimeInterval(-2200)),
                    ChatMessageItem(speakerId: "ryan", speakerName: "Ryan",
                        text: "let's book, the good spots fill up fast. i'll look tonight",
                        createdAt: referenceDate.addingTimeInterval(-1500)),
                    ChatMessageItem(speakerId: "ryan", speakerName: "Ryan",
                        text: "oh and should we bring the cooler or just grab stuff down there?",
                        createdAt: referenceDate.addingTimeInterval(-600)),
                ]
            )

        case .movieNight:
            // Single-person · 11 messages · with draft · decision reply
            return DemoConversationThread(
                title: "Sarah",
                subtitle: "Movie night invite",
                defaultComposerParticipantID: "me",
                replyTo: "sarah",
                initialDraft: "probably yeah give me like 20 mins",
                participants: [
                    Participant(id: "sarah", name: "Sarah", isSelf: false, relationship: "friend"),
                    Participant(id: "me", name: "Me", isSelf: true, relationship: "self"),
                ],
                conversationProfile: Profile(tone: "warm", length: "short"),
                messages: [
                    ChatMessageItem(speakerId: "sarah", speakerName: "Sarah",
                        text: "hey are you free tonight?",
                        createdAt: referenceDate.addingTimeInterval(-4800)),
                    ChatMessageItem(speakerId: "me", speakerName: "Me",
                        text: "yeah pretty much, what's up?",
                        createdAt: referenceDate.addingTimeInterval(-4600)),
                    ChatMessageItem(speakerId: "sarah", speakerName: "Sarah",
                        text: "i'm doing a movie night, you should come",
                        createdAt: referenceDate.addingTimeInterval(-4300)),
                    ChatMessageItem(speakerId: "me", speakerName: "Me",
                        text: "what are you watching?",
                        createdAt: referenceDate.addingTimeInterval(-4000)),
                    ChatMessageItem(speakerId: "sarah", speakerName: "Sarah",
                        text: "hereditary lol, maya and ben are coming too",
                        createdAt: referenceDate.addingTimeInterval(-3600)),
                    ChatMessageItem(speakerId: "me", speakerName: "Me",
                        text: "ooh scary movie night nice. where?",
                        createdAt: referenceDate.addingTimeInterval(-3200)),
                    ChatMessageItem(speakerId: "sarah", speakerName: "Sarah",
                        text: "my place, i'm making popcorn and getting snacks",
                        createdAt: referenceDate.addingTimeInterval(-2800)),
                    ChatMessageItem(speakerId: "me", speakerName: "Me",
                        text: "that sounds fun, what time?",
                        createdAt: referenceDate.addingTimeInterval(-2400)),
                    ChatMessageItem(speakerId: "sarah", speakerName: "Sarah",
                        text: "8pm, come a bit earlier to hang before",
                        createdAt: referenceDate.addingTimeInterval(-1800)),
                    ChatMessageItem(speakerId: "me", speakerName: "Me",
                        text: "cool i'll try to make it, still finishing up some stuff",
                        createdAt: referenceDate.addingTimeInterval(-1200)),
                    ChatMessageItem(speakerId: "sarah", speakerName: "Sarah",
                        text: "you coming right? we're starting at 8 and i already made the popcorn 🍿",
                        createdAt: referenceDate.addingTimeInterval(-400)),
                ]
            )

        case .groupHike:
            // Multi-person · 13 messages · no draft · normal reply
            return DemoConversationThread(
                title: "Hiking Crew",
                subtitle: "Weekend hike group",
                defaultComposerParticipantID: "me",
                replyTo: "mia",
                initialDraft: nil,
                participants: [
                    Participant(id: "mia", name: "Mia", isSelf: false, relationship: "friend"),
                    Participant(id: "jake", name: "Jake", isSelf: false, relationship: "friend"),
                    Participant(id: "me", name: "Me", isSelf: true, relationship: "self"),
                ],
                conversationProfile: Profile(tone: "friendly", length: "short"),
                messages: [
                    ChatMessageItem(speakerId: "mia", speakerName: "Mia",
                        text: "ok who's down for a hike this weekend",
                        createdAt: referenceDate.addingTimeInterval(-7200)),
                    ChatMessageItem(speakerId: "jake", speakerName: "Jake",
                        text: "i'm in, what trail are we thinking",
                        createdAt: referenceDate.addingTimeInterval(-6900)),
                    ChatMessageItem(speakerId: "me", speakerName: "Me",
                        text: "same, i've been meaning to do one for a while",
                        createdAt: referenceDate.addingTimeInterval(-6600)),
                    ChatMessageItem(speakerId: "mia", speakerName: "Mia",
                        text: "i was thinking mt tam, the coastal trail is supposed to be incredible",
                        createdAt: referenceDate.addingTimeInterval(-6200)),
                    ChatMessageItem(speakerId: "jake", speakerName: "Jake",
                        text: "yes good call. how long is that trail?",
                        createdAt: referenceDate.addingTimeInterval(-5800)),
                    ChatMessageItem(speakerId: "me", speakerName: "Me",
                        text: "looked it up, the main loop is like 8 miles, not too bad",
                        createdAt: referenceDate.addingTimeInterval(-5400)),
                    ChatMessageItem(speakerId: "mia", speakerName: "Mia",
                        text: "perfect, not too intense. saturday or sunday?",
                        createdAt: referenceDate.addingTimeInterval(-4900)),
                    ChatMessageItem(speakerId: "jake", speakerName: "Jake",
                        text: "saturday is better for me, sunday i have stuff in the evening",
                        createdAt: referenceDate.addingTimeInterval(-4500)),
                    ChatMessageItem(speakerId: "me", speakerName: "Me",
                        text: "saturday works for me too",
                        createdAt: referenceDate.addingTimeInterval(-4000)),
                    ChatMessageItem(speakerId: "mia", speakerName: "Mia",
                        text: "sweet. should we start early before it gets hot, like 8am at the trailhead?",
                        createdAt: referenceDate.addingTimeInterval(-3500)),
                    ChatMessageItem(speakerId: "jake", speakerName: "Jake",
                        text: "8am is early but yeah let's do it lol",
                        createdAt: referenceDate.addingTimeInterval(-3000)),
                    ChatMessageItem(speakerId: "me", speakerName: "Me",
                        text: "agreed, i'll set like three alarms",
                        createdAt: referenceDate.addingTimeInterval(-2400)),
                    ChatMessageItem(speakerId: "mia", speakerName: "Mia",
                        text: "haha same. jake how long is the drive from your place?",
                        createdAt: referenceDate.addingTimeInterval(-900)),
                ]
            )

        case .projectDeadline:
            // Multi-person · 12 messages · with draft · normal reply
            return DemoConversationThread(
                title: "CS 189 Project",
                subtitle: "Final project group",
                defaultComposerParticipantID: "me",
                replyTo: "priya",
                initialDraft: "i can do the intro and lit review",
                participants: [
                    Participant(id: "priya", name: "Priya", isSelf: false, relationship: "teammate"),
                    Participant(id: "daniel", name: "Daniel", isSelf: false, relationship: "teammate"),
                    Participant(id: "me", name: "Me", isSelf: true, relationship: "self"),
                ],
                conversationProfile: Profile(tone: "neutral", length: "short"),
                messages: [
                    ChatMessageItem(speakerId: "priya", speakerName: "Priya",
                        text: "hey team, we need to divide up the project sections this week",
                        createdAt: referenceDate.addingTimeInterval(-6000)),
                    ChatMessageItem(speakerId: "daniel", speakerName: "Daniel",
                        text: "agreed, deadline is next friday right?",
                        createdAt: referenceDate.addingTimeInterval(-5700)),
                    ChatMessageItem(speakerId: "me", speakerName: "Me",
                        text: "yep friday 11:59pm, we should split it up now",
                        createdAt: referenceDate.addingTimeInterval(-5400)),
                    ChatMessageItem(speakerId: "priya", speakerName: "Priya",
                        text: "ok so sections are: data analysis, model writeup, intro/lit review, and conclusion",
                        createdAt: referenceDate.addingTimeInterval(-5000)),
                    ChatMessageItem(speakerId: "daniel", speakerName: "Daniel",
                        text: "i'll take model writeup and results, that's my strongest area",
                        createdAt: referenceDate.addingTimeInterval(-4600)),
                    ChatMessageItem(speakerId: "me", speakerName: "Me",
                        text: "nice, that's the biggest chunk too, appreciate it",
                        createdAt: referenceDate.addingTimeInterval(-4200)),
                    ChatMessageItem(speakerId: "priya", speakerName: "Priya",
                        text: "thank you daniel seriously. i'll take data analysis since i cleaned the dataset",
                        createdAt: referenceDate.addingTimeInterval(-3700)),
                    ChatMessageItem(speakerId: "daniel", speakerName: "Daniel",
                        text: "makes sense, you know where all the edge cases are",
                        createdAt: referenceDate.addingTimeInterval(-3200)),
                    ChatMessageItem(speakerId: "me", speakerName: "Me",
                        text: "solid, so intro/lit review and conclusion are left",
                        createdAt: referenceDate.addingTimeInterval(-2800)),
                    ChatMessageItem(speakerId: "daniel", speakerName: "Daniel",
                        text: "one of those should be pretty light if we outline it first",
                        createdAt: referenceDate.addingTimeInterval(-2200)),
                    ChatMessageItem(speakerId: "priya", speakerName: "Priya",
                        text: "true. conclusion can build off the results section so whoever does that has a head start",
                        createdAt: referenceDate.addingTimeInterval(-1500)),
                    ChatMessageItem(speakerId: "priya", speakerName: "Priya",
                        text: "who wants to take point on each of those two sections?",
                        createdAt: referenceDate.addingTimeInterval(-600)),
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
