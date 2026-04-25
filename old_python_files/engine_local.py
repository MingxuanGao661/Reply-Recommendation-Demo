from llama_cpp import Llama, LlamaGrammar
from schemas import ConversationInput, SuggestionOutput, EvalMetrics
from prompt import build_messages
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


class LocalEngine:
    def __init__(self, model_path: str, n_ctx: int = 2048, n_gpu_layers: int = -1):
        """Load a GGUF model for local inference.

        Args:
            model_path: Path to the .gguf file.
            n_ctx: Context window size.
            n_gpu_layers: Layers to offload to GPU (-1 = all available).
        """
        self.model_path = model_path
        self.model_name = model_path.rsplit("/", 1)[-1].replace(".gguf", "")

        model_lower = self.model_name.lower()
        self.use_grammar = not any(skip in model_lower for skip in GRAMMAR_SKIP_MODELS)

        self.llm = Llama(
            model_path=model_path,
            n_ctx=n_ctx,
            n_gpu_layers=n_gpu_layers,
            verbose=False,
        )
        self.grammar = LlamaGrammar.from_string(SUGGESTIONS_GRAMMAR) if self.use_grammar else None

    def generate(
        self, conv_input: ConversationInput, max_tokens: int = 512, temperature: float = 0.7
    ) -> tuple[SuggestionOutput, EvalMetrics]:
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
