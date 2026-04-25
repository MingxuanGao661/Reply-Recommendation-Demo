# Python → Swift Backend Conversion Report

## Overview

This report documents the conversion of the Reply Recommendation Demo backend from Python to Swift for iOS deployment. The Python prototype served as the reference implementation — all logic, prompt templates, and JSON schemas are preserved to ensure identical behavior on both platforms.

**Source**: 6 Python modules (~750 lines)  
**Target**: 5 Swift files (~750 lines) in `Reply Recommendation Demo/Backend/` + 1 test UI  
**Model**: Llama-3.2-1B-Instruct-Q4_K_M.gguf (770 MB, shared across both platforms)

---

## File-by-File Mapping

| Python Source | Swift Target | Lines (Py → Swift) | Role |
|---------------|-------------|---------------------|------|
| `schemas.py` (data structures) | `Models.swift` | 152 → 109 | Input/output data types + metrics |
| `prompt.py` | `PromptBuilder.swift` | 88 → 125 | System/user prompt construction |
| `schemas.py` (parsing logic) | `OutputParser.swift` | (included above) → 113 | Tolerant JSON parsing from LLM output |
| `engine_local.py` | `LLMService.swift` | 78 → 252 | Local LLM inference via llama.cpp |
| `engine_cloud.py` | `CloudService.swift` | 170 → 196 | Cloud API inference (OpenAI/Anthropic/Gemini/Groq/OpenRouter) |
| `demo.py` | `ContentView.swift` | 335 → 254 | Test entry point (CLI → SwiftUI test harness) |

### Not Converted (Development-Only Tools)

| Python File | Reason |
|-------------|--------|
| `evaluator.py` (47 lines) | Performance measurement — absorbed into `LLMService.swift` metrics |
| `visualize.py` (217 lines) | Chart generation — development-only tool, not needed on device |

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

## 5. CloudService.swift ← engine_cloud.py

**What changed:**
- Python's `openai` SDK + `anthropic` SDK → Swift native `URLSession` HTTP requests
- Supports the same 5 providers: OpenAI, Anthropic, Gemini, Groq, OpenRouter
- Anthropic uses its native API format (x-api-key header, separate system message); all others use OpenAI-compatible chat completions endpoint
- `async/await` pattern matches Swift concurrency model

**Key difference from Python:**
Python uses third-party SDKs (`openai`, `anthropic` pip packages). Swift uses raw HTTP requests via `URLSession` — no external dependencies needed.

---

## 6. ContentView.swift ← demo.py

**What changed:**
- Python CLI (`argparse` + terminal output) → SwiftUI test harness UI
- Mode selection: Segmented picker (Local / Cloud) instead of `python demo.py local|cloud`
- 5 hardcoded test samples from `test_samples.json` instead of file loading
- Results display: SwiftUI `Text` views instead of `print()` statements

This is a **temporary test UI** — the frontend team will replace it with the actual app interface. Its sole purpose is to verify that backend inference works correctly on device.

---

## Integration Guide for iOS Frontend

The frontend team interacts with two services:

```swift
// Option A: Cloud inference (needs network + API key)
let cloud = try CloudService(apiKey: "xxx", provider: "groq")
let (json, metrics) = try await cloud.generate(input: input)

// Option B: Local inference (offline, needs .gguf in bundle)
let path = Bundle.main.path(forResource: "Llama-3.2-1B-Instruct-Q4_K_M", ofType: "gguf")!
let local = try LLMService(modelPath: path)
let (json, metrics) = try local.generate(input: input)
```

Both return identical JSON output format. No additional configuration is needed. The services handle prompt construction, inference, output parsing, and performance measurement internally.

---

## Fine-Tuning Data Strategy (LoRA)

### Goal

Fine-tune Llama 3.2 1B with LoRA to improve reply quality for both **draft polishing** and **from-scratch suggestion** modes.

### Training Data Format

Each training sample is a complete `system → user → assistant` turn in the standard chat format:

```json
{
  "messages": [
    {"role": "system", "content": "(system prompt — auto-generated by PromptBuilder)"},
    {"role": "user", "content": "Conversation:\n  Me: ...\n  Other: ...\n\nMy draft: \"...\"\n\nReply with JSON:"},
    {"role": "assistant", "content": "{\"suggestions\": [{\"label\": \"Natural\", \"text\": \"...\"}, {\"label\": \"Polite\", \"text\": \"...\"}, {\"label\": \"Like You\", \"text\": \"...\"}]}"}
  ]
}
```

The `system` and `user` content is derived from the existing inference-time input (ConversationInput + PromptBuilder). The `assistant` content is the **ground-truth ideal output** — generated by a large model (Claude Sonnet / GPT-4o) and quality-checked.

### Data Volume Target

| Phase | Volume | Purpose |
|-------|--------|---------|
| Phase 1 (MVP) | ~3000 samples | Stable JSON format + clear style differentiation |
| — with draft | ~1200 (40%) | Draft polishing mode |
| — without draft | ~1800 (60%) | From-scratch suggestion mode (harder task, needs more data) |
| Phase 2 (if needed) | +1000 samples | Add `relationship` field (4 types: friend/colleague/partner/family) |
| Diminishing returns | >10000 | 1B model capacity ceiling — switch to 3B+ for further gains |

### Data Generation Pipeline

1. **Scenario generation**: Use GPT-4o-mini to produce diverse conversation scenarios (~$6 for 3000)
2. **Ground-truth output**: Use Claude Sonnet to generate high-quality suggestion triples (~$45 for 3000)
3. **Quality audit**: Manually review 10% + use Claude to flag low-quality outputs
4. **Format conversion**: Script to assemble into chat-format JSONL using PromptBuilder logic
5. **Estimated total cost**: $10–50 depending on quality tier

### Topic Coverage (target distribution for 3000 samples)

| Category | % | Examples |
|----------|---|---------|
| Casual / Social | 30% | Hanging out, food, weekend plans |
| Work / Professional | 15% | Meetings, deadlines, project updates |
| Emotional / Support | 15% | Venting, encouragement, tough situations |
| Planning / Logistics | 15% | Time, location, coordination |
| Humor / Banter | 10% | Jokes, teasing, memes |
| Relationship / Dating | 10% | Flirting, check-ins, date planning |
| Family | 5% | Parents, siblings, family events |

### Profile Variation

Each sample should have a randomized `profile` to ensure the model learns all combinations:
- **tone**: warm, neutral, enthusiastic, friendly (4 values)
- **length**: short, medium, long (3 values)
- **style**: casual, chill, conversational, relaxed (4 values)

### Context Complexity Guidelines for 1B Model

**Keep for 1B:**
- `tone` / `length` / `style` (current profile fields) — proven to work
- Conversation history (up to ~10 turns) — model handles this well

**Consider adding (Phase 2):**
- `relationship` (4 broad categories only) — moderate complexity increase

**Avoid for 1B (defer to 3B+):**
- Free-text `history_summary` — exceeds comprehension capacity
- `mood` — overlaps with `tone`, causes confusion
- `setting` — too many possible values to generalize
- Multi-dimensional social context — 1B lacks the capacity to leverage it reliably

## Interface Expansion: Multi-Person Conversations (Implemented)

The `speaker` field has been expanded from `"me"` / `"other"` to support arbitrary user IDs with display names. The interface is **fully backward-compatible** — old 2-person format still works.

**Unified format (2-person and multi-person):**

2-person example:
```json
{
  "conversation": [
    {"speaker": "alice", "text": "Hey want to grab lunch?"},
    {"speaker": "me", "text": "How about ramen?"},
    {"speaker": "alice", "text": "Sure, what time?"}
  ],
  "participants": [
    {"id": "me", "name": "Me", "is_self": true},
    {"id": "alice", "name": "Alice"}
  ],
  "reply_to": "alice",
  "draft": "12ish"
}
```

Multi-person example:
```json
{
  "conversation": [
    {"speaker": "me", "text": "周六谁有空？"},
    {"speaker": "alice", "text": "我有空！"},
    {"speaker": "bob", "text": "下午可以"},
    {"speaker": "me", "text": "那去吃火锅？"},
    {"speaker": "bob", "text": "行啊，几点？"}
  ],
  "self_id": "me",
  "reply_to": "bob",
  "participants": [
    {"id": "me", "name": "Me", "is_self": true},
    {"id": "alice", "name": "Alice", "relationship": "friend"},
    {"id": "bob", "name": "Bob", "relationship": "colleague"}
  ],
  "draft": "12点",
  "profile": {"tone": "friendly", "length": "short", "style": "casual"}
}
```

**Fields:**

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `conversation` | [Message] | yes | — | Array of messages |
| `speaker` | String | yes | — | User ID (e.g. "me", "alice", "bob") |
| `text` | String | yes | — | Message content |
| `participants` | [Participant] | no | [] | Maps speaker IDs to display names; used in prompt |
| `self_id` | String? | no | `"me"` | Which speaker ID represents the current user |
| `reply_to` | String? | no | nil | Who the user is @replying to (speaker ID) |
| `draft` | String? | no | nil | User's draft text; nil/empty = suggest-from-scratch mode |
| `profile` | Profile? | no | warm/short/casual | Style preferences (see design note below) |

**Display name resolution:**
1. `participants` array lookup by speaker ID
2. Fallback: raw speaker ID as-is (e.g. "alice" shows as "alice")
3. Self ID always displays as "Me"

**Multi-person + @mention: why this works for 1B**

In the "assistive @mention" model, the user explicitly selects who to reply to. This means the 1B model doesn't need to figure out conversation dynamics or reply targets — it just needs to:
1. Read who said what (labeled with display names)
2. Know it's replying to a specific person (explicit `reply_to`)
3. Polish/suggest a reply (same core task as 2-person)

The prompt automatically adapts: "Each suggestion MUST directly respond to **Bob's message**" instead of generic "the last message."

**Assessment for 1B model with LoRA:**
- 3 participants, 5-8 turns, explicit `reply_to`: fully viable
- 4 participants: viable but quality may dip slightly
- 5+ participants or no `reply_to`: recommend Cloud API (large model)

---

### Design Decision: Profile Field

`profile` controls the style of generated replies (tone, length, style). Design considerations:

**Where does profile come from?**

| Option | Pros | Cons | Recommendation |
|--------|------|------|----------------|
| App settings (persisted) | Set once, consistent UX | User may forget to update | Default approach |
| Per-request from frontend | Maximum flexibility | Extra UI complexity | For power users |
| Omitted entirely | Simplest | No personalization | Acceptable for MVP |
| Learned from user history | Most personalized | Requires data + ML pipeline | Future enhancement |

**Current design:** `profile` is **optional** in the interface with sensible defaults (`warm` / `short` / `casual`). The frontend can:
1. Not send it at all (uses defaults)
2. Store user preferences locally and send per-request
3. Let users adjust in a settings screen

The profile is baked into the system prompt, so adding/removing it requires no model changes — it's purely a prompt-level feature. This means even after LoRA fine-tuning, profile can be adjusted without retraining.
