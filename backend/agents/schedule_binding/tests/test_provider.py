import io
import json
import time
import unittest
import urllib.error
import uuid
from unittest.mock import patch

from backend.agents.schedule_binding.provider import GigaChatModel, ProviderError


def response(data):
    return io.BytesIO(json.dumps(data).encode("utf-8"))


class ProviderTests(unittest.TestCase):
    def test_oauth_then_structured_chat_and_cached_token(self):
        token = {"access_token": "temporary-token", "expires_at": time.time() + 1800}
        reply = {"choices": [{"finish_reason": "stop", "message": {"content": '{"subject_mention":"матан"}'}}]}
        with patch(
            "backend.agents.schedule_binding.provider.urllib.request.urlopen",
            side_effect=[response(token), response(reply), response(reply)],
        ) as send:
            model = GigaChatModel("dummy-authorization-key", "GigaChat-2")
            result = model.extract({"messages": []})
            again = model.extract({"messages": []})
        self.assertEqual(result, '{"subject_mention":"матан"}')
        self.assertEqual(again, result)
        self.assertEqual(send.call_count, 3)
        auth_request = send.call_args_list[0].args[0]
        self.assertEqual(auth_request.full_url, "https://ngw.devices.sberbank.ru:9443/api/v2/oauth")
        self.assertEqual(auth_request.get_header("Authorization"), "Basic dummy-authorization-key")
        self.assertEqual(uuid.UUID(auth_request.get_header("Rquid")).version, 4)
        self.assertEqual(auth_request.data, b"scope=GIGACHAT_API_PERS")
        chat_request = send.call_args_list[1].args[0]
        self.assertEqual(chat_request.full_url, "https://api.giga.chat/v1/chat/completions")
        self.assertEqual(chat_request.get_header("Authorization"), "Bearer temporary-token")
        body = json.loads(chat_request.data)
        self.assertEqual(body["model"], "GigaChat-2")
        self.assertEqual(body["messages"][0]["role"], "system")
        self.assertEqual(body["response_format"]["type"], "json_schema")
        self.assertTrue(body["response_format"]["strict"])
        self.assertIn("subject_mention", body["response_format"]["schema"]["required"])
        self.assertIsNotNone(send.call_args_list[1].kwargs["context"])

    def test_expired_token_is_refreshed(self):
        first = {"access_token": "first", "expires_at": time.time() + 30}
        second = {"access_token": "second", "expires_at": time.time() + 1800}
        reply = {"choices": [{"message": {"content": "{}"}}]}
        with patch(
            "backend.agents.schedule_binding.provider.urllib.request.urlopen",
            side_effect=[response(first), response(reply), response(second), response(reply)],
        ) as send:
            model = GigaChatModel("dummy-key")
            model.extract({})
            model.extract({})
        self.assertEqual(send.call_count, 4)
        self.assertEqual(send.call_args_list[3].args[0].get_header("Authorization"), "Bearer second")

    def test_unauthorized_chat_refreshes_once(self):
        first = {"access_token": "first", "expires_at": time.time() + 1800}
        second = {"access_token": "second", "expires_at": time.time() + 1800}
        unauthorized = urllib.error.HTTPError("https://api.giga.chat/v1/chat/completions", 401, "Unauthorized", {}, None)
        reply = {"choices": [{"message": {"content": "{}"}}]}
        with patch(
            "backend.agents.schedule_binding.provider.urllib.request.urlopen",
            side_effect=[response(first), unauthorized, response(second), response(reply)],
        ) as send:
            result = GigaChatModel("dummy-key").extract({})
        self.assertEqual(result, "{}")
        self.assertEqual(send.call_count, 4)

    def test_blacklist_and_malformed_response_are_errors(self):
        token = {"access_token": "temporary", "expires_at": time.time() + 1800}
        with patch("backend.agents.schedule_binding.provider.urllib.request.urlopen", side_effect=[
            response(token), response({"choices": [{"finish_reason": "blacklist", "message": {"content": ""}}]}),
        ]), self.assertRaises(ProviderError):
            GigaChatModel("dummy-key").extract({})
        with patch("backend.agents.schedule_binding.provider.urllib.request.urlopen", side_effect=[
            response(token), response({"choices": []}),
        ]), self.assertRaises(ProviderError):
            GigaChatModel("dummy-key").extract({})


if __name__ == "__main__":
    unittest.main()
