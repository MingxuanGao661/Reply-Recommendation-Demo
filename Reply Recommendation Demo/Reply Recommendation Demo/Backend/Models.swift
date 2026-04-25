import Foundation

// MARK: - Input

struct Message: Codable {
    let speaker: String   // user ID, e.g. "me", "alice", "bob"
    let text: String
}

struct Participant: Codable {
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

    enum CodingKeys: String, CodingKey {
        case conversation, draft, participants
        case conversationProfile = "conversation_profile"
        case selfId = "self_id"
        case replyTo = "reply_to"
    }

    init(
        conversation: [Message],
        draft: String? = nil,
        conversationProfile: Profile? = nil,
        selfId: String? = nil,
        replyTo: String? = nil,
        participants: [Participant] = []
    ) {
        self.conversation = conversation
        self.draft = draft
        self.conversationProfile = conversationProfile
        self.selfId = selfId
        self.replyTo = replyTo
        self.participants = participants
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

    // MARK: - Parsing

    static func from(json: String) -> ConversationInput? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ConversationInput.self, from: data)
    }

    static func from(data: Data) -> ConversationInput? {
        try? JSONDecoder().decode(ConversationInput.self, from: data)
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
