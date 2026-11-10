import json
from datetime import datetime

import pytest

from app.agents.contracts import EventBundle, SourceMessage
from app.agents.schedule_binding import run_schedule_binding


class FixedProvider:
    model_name = "gigachat-test"

    def __init__(self, response):
        self.response = response

    def complete(self, system_prompt, event_json):
        assert "недоверенные" in system_prompt
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
                id=7,
                chat_id="-100123",
                topic_id="42",
                text="По матану к следующей паре решить листок",
                sent_at="2026-11-08T10:00:00+03:00",
            ),
        ),
        subjects=(
            {"id": "math", "name": "Математический анализ", "aliases": ["матан"]},
        ),
        lessons=(
            {
                "id": "math-1",
                "subject_id": "math",
                "starts_at": "2026-11-10T09:00:00+03:00",
                "subgroup_ids": [],
            },
        ),
    )


def test_binds_subject_alias_to_next_future_lesson():
    provider = FixedProvider(
        {
            "subject_mention": "матану",
            "subgroup_mentions": [],
            "deadline_kind": "next_lesson",
            "deadline_date": None,
            "source_ids": [7],
        }
    )

    run = run_schedule_binding(
        bundle(), provider, datetime.fromisoformat("2026-11-08T12:00:00+03:00")
    )

    assert run.agent_id == "schedule_binding"
    assert run.status == "proposed"
    assert run.proposals[0].fields["subject_id"] == "math"
    assert run.proposals[0].fields["lesson_id"] == "math-1"
    assert run.proposals[0].source_ids == (7,)


def test_rejects_hallucinated_source_id():
    provider = FixedProvider(
        {
            "subject_mention": "матан",
            "subgroup_mentions": [],
            "deadline_kind": "next_lesson",
            "deadline_date": None,
            "source_ids": [999],
        }
    )

    with pytest.raises(ValueError, match="source"):
        run_schedule_binding(
            bundle(), provider, datetime.fromisoformat("2026-11-08T12:00:00+03:00")
        )


def test_marks_past_explicit_deadline_for_admin_review():
    provider = FixedProvider(
        {
            "subject_mention": "матану",
            "subgroup_mentions": [],
            "deadline_kind": "date",
            "deadline_date": "2026-11-01",
            "source_ids": [7],
        }
    )

    run = run_schedule_binding(
        bundle(), provider, datetime.fromisoformat("2026-11-08T12:00:00+03:00")
    )

    assert run.proposals[0].fields["lesson_id"] is None
    assert "past_deadline" in run.proposals[0].uncertainty

