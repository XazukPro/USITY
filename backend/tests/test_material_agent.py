import json

import pytest

from app.agents.contracts import Attachment, EventBundle, SourceMessage
from app.agents.materials import run_material_proposal


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
                id=1,
                chat_id="-100123",
                topic_id="42",
                text="Конспект лекции",
                sent_at="2026-11-08T10:00:00+03:00",
                attachments=(
                    Attachment(
                        id="file-1",
                        kind="file",
                        size_bytes=1000,
                        mime_type="application/pdf",
                        file_name="lecture.pdf",
                    ),
                ),
            ),
        ),
        subjects=({"id": "math", "name": "Матан"},),
        categories=({"id": "lectures", "name": "Лекции"},),
        active_assignments=({"id": "assignment-1", "subject_id": "math"},),
    )


def test_proposes_cited_pdf_material_without_publishing_it():
    run = run_material_proposal(
        bundle(),
        FixedProvider(
            {
                "materials": [
                    {
                        "source_ids": [1],
                        "attachment_id": "file-1",
                        "category_id": "lectures",
                        "subject_ids": ["math"],
                        "assignment_ids": ["assignment-1"],
                        "reason": "Конспект лекции по предмету.",
                        "uncertain": False,
                    }
                ]
            }
        ),
    )

    assert run.agent_id == "material_proposal"
    assert run.status == "proposed"
    assert run.proposals[0].fields["attachment_id"] == "file-1"


def test_rejects_oversized_attachment():
    oversized = bundle()
    message = oversized.messages[0]
    bad = Attachment(
        id="file-1",
        kind="file",
        size_bytes=100_000_001,
        mime_type="application/pdf",
        file_name="lecture.pdf",
    )
    oversized = EventBundle(
        **{**oversized.__dict__, "messages": (SourceMessage(**{**message.__dict__, "attachments": (bad,)}),)}
    )

    with pytest.raises(ValueError, match="attachment"):
        run_material_proposal(
            oversized,
            FixedProvider(
                {
                    "materials": [
                        {
                            "source_ids": [1],
                            "attachment_id": "file-1",
                            "category_id": "lectures",
                            "subject_ids": ["math"],
                            "assignment_ids": [],
                            "reason": "Файл.",
                            "uncertain": False,
                        }
                    ]
                }
            ),
        )

