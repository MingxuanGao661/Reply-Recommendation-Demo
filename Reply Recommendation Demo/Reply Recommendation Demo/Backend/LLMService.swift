import Foundation
import LlamaSwift
import QuartzCore

/// Local LLM inference service using llama.cpp (via llama.swift SPM).
/// Input/output are JSON strings — same format as the Python demo.
final class LLMService {

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    /// Native llama.cpp sampler chain (`llama_sampler *` in C).
    private var sampler: UnsafeMutablePointer<llama_sampler>?
    /// Loaded LoRA adapter, if any (`llama_adapter_lora *` in C).
    private var loraAdapter: OpaquePointer?
    private let modelName: String
    private let contextSize: Int32

    /// User-level defaults per axis (`tone` / `length`). Merged in parallel with `conversation_profile` (see `Profile.mergedForPrompt`).
    var defaultProfile: Profile?

    // MARK: - Init / Deinit

    init(
        modelPath path: String,
        loraPath: String? = nil,
        loraScale: Float = 1.0,
        contextSize: UInt32 = 2048,
        gpuLayers: Int32 = -1,
        defaultProfile: Profile? = nil
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

        llama_backend_init()

        var modelParams = llama_model_default_params()
#if targetEnvironment(simulator)
        // The iOS Simulator Metal device can fail inside ggml-metal residency-set setup.
        // Keep simulator inference on CPU while preserving GPU offload on physical devices.
        modelParams.n_gpu_layers = 0
#else
        modelParams.n_gpu_layers = gpuLayers
#endif

        guard let loadedModel = llama_model_load_from_file(path, modelParams) else {
            throw LLMError.modelLoadFailed(path)
        }
        self.model = loadedModel
        self.vocab = llama_model_get_vocab(loadedModel)

        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = contextSize
        ctxParams.n_batch = contextSize

        guard let ctx = llama_init_from_model(loadedModel, ctxParams) else {
            llama_model_free(loadedModel)
            throw LLMError.contextCreateFailed
        }
        self.context = ctx

        // Apply LoRA adapter if a path was provided.
        if let loraPath {
            guard let adapter = llama_adapter_lora_init(loadedModel, loraPath) else {
                llama_free(ctx)
                llama_model_free(loadedModel)
                throw LLMError.loraLoadFailed(loraPath)
            }
            self.loraAdapter = adapter
            // llama_set_adapters_lora expects `llama_adapter_lora **` (array of pointers),
            // so we pass a mutable local OpaquePointer? that Swift bridges to the C double-pointer.
            var adapterRef: OpaquePointer? = adapter
            var scale: Float = loraScale
            _ = llama_set_adapters_lora(ctx, &adapterRef, 1, &scale)
        }

        // Build llama.cpp native sampler chain: top_k → top_p → temperature → dist
        // This runs entirely in C, avoiding per-token Swift loops over the full vocab.
        var sparams = llama_sampler_chain_default_params()
        sparams.no_perf = true
        let chain = llama_sampler_chain_init(sparams)
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(40))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(0.90, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_temp(0.70))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32.random(in: 0 ..< UInt32.max)))
        self.sampler = chain
    }

    deinit {
        if let sampler { llama_sampler_free(sampler) }
        if let context { llama_free(context) }
        if let loraAdapter { llama_adapter_lora_free(loraAdapter) }
        if let model { llama_model_free(model) }
        llama_backend_free()
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
        let prompt = PromptBuilder.buildLlamaPrompt(input: input, userDefaultProfile: defaultProfile)
        return try generate(prompt: prompt)
    }

    /// Generate from a pre-built raw prompt string.
    /// Used by progressive generation to run one tone at a time.
    /// - Parameter tokenLimit: Maximum new tokens to generate. Defaults to 280.
    ///   Pass a small value (e.g. 2) for warm-up calls to trigger Metal shader compilation
    ///   without spending time on full generation.
    func generate(prompt: String, tokenLimit: Int = 280) throws -> (outputJSON: String, metrics: InferenceMetrics) {
        guard model != nil, let context, let vocab, let sampler else {
            throw LLMError.modelNotLoaded
        }

        var metrics = InferenceMetrics(modelName: modelName)

        resetContextMemory(context)

        metrics.memoryBeforeMB = Self.getMemoryMB()
        let startTime = CACurrentMediaTime()

        // Tokenize
        let promptTokens = tokenize(text: prompt, vocab: vocab)
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

        // Parse output
        let output = OutputParser.parse(raw: rawOutput)
        let outputJSON = output.toJSON() ?? "{\"suggestions\": []}"

        return (outputJSON, metrics)
    }

    // MARK: - Tokenization

    private func tokenize(text: String, vocab: OpaquePointer) -> [llama_token] {
        let utf8Count = text.utf8.count
        let maxTokens = utf8Count + 16
        var tokens = [llama_token](repeating: 0, count: maxTokens)
        let count = llama_tokenize(vocab, text, Int32(utf8Count), &tokens, Int32(maxTokens), false, true)
        return count > 0 ? Array(tokens.prefix(Int(count))) : []
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
