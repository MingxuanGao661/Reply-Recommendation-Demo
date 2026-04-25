import Foundation
import LlamaSwift
import QuartzCore

/// Local LLM inference service using llama.cpp (via llama.swift SPM).
/// Input/output are JSON strings — same format as the Python demo.
final class LLMService {

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    private let modelName: String
    private let batchSize: Int32 = 512

    /// User-level defaults per axis (`tone` / `length`). Merged in parallel with `conversation_profile` (see `Profile.mergedForPrompt`).
    var defaultProfile: Profile?

    // MARK: - Init / Deinit

    init(
        modelPath path: String,
        contextSize: UInt32 = 2048,
        gpuLayers: Int32 = -1,
        defaultProfile: Profile? = nil
    ) throws {
        self.defaultProfile = defaultProfile
        self.modelName = (path as NSString).lastPathComponent.replacingOccurrences(of: ".gguf", with: "")

        llama_backend_init()

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = gpuLayers

        guard let loadedModel = llama_model_load_from_file(path, modelParams) else {
            throw LLMError.modelLoadFailed(path)
        }
        self.model = loadedModel
        self.vocab = llama_model_get_vocab(loadedModel)

        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = contextSize
        ctxParams.n_batch = UInt32(batchSize)

        guard let ctx = llama_init_from_model(loadedModel, ctxParams) else {
            llama_model_free(loadedModel)
            throw LLMError.contextCreateFailed
        }
        self.context = ctx
    }

    deinit {
        if let context { llama_free(context) }
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
        guard let model, let context, let vocab else {
            throw LLMError.modelNotLoaded
        }

        let prompt = PromptBuilder.buildLlamaPrompt(input: input, userDefaultProfile: defaultProfile)
        var metrics = InferenceMetrics(modelName: modelName)

        metrics.memoryBeforeMB = Self.getMemoryMB()
        let startTime = CACurrentMediaTime()

        // Tokenize
        let promptTokens = tokenize(text: prompt, vocab: vocab)
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

        // Generate tokens
        let maxNewTokens = 512
        var outputTokens: [llama_token] = []
        let eosToken = llama_vocab_eos(vocab)
        let vocabSize = Int(llama_vocab_n_tokens(vocab))
        var nCur = batch.n_tokens

        for _ in 0..<maxNewTokens {
            guard let logits = llama_get_logits_ith(context, batch.n_tokens - 1) else { break }

            // Temperature sampling (temperature = 0.7)
            let nextToken = sampleWithTemperature(logits: logits, vocabSize: vocabSize, temperature: 0.7)

            if nextToken == eosToken { break }
            outputTokens.append(nextToken)

            // Prepare batch for next token
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

    // MARK: - Sampling

    /// Temperature sampling: apply temperature scaling, softmax, then random pick
    private func sampleWithTemperature(logits: UnsafeMutablePointer<Float>, vocabSize: Int, temperature: Float) -> llama_token {
        if temperature <= 0 {
            // Greedy: pick highest logit
            var maxLogit = logits[0]
            var bestToken: llama_token = 0
            for i in 1..<vocabSize {
                if logits[i] > maxLogit {
                    maxLogit = logits[i]
                    bestToken = llama_token(i)
                }
            }
            return bestToken
        }

        // Apply temperature
        var scaled = [Float](repeating: 0, count: vocabSize)
        for i in 0..<vocabSize {
            scaled[i] = logits[i] / temperature
        }

        // Softmax
        let maxVal = scaled.max() ?? 0
        var expSum: Float = 0
        for i in 0..<vocabSize {
            scaled[i] = exp(scaled[i] - maxVal)
            expSum += scaled[i]
        }
        for i in 0..<vocabSize {
            scaled[i] /= expSum
        }

        // Random weighted pick
        let r = Float.random(in: 0..<1)
        var cumulative: Float = 0
        for i in 0..<vocabSize {
            cumulative += scaled[i]
            if cumulative >= r {
                return llama_token(i)
            }
        }
        return llama_token(vocabSize - 1)
    }

    // MARK: - Tokenization

    private func tokenize(text: String, vocab: OpaquePointer) -> [llama_token] {
        let utf8Count = text.utf8.count
        let maxTokens = utf8Count + 16
        var tokens = [llama_token](repeating: 0, count: maxTokens)
        let count = llama_tokenize(vocab, text, Int32(utf8Count), &tokens, Int32(maxTokens), true, true)
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
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let path): return "Failed to load model: \(path)"
        case .contextCreateFailed: return "Failed to create llama context"
        case .modelNotLoaded: return "Model not loaded"
        case .invalidInput: return "Invalid JSON input"
        case .decodeFailed: return "Token decoding failed"
        }
    }
}
