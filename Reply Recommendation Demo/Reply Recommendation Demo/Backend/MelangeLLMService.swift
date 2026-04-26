import Foundation

#if canImport(ZeticMLange)
import ZeticMLange
#endif

enum MelangeLLMError: LocalizedError {
    case sdkUnavailable
    case notLoaded

    var errorDescription: String? {
        switch self {
        case .sdkUnavailable:
            return "ZeticMLange SDK is not linked. Add the package dependency first."
        case .notLoaded:
            return "Melange LLM model is not loaded."
        }
    }
}

/// Wraps Zetic Melange LLM runtime for inline generation.
/// The model is downloaded on first use, then loaded from local cache.
actor MelangeLLMService {
    static let hfModelID = "palm/LFM2.5-1.2B-Instruct"
    static let modelVersion: Int? = 1
    static let inlineTokenLimit = 15

    private let personalKey: String
    private let onDownloadProgress: ((Float) -> Void)?

#if canImport(ZeticMLange)
    private var model: ZeticMLangeLLMModel?
#endif

    init(personalKey: String, onDownloadProgress: ((Float) -> Void)? = nil) {
        self.personalKey = personalKey
        self.onDownloadProgress = onDownloadProgress
    }

    func warmUp() async throws {
#if canImport(ZeticMLange)
        guard model == nil else {
            Self.logDebug("warmup skip alreadyLoaded model=\(Self.hfModelID)")
            return
        }
        Self.logDebug("warmup start model=\(Self.hfModelID) version=\(Self.modelVersion.map(String.init) ?? "nil")")
        model = try ZeticMLangeLLMModel(
            personalKey: personalKey,
            name: Self.hfModelID,
            version: Self.modelVersion,
            modelMode: .RUN_SPEED,
            onDownload: { [onDownloadProgress] progress in
                Self.logDebug("download progress=\(Int(progress * 100))")
                onDownloadProgress?(progress)
            }
        )
        Self.logDebug("warmup complete model=\(Self.hfModelID)")
#else
        Self.logDebug("warmup failed sdkUnavailable")
        throw MelangeLLMError.sdkUnavailable
#endif
    }

    func release() {
#if canImport(ZeticMLange)
        Self.logDebug("release")
        model?.forceDeinit()
        model = nil
#endif
    }

    func generate(
        prompt: String,
        tokenLimit: Int = inlineTokenLimit
    ) async throws -> (output: String, latencyMs: Double, tokensGenerated: Int) {
#if canImport(ZeticMLange)
        if model == nil {
            try await warmUp()
        }
        guard let model else {
            throw MelangeLLMError.notLoaded
        }

        let start = Date()
        Self.logDebug("generate start promptChars=\(prompt.count) tokenLimit=\(tokenLimit)")
        _ = try model.run(prompt)

        var output = ""
        var generated = 0
        while generated < tokenLimit {
            let next = model.waitForNextToken()
            Self.logDebug("token code=\(next.code) generated=\(next.generatedTokens) text=\(Self.preview(next.token))")
            if next.generatedTokens == 0 || next.code == 0 {
                break
            }
            output.append(next.token)
            generated = next.generatedTokens
            if output.contains("\n") {
                break
            }
        }

        try model.cleanUp()
        let latencyMs = Date().timeIntervalSince(start) * 1000
        let oneLine = output.components(separatedBy: "\n").first ?? output
        Self.logDebug(
            "generate complete latencyMs=\(Int(latencyMs)) tokens=\(generated) raw=\(Self.preview(oneLine))"
        )
        return (oneLine, latencyMs, generated)
#else
        Self.logDebug("generate failed sdkUnavailable")
        throw MelangeLLMError.sdkUnavailable
#endif
    }

    private static func logDebug(_ message: String) {
        NSLog("[melange-debug] %@", message)
    }

    private static func preview(_ text: String, limit: Int = 120) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        guard cleaned.count > limit else { return cleaned }
        return String(cleaned.prefix(limit)) + "..."
    }
}
