import json
import unittest
from unittest.mock import patch

from app.agents.providers import ChatCompletionsProvider, ModelProviderError


class Response:
    def __init__(self, body):
        self.body = body

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

    def read(self):
        return json.dumps(self.body).encode("utf-8")


class ChatProviderTests(unittest.TestCase):
    def test_sends_messages_and_returns_model_text(self):
        provider = ChatCompletionsProvider(
            endpoint="https://llm.example.test/v1/chat/completions",
            model="example-model",
            api_key="test-key",
        )
        with patch("app.agents.providers.urlopen", return_value=Response({"choices": [{"message": {"content": '{"kind":"none"}'}}]})) as send:
            result = provider.complete("system", '{"messages":[]}')
        self.assertEqual(result, '{"kind":"none"}')
        request = send.call_args.args[0]
        body = json.loads(request.data)
        self.assertEqual(body["model"], "example-model")
        self.assertEqual(body["messages"], [
            {"role": "system", "content": "system"},
            {"role": "user", "content": '{"messages":[]}'},
        ])
        self.assertEqual(request.get_header("Authorization"), "Bearer test-key")

    def test_rejects_plain_http_when_key_is_present(self):
        with self.assertRaisesRegex(ValueError, "HTTPS"):
            ChatCompletionsProvider("http://llm.example.test/v1/chat/completions", "model", "secret")

    def test_rejects_missing_choice_without_leaking_key(self):
        provider = ChatCompletionsProvider("https://llm.example.test/v1/chat/completions", "model", "secret")
        with patch("app.agents.providers.urlopen", return_value=Response({"choices": []})):
            with self.assertRaises(ModelProviderError) as caught:
                provider.complete("system", "data")
        self.assertNotIn("secret", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
