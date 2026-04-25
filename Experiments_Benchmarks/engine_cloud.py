from openai import OpenAI
from schemas import ConversationInput, SuggestionOutput, EvalMetrics
from prompt import build_messages
from evaluator import measure


PROVIDER_PRESETS = {
    "openai": {
        "base_url": "https://api.openai.com/v1",
        "default_model": "gpt-5.4-nano",
        "models": {
            "gpt-5.4":      "GPT-5.4 — frontier flagship, complex reasoning ($2.5/$15)",
            "gpt-5.4-mini": "GPT-5.4 Mini — fast, great for chat ($0.75/$4.50)",
            "gpt-5.4-nano": "GPT-5.4 Nano — cheapest, fastest ($0.20/$1.25)",
        },
    },
    "anthropic": {
        "base_url": "https://api.anthropic.com/v1/",
        "default_model": "claude-sonnet-4-6",
        "use_anthropic_sdk": True,
        "models": {
            "claude-opus-4-6":           "Claude Opus 4.6 — best quality, deep reasoning ($5/$25)",
            "claude-sonnet-4-6":         "Claude Sonnet 4.6 — balanced speed/quality ($3/$15)",
            "claude-haiku-4-5-20251001": "Claude Haiku 4.5 — fastest ($1/$5)",
        },
    },
    "gemini": {
        "base_url": "https://generativelanguage.googleapis.com/v1beta/openai/",
        "default_model": "gemini-3-flash-preview",
        "models": {
            "gemini-3.1-pro-preview":       "Gemini 3.1 Pro — most advanced reasoning",
            "gemini-3-flash-preview":       "Gemini 3 Flash — frontier at low cost ($0.50/$3)",
            "gemini-3.1-flash-lite-preview": "Gemini 3.1 Flash-Lite — budget friendly",
        },
    },
    "groq": {
        "base_url": "https://api.groq.com/openai/v1",
        "default_model": "llama-3.3-70b-versatile",
        "models": {
            "llama-3.3-70b-versatile": "Llama 3.3 70B — high quality, free tier",
            "llama-3.2-1b-preview":    "Llama 3.2 1B — ultra fast",
        },
    },
    "openrouter": {
        "base_url": "https://openrouter.ai/api/v1",
        "default_model": "anthropic/claude-sonnet-4-6",
        "models": {
            "openai/gpt-5.4-nano":         "GPT-5.4 Nano via OpenRouter",
            "anthropic/claude-sonnet-4-6":  "Claude Sonnet 4.6 via OpenRouter",
            "anthropic/claude-opus-4-6":    "Claude Opus 4.6 via OpenRouter",
            "google/gemini-3-flash-preview": "Gemini 3 Flash via OpenRouter",
        },
    },
}

ENV_KEY_MAP = {
    "openai": "OPENAI_API_KEY",
    "anthropic": "ANTHROPIC_API_KEY",
    "gemini": "GEMINI_API_KEY",
    "groq": "GROQ_API_KEY",
    "together": "TOGETHER_API_KEY",
    "openrouter": "OPENROUTER_API_KEY",
}


def list_providers():
    """Print all available providers and their models."""
    for provider, preset in PROVIDER_PRESETS.items():
        env_key = ENV_KEY_MAP.get(provider, f"{provider.upper()}_API_KEY")
        print(f"\n  {provider} (env: {env_key}):")
        for model_id, desc in preset.get("models", {}).items():
            default = " (default)" if model_id == preset["default_model"] else ""
            print(f"    {model_id:<40} {desc}{default}")


class CloudEngine:
    def __init__(
        self,
        api_key: str,
        provider: str = "openai",
        model: str | None = None,
        base_url: str | None = None,
    ):
        self.provider = provider
        preset = PROVIDER_PRESETS.get(provider, {})
        if not preset and not base_url:
            raise ValueError(
                f"Unknown provider '{provider}'. "
                f"Available: {', '.join(PROVIDER_PRESETS.keys())}"
            )

        self.base_url = base_url or preset.get("base_url", "https://api.openai.com/v1")
        self.model = model or preset.get("default_model", "gpt-5.4-nano")
        self.model_name = f"{provider}/{self.model}"
        self.use_anthropic = preset.get("use_anthropic_sdk", False)

        if self.use_anthropic:
            try:
                import anthropic
            except ImportError:
                raise ImportError("pip install anthropic  — required for Anthropic provider")
            self.anthropic_client = anthropic.Anthropic(api_key=api_key)
        else:
            self.client = OpenAI(api_key=api_key, base_url=self.base_url)

    def generate(
        self, conv_input: ConversationInput, max_tokens: int = 512, temperature: float = 0.7
    ) -> tuple[SuggestionOutput, EvalMetrics]:
        messages = build_messages(conv_input)

        try:
            if self.use_anthropic:
                return self._generate_anthropic(messages, max_tokens, temperature)
            return self._generate_openai(messages, max_tokens, temperature)
        except Exception as e:
            error_type = type(e).__name__
            raise RuntimeError(
                f"[{self.model_name}] API call failed ({error_type}): {e}"
            ) from e

    def _generate_openai(
        self, messages: list[dict], max_tokens: int, temperature: float
    ) -> tuple[SuggestionOutput, EvalMetrics]:
        with measure(self.model_name) as metrics:
            response = self.client.chat.completions.create(
                model=self.model,
                messages=messages,
                max_tokens=max_tokens,
                temperature=temperature,
                response_format={"type": "json_object"},
            )

        raw_text = response.choices[0].message.content or ""
        usage = response.usage
        if usage:
            metrics.prompt_tokens = usage.prompt_tokens
            metrics.tokens_generated = usage.completion_tokens
            metrics.total_tokens = usage.total_tokens

        output = SuggestionOutput.from_raw_text(raw_text)
        return output, metrics

    def _generate_anthropic(
        self, messages: list[dict], max_tokens: int, temperature: float
    ) -> tuple[SuggestionOutput, EvalMetrics]:
        system_msg = ""
        user_msgs = []
        for m in messages:
            if m["role"] == "system":
                system_msg = m["content"]
            else:
                user_msgs.append(m)

        with measure(self.model_name) as metrics:
            response = self.anthropic_client.messages.create(
                model=self.model,
                system=system_msg,
                messages=user_msgs,
                max_tokens=max_tokens,
                temperature=temperature,
            )

        raw_text = response.content[0].text if response.content else ""
        metrics.prompt_tokens = response.usage.input_tokens
        metrics.tokens_generated = response.usage.output_tokens
        metrics.total_tokens = response.usage.input_tokens + response.usage.output_tokens

        output = SuggestionOutput.from_raw_text(raw_text)
        return output, metrics
