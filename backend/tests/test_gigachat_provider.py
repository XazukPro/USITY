import json
import time
from unittest.mock import patch
from urllib.error import HTTPError

import pytest

from app.agents.providers import GigaChatProvider, ModelProviderError


class Response:
    def __init__(self, body):
        self.body = body

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def read(self):
        return json.dumps(self.body).encode()


def test_gigachat_oauth_schema_and_token_cache():
    provider = GigaChatProvider("test-authorization-key")
    output = '{"kind":"none","text":null,"source_ids":[],"uncertain":false}'
    responses = [
        Response({"access_token": "short-lived-token", "expires_at": time.time() + 1800}),
        Response({"choices": [{"message": {"content": output}}]}),
        Response({"choices": [{"message": {"content": output}}]}),
    ]
    with patch("app.agents.providers.urlopen", side_effect=responses) as send:
        assert provider.complete("system", "event") == output
        assert provider.complete("system", "event") == output
    assert send.call_count == 3
    oauth = send.call_args_list[0].args[0]
    chat = send.call_args_list[1].args[0]
    assert oauth.get_header("Authorization") == "Basic test-authorization-key"
    assert chat.get_header("Authorization") == "Bearer short-lived-token"
    body = json.loads(chat.data)
    assert body["response_format"]["strict"] is True
    assert body["messages"][1]["content"] == "event"


def test_gigachat_provider_errors_do_not_expose_credentials():
    provider = GigaChatProvider("secret")
    with patch(
        "app.agents.providers.urlopen",
        side_effect=HTTPError(provider.OAUTH_URL, 401, "bad", {}, None),
    ), pytest.raises(ModelProviderError) as caught:
        provider.complete("system", "event")
    assert "secret" not in str(caught.value)
