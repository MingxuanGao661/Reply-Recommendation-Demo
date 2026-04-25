# Python → Swift Backend Conversion Report

## Overview

This report documents the conversion of the Reply Recommendation Demo backend from Python to Swift for iOS deployment. The Python prototype served as the reference implementation — all logic, prompt templates, and JSON schemas are preserved to ensure identical behavior on both platforms.

**Source**: 4 Python modules (497 lines)  
**Target**: 4 Swift files (494 lines) in `Reply Recommendation Demo/Backend/`  
**Model**: Llama-3.2-1B-Instruct-Q4_K_M.gguf (770 MB, shared across both platforms)

---

## File-by-File Mapping

| Python Source | Swift Target | Lines (Py → Swift) | Role |
|---------------|-------------|---------------------|------|
| `schemas.py` (data structures) | `Models.swift` | 152 → 109 | Input/output data types + metrics |
| `prompt.py` | `PromptBuilder.swift` | 88 → 125 | System/user prompt construction |
| `schemas.py` (parsing logic) | `OutputParser.swift` | (included above) → 113 | Tolerant JSON parsing from LLM output |
| `engine_local.py` | `LLMService.swift` | 78 → 247 | LLM inference via llama.cpp |

### Not Converted (Not Needed on iOS)

| Python File | Reason |
|-------------|--------|
| `engine_cloud.py` (170 lines) | Cloud API fallback — optional for iOS, can be added later |
| `demo.py` (335 lines) | CLI entry point — iOS has its own UI layer |
| `evaluator.py` (47 lines) | Performance measurement — absorbed into `LLMService.swift` |
| `visualize.py` (217 lines) | Chart generation — development-only tool |

---

## Detailed Conversion Notes

### 1. Models.swift ← schemas.py

**What changed:**
- Python `@dataclass` → Swift `struct` with `Codable` protocol
- Python `from_dict()` / `from_json()` class methods → Swift `Codable` auto-synthesis + static `from(json:)` convenience method
- `draft` field changed from required `str` to optional `String?` with computed property `hasDraft`
- `profile` field also made optional with `resolvedProfile` default fallback

**Key design decision:**  
Python uses manual dictionary parsing (`data["draft"]`); Swift leverages `Codable` for automatic JSON ↔ struct conversion, which is more type-safe and less error-prone.

```
Python:                              Swift:
@dataclass                           struct ConversationInput: Codable {
class ConversationInput:                 let conversation: [Message]
    conversation: List[Message]          let draft: String?
    draft: str                           let profile: Profile?
    profile: Profile                     var hasDraft: Bool { ... }
                                     }
    @classmethod
    def from_dict(cls, data):        static func from(json: String) -> Self? {
        ...manual parsing...             JSONDecoder().decode(...)
                                     }
```

**Metrics struct:**  
Python `EvalMetrics` → Swift `InferenceMetrics`. Same fields, same `summary` output format. `to_dict()` preserved for JSON serialization compatibility.

---

### 2. PromptBuilder.swift ← prompt.py

**What changed:**
- Python module-level functions → Swift `enum PromptBuilder` (stateless namespace)
- Python f-string template formatting → Swift `replacingOccurrences(of:with:)`
- Both system prompts (with-draft / no-draft) preserved verbatim, including few-shot examples

**New addition — `buildLlamaPrompt()`:**  
Python's `llama-cpp-python` library handles chat template formatting internally via `create_chat_completion()`. On iOS, we call the raw llama.cpp C API directly, so we must manually format the Llama 3.2 chat template:

```
<|begin_of_text|>
<|start_header_id|>system<|end_header_id|>
{system prompt}<|eot_id|>
<|start_header_id|>user<|end_header_id|>
{user prompt}<|eot_id|>
<|start_header_id|>assistant<|end_header_id|>
```

This function does not exist in the Python version because `llama-cpp-python` abstracts it away.

**Also preserved — `buildMessages()`:**  
Returns the `[{"role": ..., "content": ...}]` array format for potential OpenAI-compatible API use on iOS (cloud fallback).

---

### 3. OutputParser.swift ← schemas.py (parsing logic)

**What changed:**
- Python `SuggestionOutput.from_raw_text()` → Swift `OutputParser.parse(raw:)`
- Extracted into a dedicated file for separation of concerns (in Python it was mixed into `schemas.py`)

**Three-layer parsing strategy preserved identically:**

1. **Right-to-left brace scanning**: Finds the largest valid JSON substring, handling garbage tails that small models sometimes append after the closing `}`.

2. **Multi-format support** (`_parse_suggestions` → `parseSuggestions`):
   - Format A: Standard `[{"label": "...", "text": "..."}]` — expected format
   - Format B: Array of plain strings — fallback for simple models
   - Format C: Dictionary `{"Natural": "...", "Polite": "..."}` — alternate key-value format

3. **Regex fallback**: When JSON parsing fails entirely, extracts `"label"/"text"` pairs via regex pattern matching.

**Implementation difference:**  
Python uses `re.findall()` for regex; Swift uses `NSRegularExpression` with `NSRange`-based extraction. The regex pattern is identical: `"label"\s*:\s*"([^"]+)"\s*,\s*"text"\s*:\s*"([^"]+)"`.

---

### 4. LLMService.swift ← engine_local.py + evaluator.py

This is the most significant conversion — the inference engine changes from a high-level Python binding to direct C API calls.

**Architecture comparison:**

```
Python (engine_local.py):            Swift (LLMService.swift):
llama-cpp-python (Python binding)    llama.cpp C API (via llama.swift SPM)
  ↓                                    ↓
Llama() class                        llama_load_model_from_file()
  .create_chat_completion()          llama_new_context_with_model()
  → returns dict with choices        Manual tokenize → decode → sample loop
                                     → returns raw string
```

**What the Python version abstracts away (that Swift must handle explicitly):**

| Responsibility | Python | Swift |
|----------------|--------|-------|
| Model loading | `Llama(model_path=...)` | `llama_model_default_params()` + `llama_load_model_from_file()` |
| Context creation | Automatic | `llama_context_default_params()` + `llama_new_context_with_model()` |
| Chat template | Automatic (`create_chat_completion`) | Manual `buildLlamaPrompt()` with Llama 3.2 special tokens |
| Tokenization | Automatic | Manual `llama_tokenize()` |
| Prompt evaluation | Automatic | `llama_batch_init()` + `llama_decode()` |
| Token generation | Automatic | Manual loop: `llama_get_logits_ith()` → sample → `llama_decode()` |
| Detokenization | Automatic | Manual `llama_token_to_piece()` |
| Memory management | Garbage collected | Manual `deinit` with `llama_free()` / `llama_free_model()` |

**GBNF Grammar:**  
The grammar string is copied verbatim from `engine_local.py`. It forces the model to output exactly 3 suggestion objects in valid JSON. The Gemma skip logic (`GRAMMAR_SKIP_MODELS`) is also preserved.

**Performance measurement:**  
Python uses a separate `evaluator.py` with a context manager. In Swift, this is integrated directly into `LLMService.generate()`:
- `CACurrentMediaTime()` for high-resolution latency (nanosecond precision vs Python's `time.perf_counter()`)
- `mach_task_basic_info` for memory measurement (more accurate than Python's `psutil` on Apple platforms)

**iOS-specific optimizations:**
- `use_mmap = true`: Memory-mapped model loading — pages count as clean memory, avoiding iOS's ~5GB dirty memory jetsam limit
- `n_gpu_layers = -1`: Full Metal GPU offload for maximum inference speed
- Thread count capped at 4 to balance performance vs battery life

---

## JSON Interface Contract

Both Python and Swift backends share the exact same JSON input/output format:

**Input (ConversationInput):**
```json
{
  "conversation": [
    {"speaker": "me", "text": "Hey, want to grab lunch?"},
    {"speaker": "other", "text": "Sure, where?"}
  ],
  "draft": "how about that new ramen place",
  "profile": {"tone": "friendly", "length": "short", "style": "casual"}
}
```

**Output (SuggestionOutput):**
```json
{
  "suggestions": [
    {"label": "Natural", "text": "How about that new ramen place downtown?"},
    {"label": "Polite", "text": "I was thinking we could try the new ramen spot, if you're interested?"},
    {"label": "Like You", "text": "ramen place on 5th? heard it's good"}
  ]
}
```

Both `draft` and `profile` are optional. When `draft` is empty or absent, the system automatically switches to "suggest mode" (generates replies from context alone instead of polishing a draft).

---

## What's Shared Across Platforms

| Asset | Shared? | Notes |
|-------|---------|-------|
| GGUF model file | Yes | Same `Llama-3.2-1B-Instruct-Q4_K_M.gguf` (770 MB) |
| GBNF grammar string | Yes | Identical, copy-pasted |
| Prompt templates | Yes | Identical text, same few-shot examples |
| JSON schema | Yes | Same field names, same structure |
| Test samples | Yes | `test_samples.json` works on both platforms |

---

## Integration Guide for iOS Frontend

The frontend team only needs to interact with `LLMService`:

```swift
// Initialize once (app startup)
let path = Bundle.main.path(forResource: "Llama-3.2-1B-Instruct-Q4_K_M", ofType: "gguf")!
let service = try LLMService(modelPath: path)

// Generate (per user request, must be called off main thread)
Task.detached {
    let (outputJSON, metrics) = try service.generate(inputJSON: inputJSON)
    // outputJSON is ready to parse/display
    // metrics.latencyMs, metrics.tokensPerSec for performance monitoring
}
```

No additional configuration is needed. The service handles prompt construction, inference, output parsing, and performance measurement internally.
