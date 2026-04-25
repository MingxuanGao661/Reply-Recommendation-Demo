# Inference Acceleration Implementation Notes

## Goal

This update implements the full staged inference strategy:

1. Keep model workers warm and long-lived.
2. Trigger a small-model inline completion after user idle for 200ms.
3. Return exactly 1 inline completion in a direct style.
4. Generate 3 richer suggestions with the larger model only when the user explicitly opens/regenerates the suggestion shelf.
5. Reduce repeated prompt overhead with prefix token cache for stable system/template prefixes.

## What Changed

### 1) Engine Interface: Add Inline Fast Path

File: `Reply Recommendation Demo/Reply Recommendation Demo/Features/Common/ReplySuggestionEngine.swift`

- Added `InlineGenerationResult`:
  - `suggestion: Suggestion`
  - `metrics: InferenceMetrics`
- Added protocol API:
  - `generateInlineSuggestion(input:defaultProfile:)`
- Added default fallback implementation:
  - Uses normal generation and picks first suggestion.
- Implemented `LocalReplyEngine.generateInlineSuggestion(...)`:
  - Builds single-tone prompt with `PromptBuilder.buildLlamaPromptSingle(...)`
  - Uses short decode budget (`tokenLimit: 96`)
  - Returns exactly one suggestion:
    - `Direct` for general style
    - `Agree` for decision style

### 2) Long-Lived Worker Split (Small vs Large)

File: `Reply Recommendation Demo/Reply Recommendation Demo/Features/Chat/ChatViewModel.swift`

- Existing large-model engine remains the panel engine.
- Added dedicated cached inline engine:
  - `cachedInlineLocalEngine`
  - Uses bundled `1B` model (`Llama-3.2-1B-Instruct-Q4_K_M`)
  - No LoRA on inline path for lower latency and stable startup
- Added warm-up for inline engine:
  - `warmUpInlineLocalEngineIfNeeded()`

### 3) 200ms Idle Trigger for Inline Completion

File: `Reply Recommendation Demo/Reply Recommendation Demo/Features/Chat/ChatViewModel.swift`

- Added debounce state:
  - `inlineDebounceTask`
  - `inlineIdleDelayNs = 200_000_000`
- Added `scheduleInlineSuggestionGeneration()`:
  - Cancels stale task on each keystroke
  - If draft is non-empty and user stops typing for 200ms, runs inline inference
- Added `generateInlineSuggestion()`:
  - Uses inline engine
  - Silent fail behavior (best effort, no blocking alerts)

### 4) Inline UX in Composer

Files:
- `Reply Recommendation Demo/Reply Recommendation Demo/Features/Chat/ChatUI.swift`
- `Reply Recommendation Demo/Reply Recommendation Demo/Features/Chat/ChatScreen.swift`

- Composer now accepts:
  - `inlineSuggestion`
  - `inlineMetricsSummary`
  - `onAcceptInline`
- Added an inline suggestion capsule above the text field:
  - Tapping applies the completion into draft
- Added draft observer in `ChatScreen`:
  - `.onChange(of: viewModel.draftText)` -> `scheduleInlineSuggestionGeneration()`

### 5) Keep Panel Generation Explicit (Large Model, 3 Cards)

File: `Reply Recommendation Demo/Reply Recommendation Demo/Features/Chat/ChatViewModel.swift`

- Bootstrapping no longer auto-runs panel generation.
- Panel generation remains explicit via:
  - Sparkle button
  - Regenerate action in suggestion shelf
- Existing `generateSuggestionsProgressive(...)` path remains the 3-card path.

### 6) Prefix Cache Optimization for Repeated Prompt Templates

File: `Reply Recommendation Demo/Reply Recommendation Demo/Backend/LLMService.swift`

- Added per-service prefix token cache:
  - `prefixTokenCache: [String: [llama_token]]`
  - small bounded size (`prefixTokenCacheLimit = 12`)
- Replaced prompt tokenization entry with:
  - `tokenizePromptWithPrefixCache(prompt:vocab:)`
- Logic:
  - Split prompt near user-header marker.
  - Cache tokenization for stable prefix segment (system/template-heavy part).
  - Re-tokenize only suffix and concatenate.

This is a lightweight prefill optimization reducing repeated tokenization overhead for similar prompts.

## Behavioral Summary

- User typing pauses for 200ms -> fast on-device inline completion (1 suggestion).
- User taps suggestion panel regenerate/sparkle -> larger 3-suggestion generation.
- Both engines are cached and warmed for long-lived worker behavior.
- Prompt token prefix caching reduces repeated work on fixed instruction/template segments.

## Notes / Tradeoffs

- Inline path intentionally prioritizes latency over style diversity.
- Inline generation currently requires non-empty draft text.
- Prefix cache is token-cache based (safe Swift-side optimization) and does not replace native KV-cache internals.
