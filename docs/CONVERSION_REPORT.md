# Python → Swift Backend Conversion Report

## 1. Overview

This document describes the iOS Swift backend for the Reply Recommendation Demo: how it maps from the Python prototype, the **JSON API**, and implementation notes.

| Item | Detail |
|------|--------|
| **Swift backend** | `Reply Recommendation Demo/Backend/*.swift` (5 files) + optional `ContentView` test UI |
| **Reference Python** | Prototype under `old_python_files/` (and similar layout elsewhere in the repo) |
| **Local model** | e.g. `Llama-3.2-1B-Instruct-Q4_K_M.gguf` (not committed to Git; use `.gitignore`) |

**Note:** Swift `Profile` is **`tone` + `length`** only. Archived Python `prompt.py` may still mention `style` until aligned.

---

## 2. Swift Module Map

| Python (reference) | Swift | Role |
|--------------------|-------|------|
| `schemas.py` (types) | `Models.swift` | `Message`, `Participant`, `Profile`, `ConversationInput`, output + metrics |
| `prompt.py` | `PromptBuilder.swift` | System / user prompts, Llama 3.2 template, cloud `messages[]` |
| `schemas.py` (parse) | `OutputParser.swift` | Tolerant JSON extraction from raw model text |
| `engine_local.py` | `LLMService.swift` | Local GGUF via llama.cpp (llama.swift SPM) |
| `engine_cloud.py` | `CloudService.swift` | OpenAI-compatible + Anthropic native HTTP |
| `demo.py` | `ContentView.swift` (optional) | Manual test harness |

**Not ported to the app:** `evaluator.py` (metrics inlined in `LLMService`), `visualize.py` (dev-only charts).

---

## 3. API Contract

### 3.1 Output — `SuggestionOutput`

```json
{
  "suggestions": [
    {"label": "Natural", "text": "..."},
    {"label": "Polite", "text": "..."},
    {"label": "Like You", "text": "..."}
  ]
}
```

### 3.2 Input — `ConversationInput`

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `conversation` | yes | — | `[{ "speaker": "<user_id>", "text": "..." }]` |
| `participants` | no | `[]` | Maps `speaker` IDs to display names in the prompt |
| `self_id` | no | `"me"` | Which `speaker` is the current user |
| `reply_to` | no | `null` | Reply target (`@`); helps multi-person prompts |
| `draft` | no | `null` | Empty / omitted → suggest-from-scratch; non-empty → polish draft |
| `conversation_profile` | no | — | Per-thread `tone` / `length`; persist with each chat |

There is **no per-request `profile` field** in JSON. Style is **conversation** + **user default** only.

**Examples** — see `docs/FRONTEND_INTEGRATION.md` for full JSON samples.

**Display names:** `participants` lookup by `speaker` ID; else raw ID; `self_id` → **Me**.

### 3.3 Profile merge (two layers, **per-field**)

| Layer | Source |
|-------|--------|
| Per-conversation | `conversation_profile` (optional `tone` / `length` per key) |
| Per-user | `defaultProfile` on `LLMService` / `CloudService` |

**Not whole-object priority:** for each axis independently —  
`tone` = `conversation_profile.tone` ?? `defaultProfile.tone` ?? `"warm"`;  
`length` = `conversation_profile.length` ?? `defaultProfile.length` ?? `"short"`.

`Profile` uses optional `String?` for `tone` and `length` so JSON may omit either key. Implemented via `Profile.mergedForPrompt(conversation:userDefault:)` and `ConversationInput.effectiveProfile(userDefault:)`.

### 3.4 Multi-person + 1B

With explicit `reply_to`, the task stays close to two-party reply generation. Prefer short threads and ≤3–4 speakers on 1B.

---

## 4. Implementation Notes (by file)

### 4.1 `Models.swift`

- `Codable` types; `ConversationInput.from(json:)`.
- `Profile` optional `tone` / `length`; `mergedForPrompt(conversation:userDefault:)` per-axis merge; `effectiveProfile(userDefault:)`.

### 4.2 `PromptBuilder.swift`

- **System:** Rules include personal tone/length, conversation tone/length, and **effective** merged line; no conversation transcript in system.
- **User:** recent `conversation` window, group / `reply_to`, draft, JSON instruction.
- `buildLlamaPrompt(input:userDefaultProfile:)`, `buildMessages(input:userDefaultProfile:)`.

### 4.3 `OutputParser.swift`

- Brace scan → JSON parse → regex fallback.

### 4.4 `LLMService.swift` / `CloudService.swift`

- Pass `defaultProfile` into `PromptBuilder` as `userDefaultProfile`.

### 4.5 `ContentView.swift`

- Optional smoke-test UI.

---

## 5. Fine-Tuning (LoRA) — Brief

- Chat-format training triples; `assistant` = gold `suggestions` JSON.
- ~3k samples target; ~40% with-draft / ~60% without-draft.
- Vary `tone` / `length` in synthetic data; align with `conversation_profile` + user default semantics.

---

## 6. Shared Assets (conceptual)

| Asset | Notes |
|-------|--------|
| GGUF weights | Do not commit large binaries |
| Prompt intent | Same task and output JSON shape |
| `test_samples.json` | Scenario ideas; field names may need updates |

---

## 7. iOS Integration Snippet

```swift
let cloud = try CloudService(apiKey: "...", provider: "groq", defaultProfile: Profile(tone: "warm", length: "short"))
let (json, metrics) = try await cloud.generate(input: input)

let local = try LLMService(modelPath: path, defaultProfile: Profile(tone: "neutral", length: "medium"))
let (json, metrics) = try local.generate(input: input)
```

Decode `json` → `SuggestionOutput`.

**Frontend-facing doc:** `docs/FRONTEND_INTEGRATION.md`.
