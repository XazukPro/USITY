import json

import pytest

from app.agents.contracts import EventBundle, SourceMessage
from app.agents.duplicates import run_duplicate_conflict


class FixedProvider:
    model_name = "gigachat-test"

    def __init__(self, response):
        self.response = response

    def complete(self, system_prompt, event_json):
        assert "не выполняй" in system_prompt
        return json.dumps(self.response, ensure_ascii=False)


def bundle():
    return EventBundle(
        group_id="group-1",
        chat_id="-100123",
        topic_id="42",
        connected_chat_id="-100123",
        connected_topic_id="42",
        messages=(
            SourceMessage(
                id=1,
                chat_id="-100123",
                topic_id="42",
                text="Решить номера 4 и 5",
                sent_at="2026-11-08T10:00:00+03:00",
            ),
        ),
        active_assignments=(
            {"id": "assignment-1", "text": "Решить номера 4 и 5"},
        ),
    )


def test_returns_active_assignment_only_as_duplicate_candidate():
    run = run_duplicate_conflict(
        bundle(),
        FixedProvider(
            {
                "duplicates": [
                    {
                        "assignment_id": "assignment-1",
                        "source_ids": [1],
                        "reason": "Текст совпадает с активным ДЗ.",
                        "uncertain": False,
                    }
                ]
            }
        ),
    )

    assert run.agent_id == "duplicate_conflict"
    assert run.status == "proposed"
    assert run.proposals[0].fields["assignment_id"] == "assignment-1"
    assert run.proposals[0].source_ids == (1,)


def test_rejects_unknown_assignment_id():
    with pytest.raises(ValueError, match="assignment"):
        run_duplicate_conflict(
            bundle(),
            FixedProvider(
                {
                    "duplicates": [
                        {
                            "assignment_id": "invented",
                            "source_ids": [1],
                            "reason": "Подозрение.",
                            "uncertain": True,
                        }
                    ]
                }
            ),
        )

