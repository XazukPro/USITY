"""Optional adapter for APIs implementing the Chat Completions message format."""

import json
import ssl
import time
import uuid
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlparse
from urllib.request import Request, urlopen


class ModelProviderError(RuntimeError):
    """A model request failed; it must not become an empty agent result."""


class ProviderHttpError(ModelProviderError):
    def __init__(self, status):
        super().__init__(f"GigaChat HTTP status {status}")
        self.status = status


class ChatCompletionsProvider:
    def __init__(
        self, endpoint: str, model: str, api_key: str, timeout_seconds: float = 20.0
    ):
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
            headers={
                "Authorization": f"Bearer {self.api_key}",
                "Content-Type": "application/json",
            },
            method="POST",
        )
        try:
            with urlopen(request, timeout=self.timeout_seconds) as response:
                body = json.load(response)
        except HTTPError as exc:
            raise ModelProviderError(f"LLM HTTP status {exc.code}") from None
        except (URLError, TimeoutError, OSError, ValueError) as exc:
            raise ModelProviderError(
                f"LLM request failed: {type(exc).__name__}"
            ) from None
        try:
            content = body["choices"][0]["message"]["content"]
        except (TypeError, KeyError, IndexError) as exc:
            raise ModelProviderError("LLM response has no message content") from exc
        if not isinstance(content, str) or not content.strip():
            raise ModelProviderError("LLM response content is empty")
        return content


class GigaChatProvider:
    """GigaChat personal API adapter with cached OAuth token and verified TLS."""

    OAUTH_URL = "https://ngw.devices.sberbank.ru:9443/api/v2/oauth"
    CHAT_URL = "https://api.giga.chat/v1/chat/completions"
    OUTPUT_SCHEMA = {
        "type": "object",
        "additionalProperties": False,
        "required": ["kind", "text", "source_ids", "uncertain"],
        "properties": {
            "kind": {"type": "string", "enum": ["new_homework", "none"]},
            "text": {"type": ["string", "null"]},
            "source_ids": {"type": "array", "items": {"type": "integer"}},
            "uncertain": {"type": "boolean"},
        },
    }

    def __init__(
        self,
        credentials,
        model="GigaChat-2",
        ca_bundle_file=None,
        timeout=20,
        *,
        output_schema=None,
    ):
        if not credentials or not model or timeout <= 0:
            raise ValueError("credentials, model and positive timeout are required")
        self.credentials = credentials
        self.model = model
        self.timeout = timeout
        self.output_schema = (
            self.OUTPUT_SCHEMA if output_schema is None else output_schema
        )
        self.context = ssl.create_default_context()
        if ca_bundle_file:
            self.context.load_verify_locations(cafile=ca_bundle_file)
        self.access_token = None
        self.expires_at = 0

    def _post(self, request):
        try:
            with urlopen(
                request, timeout=self.timeout, context=self.context
            ) as response:
                result = json.load(response)
        except HTTPError as exc:
            raise ProviderHttpError(exc.code) from None
        except (URLError, TimeoutError, OSError, ValueError) as exc:
            raise ModelProviderError(
                f"GigaChat request failed: {type(exc).__name__}"
            ) from None
        if not isinstance(result, dict):
            raise ModelProviderError("GigaChat returned an invalid response")
        return result

    def _token(self):
        if self.access_token and time.time() < self.expires_at - 60:
            return self.access_token
        request = Request(
            self.OAUTH_URL,
            data=urlencode({"scope": "GIGACHAT_API_PERS"}).encode("ascii"),
            headers={
                "Authorization": "Basic " + self.credentials,
                "Content-Type": "application/x-www-form-urlencoded",
                "Accept": "application/json",
                "RqUID": str(uuid.uuid4()),
            },
            method="POST",
        )
        result = self._post(request)
        token, expires_at = result.get("access_token"), result.get("expires_at")
        if (
            not isinstance(token, str)
            or not token
            or not isinstance(expires_at, (int, float))
        ):
            raise ModelProviderError("GigaChat OAuth response is invalid")
        self.access_token = token
        self.expires_at = expires_at
        return token

    def complete(self, system_prompt, event_json):
        body = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": event_json},
            ],
            "response_format": {
                "type": "json_schema",
                "schema": self.output_schema,
                "strict": True,
            },
        }
        for attempt in range(2):
            request = Request(
                self.CHAT_URL,
                data=json.dumps(body, ensure_ascii=False).encode("utf-8"),
                headers={
                    "Authorization": "Bearer " + self._token(),
                    "Content-Type": "application/json",
                    "Accept": "application/json",
                },
                method="POST",
            )
            try:
                result = self._post(request)
                break
            except ProviderHttpError as exc:
                if exc.status != 401 or attempt:
                    raise
                self.access_token = None
        try:
            choice = result["choices"][0]
            if choice.get("finish_reason") == "blacklist":
                raise ModelProviderError("GigaChat rejected the request")
            content = choice["message"]["content"]
        except (KeyError, IndexError, TypeError) as exc:
            raise ModelProviderError("GigaChat chat response is invalid") from exc
        if not isinstance(content, str) or not content.strip():
            raise ModelProviderError("GigaChat chat content is empty")
        return content
