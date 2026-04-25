import Combine
import Foundation

enum ReplyBackendMode: String, CaseIterable, Identifiable {
    case local
    case cloud
    case mock

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local: return "Local"
        case .cloud: return "Cloud"
        case .mock: return "Mock"
        }
    }

    var statusBadgeText: String {
        switch self {
        case .local: return "On-device"
        case .cloud: return "Cloud"
        case .mock: return "Mock"
        }
    }
}

enum ReplyToneOption: String, CaseIterable, Identifiable {
    case warm
    case neutral
    case friendly
    case formal

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

enum ReplyLengthOption: String, CaseIterable, Identifiable {
    case short
    case medium
    case long

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

enum ThreadToneOverride: String, CaseIterable, Identifiable {
    case inherit
    case warm
    case neutral
    case friendly
    case formal

    var id: String { rawValue }

    var displayName: String {
        self == .inherit ? "Inherit default" : rawValue.capitalized
    }

    var toneValue: String? {
        self == .inherit ? nil : rawValue
    }

    init(profileTone: String?) {
        self = Self(rawValue: profileTone ?? Self.inherit.rawValue) ?? .inherit
    }
}

enum ThreadLengthOverride: String, CaseIterable, Identifiable {
    case inherit
    case short
    case medium
    case long

    var id: String { rawValue }

    var displayName: String {
        self == .inherit ? "Inherit default" : rawValue.capitalized
    }

    var lengthValue: String? {
        self == .inherit ? nil : rawValue
    }

    init(profileLength: String?) {
        self = Self(rawValue: profileLength ?? Self.inherit.rawValue) ?? .inherit
    }
}

enum CloudProviderOption: String, CaseIterable, Identifiable {
    case openai
    case anthropic
    case gemini
    case groq
    case openrouter

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

/// Bundled `.gguf` base names (no extension) — must match files in **Copy Bundle Resources**.
enum BundledLlamaModelOption: String, CaseIterable, Identifiable {
    case instruct1B_Q4 = "Llama-3.2-1B-Instruct-Q4_K_M"
    case instruct3B_Q4 = "Llama-3.2-3B-Instruct-Q4_K_M"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .instruct1B_Q4: return "1B · Q4_K_M (~770 MB)"
        case .instruct3B_Q4: return "3B · Q4_K_M (~1.9 GB)"
        }
    }

    var resourceName: String { rawValue }

    /// Whether this model is compatible with the reply SFT LoRA adapter.
    var supportsReplyLoRA: Bool {
        self == .instruct3B_Q4
    }
}

/// Bundled LoRA adapter `.gguf` names (no extension) — must match files in **Copy Bundle Resources**.
enum BundledLoraAdapterOption: String, CaseIterable, Identifiable {
    case replySFT_v1 = "reply_sft_lora_v1"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .replySFT_v1: return "reply_sft_lora_v1"
        }
    }

    var resourceName: String { rawValue }
}

@MainActor
final class AppSettingsStore: ObservableObject {
    @Published var backendMode: ReplyBackendMode {
        didSet { persist() }
    }

    @Published var defaultTone: ReplyToneOption {
        didSet { persist() }
    }

    @Published var defaultLength: ReplyLengthOption {
        didSet { persist() }
    }

    @Published var cloudProvider: CloudProviderOption {
        didSet { persist() }
    }

    @Published var cloudModelName: String {
        didSet { persist() }
    }

    @Published var cloudAPIKey: String {
        didSet { persist() }
    }

    @Published var safeDemoModeEnabled: Bool {
        didSet { persist() }
    }

    @Published var localTrainingEnabled: Bool {
        didSet { persist() }
    }

    @Published var localTrainingOnboardingCompleted: Bool {
        didSet { persist() }
    }

    @Published var bundledLlamaModel: BundledLlamaModelOption {
        didSet { persist() }
    }

    /// Whether to apply the bundled reply SFT LoRA adapter during local inference.
    /// Only has effect when `bundledLlamaModel` is the 3B model (the only compatible base).
    /// Mutually exclusive with `userTrainedLoraAdapterEnabled`: enabling one turns the other off.
    @Published var loraAdapterEnabled: Bool {
        didSet {
            if loraAdapterEnabled, userTrainedLoraAdapterEnabled {
                userTrainedLoraAdapterEnabled = false
            }
            persist()
        }
    }

    /// When true, local inference loads the adapter at `userTrainedLoraAdapterPath` (sandbox / Application Support path).
    /// **Default bundled LoRA is off** while this is on: enabling User LoRA clears `loraAdapterEnabled` (see `didSet` below).
    @Published var userTrainedLoraAdapterEnabled: Bool {
        didSet {
            if userTrainedLoraAdapterEnabled, loraAdapterEnabled {
                loraAdapterEnabled = false
            }
            persist()
        }
    }

    /// Absolute path to a user-trained LoRA `.gguf` (e.g. `report.outputAdapterPath` from `LLMTrainingService`).
    @Published var userTrainedLoraAdapterPath: String {
        didSet { persist() }
    }

    @Published var lastTrainingFinalLoss: Double? {
        didSet { persist() }
    }

    @Published var lastTrainingDurationMs: Double? {
        didSet { persist() }
    }

    @Published var lastTrainingPeakMemoryMB: Double? {
        didSet { persist() }
    }

    @Published var lastTrainingCompletedAt: Date? {
        didSet { persist() }
    }

    @Published private var demoComposerParticipantIDs: [String: String] {
        didSet { persistDemoComposerParticipantIDs() }
    }

    private let defaults: UserDefaults
    let isRunningInXcodePreview: Bool
    let demoSenderDeviceID: String

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isRunningInXcodePreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
        if let existingID = defaults.string(forKey: Keys.demoSenderDeviceID),
           !existingID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            demoSenderDeviceID = existingID
        } else {
            let newID = UUID().uuidString
            defaults.set(newID, forKey: Keys.demoSenderDeviceID)
            demoSenderDeviceID = newID
        }

        backendMode = ReplyBackendMode(
            rawValue: defaults.string(forKey: Keys.backendMode) ?? ""
        ) ?? .mock
        defaultTone = ReplyToneOption(
            rawValue: defaults.string(forKey: Keys.defaultTone) ?? ""
        ) ?? .warm
        defaultLength = ReplyLengthOption(
            rawValue: defaults.string(forKey: Keys.defaultLength) ?? ""
        ) ?? .short
        cloudProvider = CloudProviderOption(
            rawValue: defaults.string(forKey: Keys.cloudProvider) ?? ""
        ) ?? .openai
        cloudModelName = defaults.string(forKey: Keys.cloudModelName) ?? ""
        cloudAPIKey = defaults.string(forKey: Keys.cloudAPIKey) ?? ""
        safeDemoModeEnabled = defaults.object(forKey: Keys.safeDemoModeEnabled) as? Bool ?? true
        localTrainingEnabled = defaults.object(forKey: Keys.localTrainingEnabled) as? Bool ?? false
        localTrainingOnboardingCompleted = defaults.object(
            forKey: Keys.localTrainingOnboardingCompleted
        ) as? Bool ?? false
        bundledLlamaModel = BundledLlamaModelOption(
            rawValue: defaults.string(forKey: Keys.bundledLlamaModel) ?? ""
        ) ?? .instruct3B_Q4
        loraAdapterEnabled = defaults.object(forKey: Keys.loraAdapterEnabled) as? Bool ?? false
        userTrainedLoraAdapterEnabled = defaults.object(
            forKey: Keys.userTrainedLoraAdapterEnabled
        ) as? Bool ?? false
        userTrainedLoraAdapterPath = defaults.string(forKey: Keys.userTrainedLoraAdapterPath) ?? ""
        lastTrainingFinalLoss = Self.optionalDouble(forKey: Keys.lastTrainingFinalLoss, defaults: defaults)
        lastTrainingDurationMs = Self.optionalDouble(forKey: Keys.lastTrainingDurationMs, defaults: defaults)
        lastTrainingPeakMemoryMB = Self.optionalDouble(forKey: Keys.lastTrainingPeakMemoryMB, defaults: defaults)
        lastTrainingCompletedAt = defaults.object(forKey: Keys.lastTrainingCompletedAt) as? Date
        demoComposerParticipantIDs = Self.loadDemoComposerParticipantIDs(from: defaults)

        if userTrainedLoraAdapterEnabled, loraAdapterEnabled {
            loraAdapterEnabled = false
        }

        if isRunningInXcodePreview {
            backendMode = .mock
            safeDemoModeEnabled = true
        }
    }

    var defaultProfile: Profile {
        Profile(tone: defaultTone.rawValue, length: defaultLength.rawValue)
    }

    /// Resolved LoRA for `LocalReplyEngine`: user-trained path wins when enabled and file exists; otherwise optional bundled adapter.
    func resolvedLocalLoraConfiguration() -> (bundledResourceName: String?, userAdapterPath: String?) {
        let trimmedPath = userTrainedLoraAdapterPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let userOn = userTrainedLoraAdapterEnabled && userTrainedLoraAdapterAvailable
        if userOn {
            return (bundledResourceName: nil, userAdapterPath: trimmedPath)
        }
        let bundledOn = loraAdapterEnabled && bundledLlamaModel.supportsReplyLoRA
        let bundledName = bundledOn ? BundledLoraAdapterOption.replySFT_v1.resourceName : nil
        return (bundledResourceName: bundledName, userAdapterPath: nil)
    }

    var userTrainedLoraAdapterAvailable: Bool {
        let trimmedPath = userTrainedLoraAdapterPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedPath.isEmpty && FileManager.default.fileExists(atPath: trimmedPath)
    }

    var availableBackendModes: [ReplyBackendMode] {
        isRunningInXcodePreview ? [.mock, .cloud] : ReplyBackendMode.allCases
    }

    func demoComposerParticipantID(for threadID: UUID) -> String? {
        demoComposerParticipantIDs[threadID.uuidString]
    }

    func setDemoComposerParticipantID(_ participantID: String, for threadID: UUID) {
        demoComposerParticipantIDs[threadID.uuidString] = participantID
    }

    func recordLocalTrainingReport(_ report: LLMTrainingReport) {
        userTrainedLoraAdapterPath = report.outputAdapterPath
        lastTrainingFinalLoss = report.stepMetrics.last?.loss
        lastTrainingDurationMs = report.durationMs
        lastTrainingPeakMemoryMB = report.peakMemoryMB
        lastTrainingCompletedAt = Date()
    }

    private func persist() {
        guard !isRunningInXcodePreview else { return }
        defaults.set(backendMode.rawValue, forKey: Keys.backendMode)
        defaults.set(defaultTone.rawValue, forKey: Keys.defaultTone)
        defaults.set(defaultLength.rawValue, forKey: Keys.defaultLength)
        defaults.set(cloudProvider.rawValue, forKey: Keys.cloudProvider)
        defaults.set(cloudModelName, forKey: Keys.cloudModelName)
        defaults.set(cloudAPIKey, forKey: Keys.cloudAPIKey)
        defaults.set(safeDemoModeEnabled, forKey: Keys.safeDemoModeEnabled)
        defaults.set(localTrainingEnabled, forKey: Keys.localTrainingEnabled)
        defaults.set(localTrainingOnboardingCompleted, forKey: Keys.localTrainingOnboardingCompleted)
        defaults.set(bundledLlamaModel.rawValue, forKey: Keys.bundledLlamaModel)
        defaults.set(loraAdapterEnabled, forKey: Keys.loraAdapterEnabled)
        defaults.set(userTrainedLoraAdapterEnabled, forKey: Keys.userTrainedLoraAdapterEnabled)
        defaults.set(userTrainedLoraAdapterPath, forKey: Keys.userTrainedLoraAdapterPath)
        Self.persist(lastTrainingFinalLoss, forKey: Keys.lastTrainingFinalLoss, defaults: defaults)
        Self.persist(lastTrainingDurationMs, forKey: Keys.lastTrainingDurationMs, defaults: defaults)
        Self.persist(lastTrainingPeakMemoryMB, forKey: Keys.lastTrainingPeakMemoryMB, defaults: defaults)
        if let lastTrainingCompletedAt {
            defaults.set(lastTrainingCompletedAt, forKey: Keys.lastTrainingCompletedAt)
        } else {
            defaults.removeObject(forKey: Keys.lastTrainingCompletedAt)
        }
    }

    private func persistDemoComposerParticipantIDs() {
        guard !isRunningInXcodePreview else { return }
        guard let data = try? JSONEncoder().encode(demoComposerParticipantIDs) else { return }
        defaults.set(data, forKey: Keys.demoComposerParticipantIDs)
    }

    private static func loadDemoComposerParticipantIDs(from defaults: UserDefaults) -> [String: String] {
        guard let data = defaults.data(forKey: Keys.demoComposerParticipantIDs),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func optionalDouble(forKey key: String, defaults: UserDefaults) -> Double? {
        guard defaults.object(forKey: key) != nil else { return nil }
        return defaults.double(forKey: key)
    }

    private static func persist(_ value: Double?, forKey key: String, defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private enum Keys {
        static let backendMode = "replyDemo.backendMode"
        static let defaultTone = "replyDemo.defaultTone"
        static let defaultLength = "replyDemo.defaultLength"
        static let cloudProvider = "replyDemo.cloudProvider"
        static let cloudModelName = "replyDemo.cloudModelName"
        static let cloudAPIKey = "replyDemo.cloudAPIKey"
        static let safeDemoModeEnabled = "replyDemo.safeDemoModeEnabled"
        static let localTrainingEnabled = "replyDemo.localTrainingEnabled"
        static let localTrainingOnboardingCompleted = "replyDemo.localTrainingOnboardingCompleted"
        static let bundledLlamaModel = "replyDemo.bundledLlamaModel"
        static let loraAdapterEnabled = "replyDemo.loraAdapterEnabled"
        static let userTrainedLoraAdapterEnabled = "replyDemo.userTrainedLoraAdapterEnabled"
        static let userTrainedLoraAdapterPath = "replyDemo.userTrainedLoraAdapterPath"
        static let lastTrainingFinalLoss = "replyDemo.lastTrainingFinalLoss"
        static let lastTrainingDurationMs = "replyDemo.lastTrainingDurationMs"
        static let lastTrainingPeakMemoryMB = "replyDemo.lastTrainingPeakMemoryMB"
        static let lastTrainingCompletedAt = "replyDemo.lastTrainingCompletedAt"
        static let demoSenderDeviceID = "replyDemo.demoSenderDeviceID"
        static let demoComposerParticipantIDs = "replyDemo.demoComposerParticipantIDs"
    }
}
