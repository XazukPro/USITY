import json
import time
from unittest.mock import patch

from app.agents.contracts import EventBundle, SourceMessage
from app.agents.providers import GigaChatProvider
from app.agents.registry import AGENT_IDS, build_default_agents, run_all_agents


class Response:
    def __init__(self, body):
        self.body = body

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def read(self):
        return json.dumps(self.body).encode()


def test_five_agents_request_their_own_gigachat_schema_and_share_oauth():
    outputs = {
        "kind": {"kind": "none", "text": None, "source_ids": [], "uncertain": False},
        "subject_mention": {"subject_mention": None, "subgroup_mentions": None,
                            "deadline_kind": "none", "deadline_date": None, "source_ids": [10]},
        "duplicates": {"duplicates": []},
        "materials": {"materials": []},
        "changes": {"changes": []},
    }
    schemas = []

    def reply(request, **_kwargs):
        if request.full_url == GigaChatProvider.OAUTH_URL:
            return Response({"access_token": "token", "expires_at": time.time() + 1800})
        schema = json.loads(request.data)["response_format"]["schema"]
        keys = schema["properties"]
        key = next(key for key in outputs if key in keys)
        schemas.append(key)
        return Response({"choices": [{"message": {"content": json.dumps(outputs[key])}}]})

    bundle = EventBundle(
        "group", "chat", "topic", "chat", "topic",
        (SourceMessage(10, "chat", "topic", "ДЗ по математике", "2026-11-17T10:00:00+03:00"),),
    )
    provider = GigaChatProvider("test-key", model="GigaChat-2")
    with patch("app.agents.providers.urlopen", side_effect=reply) as send:
        runs = run_all_agents(bundle, build_default_agents(provider, "2026-11-17T12:00:00+03:00"))

    assert [run.agent_id for run in runs] == list(AGENT_IDS)
    assert [run.status for run in runs] == ["not_found", "proposed", "not_found", "not_found", "not_found"]
    assert schemas == ["kind", "subject_mention", "duplicates", "materials", "changes"]
    assert send.call_count == 6
    assert all(run.model_version == "GigaChat-2" for run in runs)
