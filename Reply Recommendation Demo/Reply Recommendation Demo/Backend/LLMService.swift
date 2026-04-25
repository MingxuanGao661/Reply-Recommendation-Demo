import Foundation
import QuartzCore
import llama

/// Local LLM inference service using llama.cpp (`Vendor/QVAC/llama.xcframework`).
/// Input/output are JSON strings — same format as the Python demo.
final class LLMService {
    private static let backendLifecycleQueue = DispatchQueue(label: "reply-demo.llama-backend-lifecycle")
    private static var isBackendInitialized = false
    private static let logCallback: ggml_log_callback = { _, text, _ in
        guard let text else { return }
        let message = String(cString: text)
        print("[llama] \(message)", terminator: "")
    }

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    /// Native llama.cpp sampler chain (`llama_sampler *` in C).
    private var sampler: UnsafeMutablePointer<llama_sampler>?
    /// Loaded LoRA adapter, if any (`llama_adapter_lora *` in C).
    private var loraAdapter: OpaquePointer?
    private let modelName: String
    private let contextSize: Int32
    /// Token cache for stable prompt prefixes (system + chat template) to reduce repeated tokenization cost.
    private var prefixTokenCache: [String: [llama_token]] = [:]
    private let prefixTokenCacheLimit = 12

    /// User-level defaults per axis (`tone` / `length`). Merged in parallel with `conversation_profile` (see `Profile.mergedForPrompt`).
    var defaultProfile: Profile?

    /// When true with **general** (`replyStyles`) input, use the User-LoRA single-reply prompt and normalize output to one card.
    var inferPersonalLoraGeneralAsPlainText: Bool = false

    // MARK: - Init / Deinit

    init(
        modelPath path: String,
        loraPath: String? = nil,
        loraScale: Float = 1.0,
        contextSize: UInt32 = 2048,
        gpuLayers: Int32 = 999,
        defaultProfile: Profile? = nil,
        temperature: Float = 0.70,
        topK: Int32 = 40,
        topP: Float = 0.90
    ) throws {
        self.defaultProfile = defaultProfile
        let baseName = (path as NSString).lastPathComponent.replacingOccurrences(of: ".gguf", with: "")
        if let loraPath {
            let loraName = (loraPath as NSString).lastPathComponent.replacingOccurrences(of: ".gguf", with: "")
            self.modelName = "\(baseName)+\(loraName)"
        } else {
            self.modelName = baseName
        }
        self.contextSize = Int32(contextSize)

        Self.ensureBackendInitialized()

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = gpuLayers

        let loadedModel = llama_model_load_from_file(path, modelParams)

        guard let loadedModel else {
            throw LLMError.modelLoadFailed(path)
        }
        var ownedModel: OpaquePointer? = loadedModel
        var ownedContext: OpaquePointer?
        var ownedSampler: UnsafeMutablePointer<llama_sampler>?

        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = contextSize
        ctxParams.n_batch = contextSize
#if targetEnvironment(simulator) || targetEnvironment(macCatalyst)
        // Keep batch conservative on Simulator/Catalyst to avoid graph allocation asserts.
        ctxParams.n_batch = min(contextSize, 512)
#endif

        guard let ctx = llama_init_from_model(loadedModel, ctxParams) else {
            if let ownedModel {
                llama_model_free(ownedModel)
            }
            throw LLMError.contextCreateFailed
        }
        ownedContext = ctx

        // Apply LoRA adapter if a path was provided.
        if let loraPath {
            guard let adapter = llama_adapter_lora_init(loadedModel, loraPath) else {
                if let ownedContext {
                    llama_free(ownedContext)
                }
                if let ownedModel {
                    llama_model_free(ownedModel)
                }
                throw LLMError.loraLoadFailed(loraPath)
            }
            self.loraAdapter = adapter
            _ = llama_set_adapter_lora(ctx, adapter, loraScale)
        }

        // Build llama.cpp native sampler chain: top_k → top_p → temperature → dist
        // This runs entirely in C, avoiding per-token Swift loops over the full vocab.
        var sparams = llama_sampler_chain_default_params()
        sparams.no_perf = true
        let chain = llama_sampler_chain_init(sparams)
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(topK))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(topP, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_temp(temperature))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32.random(in: 0 ..< UInt32.max)))
        ownedSampler = chain

        self.model = ownedModel
        self.context = ownedContext
        self.vocab = llama_model_get_vocab(loadedModel)
        self.sampler = ownedSampler
        ownedModel = nil
        ownedContext = nil
        ownedSampler = nil
    }

    deinit {
        if let sampler {
            llama_sampler_free(sampler)
            self.sampler = nil
        }
        if let context {
            // Ensure context no longer references adapter state before teardown.
            llama_clear_adapter_lora(context)
            llama_free(context)
            self.context = nil
        }
        // Do not free LoRA adapter manually here.
        // libllama frees loaded adapters with the owning model.
        if let model {
            llama_model_free(model)
            self.model = nil
        }
        self.vocab = nil
        self.loraAdapter = nil
    }

    // MARK: - Public API

    /// Generate reply suggestions from a JSON input string.
    func generate(inputJSON: String) throws -> (outputJSON: String, metrics: InferenceMetrics) {
        guard let input = ConversationInput.from(json: inputJSON) else {
            throw LLMError.invalidInput
        }
        return try generate(input: input)
    }

    /// Generate reply suggestions from a ConversationInput.
    func generate(input: ConversationInput) throws -> (outputJSON: String, metrics: InferenceMetrics) {
        guard model != nil else { throw LLMError.modelNotLoaded }
        let personalGeneral = inferPersonalLoraGeneralAsPlainText
            && input.suggestionThemeSet == .replyStyles
        let prompt: String
        let tokenLimit: Int
        if personalGeneral {
            prompt = PromptBuilder.buildLlamaPromptPersonalLoraGeneral(
                input: input,
                userDefaultProfile: defaultProfile
            )
            tokenLimit = 160
        } else {
            prompt = PromptBuilder.buildLlamaPrompt(input: input, userDefaultProfile: defaultProfile)
            tokenLimit = 280
        }
        var (outputJSON, metrics) = try generate(prompt: prompt, tokenLimit: tokenLimit)
        if personalGeneral {
            outputJSON = Self.normalizePersonalGeneralJSON(outputJSON)
        }
        return (outputJSON, metrics)
    }

    /// Collapse parser output to a single `Natural` card for general + User LoRA plain-text mode.
    private static func normalizePersonalGeneralJSON(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(SuggestionOutput.self, from: data) else {
            return json
        }
        let first = decoded.suggestions.first { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            ?? decoded.suggestions.first
        guard let pick = first else { return json }
        let text = pick.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return json }
        let wrapped = SuggestionOutput(suggestions: [Suggestion(label: "Natural", text: text)])
        return wrapped.toJSON(prettyPrint: false) ?? json
    }

    /// Generate from a pre-built raw prompt string.
    /// Used by progressive generation to run one tone at a time.
    /// - Parameter tokenLimit: Maximum new tokens to generate. Defaults to 280.
    ///   Pass a small value (e.g. 2) for warm-up calls to trigger Metal shader compilation
    ///   without spending time on full generation.
    func generate(prompt: String, tokenLimit: Int = 280) throws -> (outputJSON: String, metrics: InferenceMetrics) {
        let (rawOutput, metrics) = try generateRaw(prompt: prompt, tokenLimit: tokenLimit)
        let output = OutputParser.parse(raw: rawOutput)
        let outputJSON = output.toJSON() ?? "{\"suggestions\": []}"
        return (outputJSON, metrics)
    }

    /// Generate from a pre-built prompt and return the model text verbatim.
    /// Used by inline completion, where JSON parsing would destroy the continuation.
    func generateRaw(prompt: String, tokenLimit: Int = 280) throws -> (rawOutput: String, metrics: InferenceMetrics) {
        guard model != nil, let context, let vocab, let sampler else {
            throw LLMError.modelNotLoaded
        }

        var metrics = InferenceMetrics(modelName: modelName)

        resetContextMemory(context)

        metrics.memoryBeforeMB = Self.getMemoryMB()
        let startTime = CACurrentMediaTime()

        // Tokenize
        let promptTokens = tokenizePromptWithPrefixCache(prompt: prompt, vocab: vocab)
        guard !promptTokens.isEmpty else {
            throw LLMError.invalidInput
        }
        guard promptTokens.count < Int(contextSize) else {
            throw LLMError.promptTooLong(
                promptTokens: promptTokens.count,
                contextSize: Int(contextSize)
            )
        }
        metrics.promptTokens = promptTokens.count

        // Create and fill batch with prompt tokens
        var batch = llama_batch_init(Int32(promptTokens.count), 0, 1)
        defer { llama_batch_free(batch) }

        batch.n_tokens = Int32(promptTokens.count)
        for i in 0..<promptTokens.count {
            batch.token[i] = promptTokens[i]
            batch.pos[i] = Int32(i)
            batch.n_seq_id[i] = 1
            if let seqIds = batch.seq_id, let seqId = seqIds[i] {
                seqId[0] = 0
            }
            batch.logits[i] = 0
        }
        if batch.n_tokens > 0 {
            batch.logits[Int(batch.n_tokens) - 1] = 1
        }

        // Decode prompt
        guard llama_decode(context, batch) == 0 else {
            throw LLMError.decodeFailed
        }

        // Reset sampler state so each generation starts fresh (no stale repetition context).
        llama_sampler_reset(sampler)

        // Generate tokens using llama.cpp native sampler chain (top_k → top_p → temp → dist).
        // This avoids a per-token Swift loop over the full vocab, which was the main CPU bottleneck.
        let maxNewTokens = min(
            tokenLimit,
            max(0, Int(contextSize) - promptTokens.count)
        )
        var outputTokens: [llama_token] = []
        let eosToken = llama_vocab_eos(vocab)
        var nCur = batch.n_tokens

        for _ in 0..<maxNewTokens {
            // llama_sampler_sample reads logits from the context internally — no Swift logit copy.
            let nextToken = llama_sampler_sample(sampler, context, batch.n_tokens - 1)
            llama_sampler_accept(sampler, nextToken)

            if nextToken == eosToken { break }
            outputTokens.append(nextToken)

            // Prepare single-token batch for next decode step.
            batch.n_tokens = 1
            batch.token[0] = nextToken
            batch.pos[0] = nCur
            batch.n_seq_id[0] = 1
            if let seqIds = batch.seq_id, let seqId = seqIds[0] {
                seqId[0] = 0
            }
            batch.logits[0] = 1
            nCur += 1

            guard llama_decode(context, batch) == 0 else { break }
        }

        let endTime = CACurrentMediaTime()

        // Detokenize
        let rawOutput = detokenize(tokens: outputTokens, vocab: vocab)

        // Fill metrics
        let elapsed = endTime - startTime
        metrics.latencyMs = elapsed * 1000
        metrics.memoryAfterMB = Self.getMemoryMB()
        metrics.memoryDeltaMB = metrics.memoryAfterMB - metrics.memoryBeforeMB
        metrics.tokensGenerated = outputTokens.count
        metrics.totalTokens = promptTokens.count + outputTokens.count
        if elapsed > 0 {
            metrics.tokensPerSec = Double(outputTokens.count) / elapsed
        }

        return (rawOutput, metrics)
    }

    // MARK: - Tokenization

    private func tokenize(text: String, vocab: OpaquePointer) -> [llama_token] {
        let utf8Count = text.utf8.count
        let maxTokens = utf8Count + 16
        var tokens = [llama_token](repeating: 0, count: maxTokens)
        let count = llama_tokenize(vocab, text, Int32(utf8Count), &tokens, Int32(maxTokens), false, true)
        return count > 0 ? Array(tokens.prefix(Int(count))) : []
    }

    private func tokenizePromptWithPrefixCache(prompt: String, vocab: OpaquePointer) -> [llama_token] {
        let userMarkers = [
            "<|start_header_id|>user<|end_header_id|>",
            "<|redacted_start_header_id|>user<|redacted_end_header_id|>",
        ]
        for marker in userMarkers {
            if let range = prompt.range(of: marker) {
                let prefix = String(prompt[..<range.lowerBound])
                let suffix = String(prompt[range.lowerBound...])

                let prefixTokens: [llama_token]
                if let cached = prefixTokenCache[prefix] {
                    prefixTokens = cached
                } else {
                    prefixTokens = tokenize(text: prefix, vocab: vocab)
                    if !prefixTokens.isEmpty {
                        prefixTokenCache[prefix] = prefixTokens
                        trimPrefixTokenCacheIfNeeded()
                    }
                }
                let suffixTokens = tokenize(text: suffix, vocab: vocab)
                return prefixTokens + suffixTokens
            }
        }
        return tokenize(text: prompt, vocab: vocab)
    }

    private func trimPrefixTokenCacheIfNeeded() {
        guard prefixTokenCache.count > prefixTokenCacheLimit else { return }
        if let firstKey = prefixTokenCache.keys.first {
            prefixTokenCache.removeValue(forKey: firstKey)
        }
    }

    private func detokenize(tokens: [llama_token], vocab: OpaquePointer) -> String {
        var result = ""
        var buffer = [CChar](repeating: 0, count: 256)
        for token in tokens {
            let len = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
            if len > 0 {
                buffer[Int(len)] = 0
                result += String(cString: buffer)
            }
        }
        return result
    }

    // MARK: - Memory

    private func resetContextMemory(_ context: OpaquePointer) {
        guard let memory = llama_get_memory(context) else { return }
        llama_memory_clear(memory, true)
    }

    static func getMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / (1024 * 1024) : 0
    }

    private static func ensureBackendInitialized() {
        backendLifecycleQueue.sync {
            if !isBackendInitialized {
                llama_log_set(logCallback, nil)
                llama_backend_init()
                isBackendInitialized = true
            }
        }
    }
}

// MARK: - Errors

enum LLMError: LocalizedError {
    case modelLoadFailed(String)
    case contextCreateFailed
    case modelNotLoaded
    case invalidInput
    case promptTooLong(promptTokens: Int, contextSize: Int)
    case decodeFailed
    case loraLoadFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let path): return "Failed to load model: \(path)"
        case .contextCreateFailed: return "Failed to create llama context"
        case .modelNotLoaded: return "Model not loaded"
        case .invalidInput: return "Invalid JSON input"
        case .promptTooLong(let promptTokens, let contextSize):
            return "Prompt is too long for local inference (\(promptTokens) tokens, max \(contextSize - 1))."
        case .decodeFailed: return "Token decoding failed"
        case .loraLoadFailed(let path): return "Failed to load LoRA adapter: \(path)"
        }
    }
}
