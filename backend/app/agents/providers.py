"""Optional adapter for APIs implementing the Chat Completions message format."""

import json
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import Request, urlopen


class ModelProviderError(RuntimeError):
    """A model request failed; it must not become an empty agent result."""


class ChatCompletionsProvider:
    def __init__(self, endpoint: str, model: str, api_key: str, timeout_seconds: float = 20.0):
        parsed = urlparse(endpoint)
        if parsed.scheme != "https" or not parsed.netloc:
            raise ValueError("LLM endpoint must use HTTPS")
        if not model or not api_key or timeout_seconds <= 0:
            raise ValueError("model, api_key and positive timeout are required")
        self.endpoint = endpoint
        self.model = model
        self.api_key = api_key
        self.timeout_seconds = timeout_seconds

    def complete(self, system_prompt: str, event_json: str) -> str:
        payload = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": event_json},
            ],
        }
        request = Request(
            self.endpoint,
            data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
            headers={"Authorization": f"Bearer {self.api_key}", "Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urlopen(request, timeout=self.timeout_seconds) as response:
                body = json.load(response)
        except HTTPError as exc:
            raise ModelProviderError(f"LLM HTTP status {exc.code}") from None
        except (URLError, TimeoutError, OSError, ValueError) as exc:
            raise ModelProviderError(f"LLM request failed: {type(exc).__name__}") from None
        try:
            content = body["choices"][0]["message"]["content"]
        except (TypeError, KeyError, IndexError) as exc:
            raise ModelProviderError("LLM response has no message content") from exc
        if not isinstance(content, str) or not content.strip():
            raise ModelProviderError("LLM response content is empty")
        return content
