import io
import json
import unittest
from unittest.mock import patch

from backend.agents.assignment_change.provider import GigaChatModel, ProviderError


def reply(payload):
    return io.BytesIO(json.dumps(payload).encode())


class GigaChatProviderTests(unittest.TestCase):
    def test_oauth_then_structured_chat_request(self):
        answers = [
            reply({"access_token": "token-1", "expires_at": 4102444800000}),
            reply({"choices": [{"message": {"content": '{"changes": []}'}, "finish_reason": "stop"}]}),
        ]
        with patch("backend.agents.assignment_change.provider.urllib.request.urlopen", side_effect=answers) as send:
            result = GigaChatModel("dummy-credentials").extract({"messages": []})
        self.assertEqual(result, '{"changes": []}')
        oauth, chat = (call.args[0] for call in send.call_args_list)
        self.assertEqual(oauth.get_header("Authorization"), "Basic dummy-credentials")
        self.assertEqual(chat.get_header("Authorization"), "Bearer token-1")
        body = json.loads(chat.data)
        self.assertEqual(body["model"], "GigaChat-2")
        self.assertEqual(body["response_format"]["type"], "json_schema")
        self.assertEqual(body["messages"][0]["role"], "system")

    def test_token_is_reused_until_expiry(self):
        model = GigaChatModel("dummy-credentials")
        answers = [
            reply({"access_token": "token-1", "expires_at": 4102444800000}),
            reply({"choices": [{"message": {"content": "{}"}}]}),
            reply({"choices": [{"message": {"content": "{}"}}]}),
        ]
        with patch("backend.agents.assignment_change.provider.urllib.request.urlopen", side_effect=answers) as send:
            model.extract({})
            model.extract({})
        self.assertEqual(send.call_count, 3)

    def test_empty_content_is_error(self):
        answers = [
            reply({"access_token": "token-1", "expires_at": 4102444800000}),
            reply({"choices": [{"message": {"content": ""}}]}),
        ]
        with patch("backend.agents.assignment_change.provider.urllib.request.urlopen", side_effect=answers), self.assertRaises(ProviderError):
            GigaChatModel("dummy-credentials").extract({})


if __name__ == "__main__":
    unittest.main()
