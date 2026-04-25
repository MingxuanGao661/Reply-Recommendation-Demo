import Foundation

// MARK: - Input

struct Message: Codable {
    let speaker: String   // user ID, e.g. "me", "alice", "bob"
    let text: String
}

struct Participant: Codable, Equatable {
    let id: String
    let name: String
    let isSelf: Bool?
    let relationship: String?

    enum CodingKeys: String, CodingKey {
        case id, name, relationship
        case isSelf = "is_self"
    }

    init(id: String, name: String, isSelf: Bool? = nil, relationship: String? = nil) {
        self.id = id
        self.name = name
        self.isSelf = isSelf
        self.relationship = relationship
    }
}

/// Style preferences (`tone` + `length`). Each field is optional so JSON can specify only one axis.
/// **Merge rule (parallel):** for `tone`, use `conversation_profile.tone` if present, else `defaultProfile.tone`, else `"warm"`. Same pattern for `length` → `"short"`.
struct Profile: Codable, Equatable {
    var tone: String?
    var length: String?

    init(tone: String? = nil, length: String? = nil) {
        self.tone = tone
        self.length = length
    }

    /// Strings ready for the system prompt (after merge or as fallback).
    var resolvedTone: String { tone ?? "warm" }
    var resolvedLength: String { length ?? "short" }

    /// Field-wise merge: conversation and user default fill **different axes** without overriding each other.
    static func mergedForPrompt(conversation: Profile?, userDefault: Profile?) -> Profile {
        let c = conversation
        let u = userDefault
        return Profile(
            tone: c?.tone ?? u?.tone ?? "warm",
            length: c?.length ?? u?.length ?? "short"
        )
    }
}

struct ConversationInput: Codable {
    let conversation: [Message]
    let draft: String?
    /// Per-thread / per-chat (e.g. work vs friends). Persist with the conversation in your app.
    let conversationProfile: Profile?
    let selfId: String?
    let replyTo: String?
    let participants: [Participant]
    /// When the UI pins a specific bubble, pass it here so prompts still quote the right text
    /// even if that message is excluded from the rolling `conversation` window.
    let explicitReplyTarget: Message?

    enum CodingKeys: String, CodingKey {
        case conversation, draft, participants
        case conversationProfile = "conversation_profile"
        case selfId = "self_id"
        case replyTo = "reply_to"
        case explicitReplyTarget = "explicit_reply_target"
    }

    init(
        conversation: [Message],
        draft: String? = nil,
        conversationProfile: Profile? = nil,
        selfId: String? = nil,
        replyTo: String? = nil,
        participants: [Participant] = [],
        explicitReplyTarget: Message? = nil
    ) {
        self.conversation = conversation
        self.draft = draft
        self.conversationProfile = conversationProfile
        self.selfId = selfId
        self.replyTo = replyTo
        self.participants = participants
        self.explicitReplyTarget = explicitReplyTarget
    }

    // MARK: - Resolved Properties

    var resolvedSelfId: String { selfId ?? "me" }

    var resolvedDraft: String {
        (draft ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasDraft: Bool { !resolvedDraft.isEmpty }

    var isGroupChat: Bool {
        let uniqueSpeakers = Set(conversation.map { $0.speaker })
        return uniqueSpeakers.count > 2
    }

    /// Merged profile for the prompt: each of `tone` / `length` is taken from `conversation_profile` if set, else `defaultProfile`, else app default.
    func effectiveProfile(userDefault: Profile?) -> Profile {
        Profile.mergedForPrompt(conversation: conversationProfile, userDefault: userDefault)
    }

    /// Get the display name for a speaker ID.
    func displayName(for speakerId: String) -> String {
        if speakerId == resolvedSelfId { return "Me" }
        if let p = participants.first(where: { $0.id == speakerId }) {
            return p.name
        }
        return speakerId
    }

    var replyTargetName: String? {
        guard let replyTo else { return nil }
        return displayName(for: replyTo)
    }

    var suggestionThemeSet: SuggestionThemeSet {
        SuggestionThemeSet.resolve(for: self)
    }

    var replyTargetMessage: Message? {
        if let explicitReplyTarget {
            return explicitReplyTarget
        }
        if let replyTo,
           let matched = conversation.last(where: { $0.speaker == replyTo }) {
            return matched
        }
        return conversation.last
    }

    // MARK: - Parsing

    static func from(json: String) -> ConversationInput? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ConversationInput.self, from: data)
    }

    static func from(data: Data) -> ConversationInput? {
        try? JSONDecoder().decode(ConversationInput.self, from: data)
    }
}

enum SuggestionThemeSet: Equatable {
    case replyStyles
    case decisionReply

    static let replyStyleLabels = ["Direct", "Friendly", "Thoughtful"]
    static let decisionLabels = ["Agree", "Soft Decline", "Delay"]

    var labels: [String] {
        switch self {
        case .replyStyles:
            Self.replyStyleLabels
        case .decisionReply:
            Self.decisionLabels
        }
    }

    static func resolve(for input: ConversationInput) -> SuggestionThemeSet {
        // When a draft is present the user has already indicated their intent.
        // Decision labels (Agree / Soft Decline / Delay) conflict with draft
        // continuation and cause the model to ignore the draft entirely.
        guard !input.hasDraft else { return .replyStyles }
        return input.shouldUseDecisionThemes ? .decisionReply : .replyStyles
    }
}

private extension ConversationInput {
    var shouldUseDecisionThemes: Bool {
        Self.isBinaryDecisionPrompt(replyTargetMessage?.text ?? "")
    }

    static func isBinaryDecisionPrompt(_ text: String) -> Bool {
        let normalized = text
            .lowercased()
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else { return false }

        let compact = normalized
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        // Phrases that turn a yes/no-prefix question into an open-ended info request.
        // e.g. "can you explain", "could you tell me", "can you help" → NOT a decision.
        let infoRequestVerbs = [
            "explain", "tell me", "tell us", "describe", "clarify", "help me",
            "help us", "show me", "show us", "give me", "give us", "let me know",
            "remind me", "remind us", "suggest", "recommend",
        ]

        let openEndedPrefixes = [
            "what", "when", "where", "why", "how", "which", "who",
        ]
        let yesNoPrefixes = [
            "are", "is", "am", "do", "does", "did", "can", "could", "would", "will",
            "should", "have", "has", "had", "may",
        ]
        let decisionPhrases = [
            // original
            "want to",
            "do you want",
            "would you",
            "could you",
            "can you",
            "are you free",
            "are you available",
            "are you down",
            "still coming",
            "still down",
            "down to",
            "up for",
            "able to",
            "make it",
            "join us",
            "works for you",
            "does that work",
            "does that sound good",
            "is that okay",
            "okay with",
            "good with",
            // casual / abbreviated forms
            "wanna",
            "u down",
            "u in",
            "u coming",
            "you coming",
            "you in",
            "you down",
            "you going",
            "u going",
            "tryna",
            "dtf",          // "down to [hang / go]"
            "you up",
            "u up",
            "coming with",
            "roll with",
            "game for",
            "down for",
            "in for",
            "still on",
            "still good",
            "cool with",
            "fine with",
        ]

        if decisionPhrases.contains(where: { compact.contains($0) }) {
            // "X or Y" choice questions are open-ended, not yes/no — unless "or not"
            if compact.contains(" or ") && !compact.contains(" or not") {
                return false
            }
            // "can you explain / tell me / help me …" are info requests, not decisions
            if infoRequestVerbs.contains(where: { compact.contains($0) }) {
                return false
            }
            return true
        }

        let firstToken = compact
            .split(separator: " ")
            .first
            .map(String.init) ?? ""

        if openEndedPrefixes.contains(firstToken) {
            return false
        }

        if compact.contains(" or ") && !compact.contains(" or not") {
            return false
        }

        guard compact.contains("?") else { return false }

        if yesNoPrefixes.contains(firstToken) {
            // "can you explain / could you tell me …" are info requests even with yes/no prefix
            if infoRequestVerbs.contains(where: { compact.contains($0) }) {
                return false
            }
            return true
        }

        return false
    }
}

// MARK: - Output

struct Suggestion: Codable {
    let label: String
    let text: String
}

struct SuggestionOutput: Codable {
    let suggestions: [Suggestion]

    func toJSON(prettyPrint: Bool = true) -> String? {
        let encoder = JSONEncoder()
        if prettyPrint { encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes] }
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Metrics

struct InferenceMetrics {
    var modelName: String = ""
    var latencyMs: Double = 0
    var memoryBeforeMB: Double = 0
    var memoryAfterMB: Double = 0
    var memoryDeltaMB: Double = 0
    var tokensGenerated: Int = 0
    var tokensPerSec: Double = 0
    var promptTokens: Int = 0
    var totalTokens: Int = 0

    func toDict() -> [String: Any] {
        [
            "model_name": modelName,
            "latency_ms": latencyMs,
            "memory_before_mb": memoryBeforeMB,
            "memory_after_mb": memoryAfterMB,
            "memory_delta_mb": memoryDeltaMB,
            "tokens_generated": tokensGenerated,
            "tokens_per_sec": tokensPerSec,
            "prompt_tokens": promptTokens,
            "total_tokens": totalTokens,
        ]
    }

    var summary: String {
        var lines = [
            "Model:            \(modelName)",
            "Latency:          \(Int(latencyMs)) ms",
            "Memory delta:     \(String(format: "%+.1f", memoryDeltaMB)) MB",
        ]
        if tokensGenerated > 0 {
            lines.append("Tokens generated: \(tokensGenerated)")
            lines.append("Tokens/sec:       \(String(format: "%.1f", tokensPerSec))")
        }
        return lines.joined(separator: "\n")
    }
}
