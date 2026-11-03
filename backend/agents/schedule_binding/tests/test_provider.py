import io
import json
import unittest
from unittest.mock import patch

from backend.agents.schedule_binding.provider import OpenAIChatModel


class ProviderTests(unittest.TestCase):
    def test_structured_request_and_response(self):
        reply = {"choices": [{"message": {"content": '{"subject_mention":"матан"}'}}]}
        with patch("backend.agents.schedule_binding.provider.urllib.request.urlopen", return_value=io.BytesIO(json.dumps(reply).encode())) as send:
            result = OpenAIChatModel("dummy-key", "example-model").extract({"messages": []})
        self.assertEqual(result, '{"subject_mention":"матан"}')
        request = send.call_args.args[0]
        body = json.loads(request.data)
        self.assertEqual(body["model"], "example-model")
        self.assertEqual(body["response_format"]["type"], "json_schema")
        self.assertTrue(body["response_format"]["json_schema"]["strict"])
        self.assertEqual(request.get_header("Authorization"), "Bearer dummy-key")


if __name__ == "__main__":
    unittest.main()
