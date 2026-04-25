from llama_cpp import Llama, LlamaGrammar
from schemas import ConversationInput, SuggestionOutput, EvalMetrics
from prompt import build_messages, build_messages_gemma, build_messages_qwen
from evaluator import measure

# GBNF grammar that forces the model to output exactly:
# {"suggestions": [{"label": "...", "text": "..."}, ...]}
# with exactly 3 suggestion objects
SUGGESTIONS_GRAMMAR = r'''
root   ::= "{" ws "\"suggestions\"" ws ":" ws "[" ws item "," ws item "," ws item ws "]" ws "}"
item   ::= "{" ws "\"label\"" ws ":" ws string "," ws "\"text\"" ws ":" ws string ws "}"
string ::= "\"" chars "\""
chars  ::= char+
char   ::= [^"\\] | "\\" escape
escape ::= ["\\nrt/]
ws     ::= [ \t\n]*
'''

# Models with known grammar compatibility issues — use json_object mode instead
GRAMMAR_SKIP_MODELS = {"gemma"}

# Per-family routing: chat_format passed to Llama(), msg_builder key for generate()
_MODEL_FAMILIES: dict[str, dict[str, str]] = {
    "gemma": {"chat_format": "gemma",  "msg_builder": "gemma"},
    "qwen":  {"chat_format": "chatml", "msg_builder": "qwen"},
}


def _detect_model_family(name: str) -> str | None:
    """Return the model family key (e.g. 'gemma', 'qwen') or None."""
    n = name.lower()
    for family in _MODEL_FAMILIES:
        if family in n:
            return family
    return None


class LocalEngine:
    def __init__(
        self,
        model_path: str,
        n_ctx: int = 2048,
        n_gpu_layers: int = -1,
        chat_format: str | None = None,
        lora_path: str | None = None,
        lora_base: str | None = None,
        lora_scale: float = 1.0,
    ):
        """Load a GGUF model for local inference.

        Args:
            model_path: Path to the base ``.gguf`` weights (e.g. Llama-3.2-3B-Instruct-Q4_K_M.gguf).
            n_ctx: Context window size.
            n_gpu_layers: Layers to offload to GPU (-1 = all available).
            chat_format: Optional ``llama-cpp-python`` chat format override (e.g. ``\"gemma\"``, ``\"chatml\"``).
                If None, model family is auto-detected by filename:
                  gemma* → chat_format="gemma",  message builder merges system→user
                  qwen*  → chat_format="chatml", message builder appends /no_think to user turn
            lora_path: Optional path to a **LoRA adapter** in GGUF form (``llama-cpp-python`` merges at runtime).
            lora_base: Optional second base path (rare; see ``Llama`` docs — leave ``None`` for base+LoRA GGUF).
            lora_scale: LoRA blend strength (default ``1.0``).
        """
        self.model_path = model_path
        self.lora_path = lora_path
        base_name = model_path.rsplit("/", 1)[-1].replace(".gguf", "")
        if lora_path:
            lora_name = lora_path.rsplit("/", 1)[-1].replace(".gguf", "")
            self.model_name = f"{base_name}+{lora_name}"
        else:
            self.model_name = base_name

        model_lower = self.model_name.lower()
        self.use_grammar = not any(skip in model_lower for skip in GRAMMAR_SKIP_MODELS)

        # Resolve model family (None when chat_format is forced via CLI arg)
        if chat_format is not None:
            self.chat_format = chat_format
            self.model_family: str | None = None
        else:
            self.model_family = _detect_model_family(self.model_name)
            cfg = _MODEL_FAMILIES.get(self.model_family or "", {})
            self.chat_format = cfg.get("chat_format")

        llama_kwargs = dict(
            model_path=model_path,
            n_ctx=n_ctx,
            n_gpu_layers=n_gpu_layers,
            verbose=False,
        )
        if self.chat_format:
            llama_kwargs["chat_format"] = self.chat_format
        if lora_path:
            llama_kwargs["lora_path"] = lora_path
            llama_kwargs["lora_scale"] = lora_scale
            if lora_base:
                llama_kwargs["lora_base"] = lora_base

        self.llm = Llama(**llama_kwargs)
        self.grammar = LlamaGrammar.from_string(SUGGESTIONS_GRAMMAR) if self.use_grammar else None

    def generate(
        self, conv_input: ConversationInput, max_tokens: int = 512, temperature: float = 0.7
    ) -> tuple[SuggestionOutput, EvalMetrics]:
        builder = _MODEL_FAMILIES.get(self.model_family or "", {}).get("msg_builder", "default")
        if builder == "gemma":
            messages = build_messages_gemma(conv_input)
        elif builder == "qwen":
            messages = build_messages_qwen(conv_input)
        else:
            messages = build_messages(conv_input)

        call_kwargs = {
            "messages": messages,
            "max_tokens": max_tokens,
            "temperature": temperature,
        }
        if self.grammar:
            call_kwargs["grammar"] = self.grammar
            # 1B models often over-copy prompts or ramble to max_tokens; cap + repeat penalty helps.
            call_kwargs["max_tokens"] = min(call_kwargs["max_tokens"], 280)
            call_kwargs["repeat_penalty"] = 1.15
        else:
            call_kwargs["response_format"] = {"type": "json_object"}

        with measure(self.model_name) as metrics:
            response = self.llm.create_chat_completion(**call_kwargs)

        raw_text = response["choices"][0]["message"]["content"] or ""
        usage = response.get("usage", {})
        metrics.prompt_tokens = usage.get("prompt_tokens", 0)
        metrics.tokens_generated = usage.get("completion_tokens", 0)
        metrics.total_tokens = usage.get("total_tokens", 0)
        if metrics.latency_ms > 0 and metrics.tokens_generated > 0:
            metrics.tokens_per_sec = metrics.tokens_generated / (metrics.latency_ms / 1000)

        output = SuggestionOutput.from_raw_text(raw_text)
        return output, metrics

    def unload(self):
        del self.llm
        self.llm = None
