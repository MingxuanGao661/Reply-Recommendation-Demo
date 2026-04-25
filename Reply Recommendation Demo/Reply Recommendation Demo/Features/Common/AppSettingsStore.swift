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
    case instruct1B_Q8 = "Llama-3.2-1B-Instruct-Q8_0"
    case instruct3B_Q4 = "Llama-3.2-3B-Instruct-Q4_K_M"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .instruct1B_Q4: return "1B · Q4_K_M (~770 MB)"
        case .instruct1B_Q8: return "1B · Q8_0 (~1.2 GB)"
        case .instruct3B_Q4: return "3B · Q4_K_M (~1.9 GB)"
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

    @Published var bundledLlamaModel: BundledLlamaModelOption {
        didSet { persist() }
    }

    private let defaults: UserDefaults
    let isRunningInXcodePreview: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isRunningInXcodePreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"

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
        bundledLlamaModel = BundledLlamaModelOption(
            rawValue: defaults.string(forKey: Keys.bundledLlamaModel) ?? ""
        ) ?? .instruct3B_Q4

        if isRunningInXcodePreview {
            backendMode = .mock
            safeDemoModeEnabled = true
        }
    }

    var defaultProfile: Profile {
        Profile(tone: defaultTone.rawValue, length: defaultLength.rawValue)
    }

    var availableBackendModes: [ReplyBackendMode] {
        isRunningInXcodePreview ? [.mock, .cloud] : ReplyBackendMode.allCases
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
        defaults.set(bundledLlamaModel.rawValue, forKey: Keys.bundledLlamaModel)
    }

    private enum Keys {
        static let backendMode = "replyDemo.backendMode"
        static let defaultTone = "replyDemo.defaultTone"
        static let defaultLength = "replyDemo.defaultLength"
        static let cloudProvider = "replyDemo.cloudProvider"
        static let cloudModelName = "replyDemo.cloudModelName"
        static let cloudAPIKey = "replyDemo.cloudAPIKey"
        static let safeDemoModeEnabled = "replyDemo.safeDemoModeEnabled"
        static let bundledLlamaModel = "replyDemo.bundledLlamaModel"
    }
}
