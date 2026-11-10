import json
from datetime import date

import pytest

from app.agents.assignment_changes import run_assignment_change
from app.agents.contracts import EventBundle, SourceMessage


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
                text="ДЗ отменяется",
                sent_at="2026-11-08T10:00:00+03:00",
            ),
        ),
        active_assignments=({"id": "assignment-1", "text": "Решить 4 и 5"},),
    )


def test_proposes_cancellation_without_mutating_assignment():
    run = run_assignment_change(
        bundle(),
        FixedProvider(
            {
                "changes": [
                    {
                        "kind": "cancel",
                        "assignment_id": "assignment-1",
                        "source_ids": [1],
                        "new_text": None,
                        "new_due_date": None,
                        "reason": "Явная отмена.",
                        "uncertain": False,
                    }
                ]
            }
        ),
        date(2026, 11, 8),
    )

    assert run.agent_id == "assignment_change"
    assert run.status == "proposed"
    assert run.proposals[0].fields["kind"] == "cancel"
    assert run.proposals[0].fields["assignment_id"] == "assignment-1"


def test_rejects_unknown_assignment():
    with pytest.raises(ValueError, match="assignment"):
        run_assignment_change(
            bundle(),
            FixedProvider(
                {
                    "changes": [
                        {
                            "kind": "cancel",
                            "assignment_id": "unknown",
                            "source_ids": [1],
                            "new_text": None,
                            "new_due_date": None,
                            "reason": "Отмена.",
                            "uncertain": False,
                        }
                    ]
                }
            ),
            date(2026, 11, 8),
        )

