import json
from datetime import timedelta

from sqlalchemy import select, update
from sqlalchemy.orm import Session

from app.models import Draft, TelegramInbox, TelegramIntegration, utc_now
from app.telegram import process_ready_messages, queue_text_message


class Provider:
    model_name = "fixture"

    def __init__(self):
        self.calls = 0

    def complete(self, prompt, payload):
        self.calls += 1
        messages = json.loads(payload)["messages"]
        ids = [m["id"] for m in messages]
        complete = any("странице" in m["text"] for m in messages)
        if "НОВОЕ домашнее" in prompt:
            return json.dumps(
                {
                    "kind": "new_homework" if complete else "incomplete_homework",
                    "text": "Решить: стр. 20, № 4, 5" if complete else None,
                    "source_ids": ids,
                    "uncertain": not complete,
                }
            )
        if "привязываешь" in prompt:
            return json.dumps(
                {
                    "subject_mention": "математике",
                    "subgroup_mentions": None,
                    "deadline_kind": "next_lesson",
                    "deadline_date": None,
                    "source_ids": ids,
                }
            )
        if "дубли" in prompt:
            return '{"duplicates": []}'
        if "учебные материалы" in prompt:
            return '{"materials": []}'
        return '{"changes": []}'


def enqueue(setup, provider, message_id=10, text="Сообщение"):
    queue_text_message(setup["engine"], "chat", "topic", message_id, text, utc_now())
    with setup["engine"].begin() as db:
        db.execute(
            update(TelegramInbox).values(received_at=utc_now() - timedelta(minutes=1))
        )
    return process_ready_messages(
        setup["engine"], provider, "fixture", five_agents=True
    )


def connect(setup):
    with setup["engine"].begin() as db:
        db.execute(
            TelegramIntegration.__table__.insert(),
            {"group_id": setup["group"], "chat_id": "chat", "topic_id": "topic"},
        )


def test_noise_does_not_create_review_and_topic_filter_precedes_agents(setup):
    class Noise(Provider):
        def complete(self, prompt, payload):
            if "НОВОЕ домашнее" in prompt:
                self.calls += 1
                return '{"kind":"none","text":null,"source_ids":[],"uncertain":false}'
            return super().complete(prompt, payload)

    connect(setup)
    provider = Noise()
    assert not queue_text_message(
        setup["engine"], "chat", "other-topic", 10, "Привет", utc_now()
    )
    assert (
        process_ready_messages(setup["engine"], provider, "fixture", five_agents=True)
        == []
    )
    assert provider.calls == 0
    assert enqueue(setup, provider, text="Привет") == [None]
    assert provider.calls == 5


def test_model_failure_is_reviewable_not_silent_noise(setup):
    class Failed(Provider):
        def complete(self, *_):
            raise RuntimeError("unavailable")

    connect(setup)
    result = enqueue(setup, Failed())
    with Session(setup["engine"]) as db:
        draft = db.get(Draft, result[0])
        assert all(run["status"] == "error" for run in draft.proposal_set["runs"])
        assert draft.proposal_set["summary"]["state"] == "needs_review"
    response = setup["client"].post(
        f"/groups/{setup['group']}/review/{result[0]}/decision",
        headers={"Authorization": "Bearer " + setup["users"]["admin"]},
        json={
            "action": "approve",
            "expected_version": 1,
            "text": "Предложения требуют проверки",
            "lesson_id": setup["lesson"],
        },
    )
    assert response.status_code == 422


def test_unrelated_message_does_not_modify_waiting_draft(setup):
    class Unrelated(Provider):
        def complete(self, prompt, payload):
            if "НОВОЕ домашнее" in prompt:
                self.calls += 1
                return '{"kind":"none","text":null,"source_ids":[],"uncertain":false}'
            return super().complete(prompt, payload)

    connect(setup)
    original = enqueue(
        setup, Provider(), text="К следующей паре по математике нужно решить"
    )[0]
    assert enqueue(setup, Unrelated(), 11, "Спасибо") == [None]
    with Session(setup["engine"]) as db:
        draft = db.get(Draft, original)
        assert draft.version == 1
        assert draft.proposal_set["summary"]["state"] == "waiting"


def test_disconnected_source_during_model_run_is_not_saved(setup):
    import pytest

    from app.ingestion import SourceNotConnected

    connect(setup)

    class Disconnect(Provider):
        def complete(self, prompt, payload):
            with setup["engine"].begin() as db:
                db.execute(
                    TelegramIntegration.__table__.delete().where(
                        TelegramIntegration.group_id == setup["group"]
                    )
                )
            return super().complete(prompt, payload)

    with pytest.raises(SourceNotConnected):
        enqueue(setup, Disconnect())
    with Session(setup["engine"]) as db:
        assert db.scalar(select(TelegramInbox.processed_at)) is None


def test_material_link_is_proposed_from_trusted_source_not_published_as_homework(setup):
    class Links(Provider):
        def complete(self, prompt, payload):
            if "НОВОЕ домашнее" in prompt:
                return '{"kind":"none","text":null,"source_ids":[],"uncertain":false}'
            if "учебные материалы" in prompt:
                context = json.loads(payload)
                attachment = context["messages"][0]["attachments"][0]
                assert attachment["url"] == "https://example.test/book.pdf"
                return json.dumps(
                    {
                        "materials": [
                            {
                                "attachment_id": attachment["id"],
                                "source_ids": [10],
                                "category_id": "Учебники",
                                "subject_ids": ["Математика"],
                                "assignment_ids": [],
                                "reason": "Учебник",
                                "uncertain": False,
                            }
                        ]
                    }
                )
            return super().complete(prompt, payload)

    connect(setup)
    result = enqueue(
        setup, Links(), text="Учебник по математике https://example.test/book.pdf"
    )
    with Session(setup["engine"]) as db:
        draft = db.get(Draft, result[0])
        assert draft.proposal_set["summary"]["homework"] is False
        material = next(
            r
            for r in draft.proposal_set["runs"]
            if r["agent_id"] == "material_proposal"
        )
        assert material["status"] == "proposed"
        assert material["proposals"][0]["fields"]["attachment_id"] == "10:link:0"
    # Exercise the production API registration, not an isolated review router.
    response = setup["client"].post(
        f"/groups/{setup['group']}/review/{result[0]}/proposals/3/0/decision",
        headers={"Authorization": "Bearer " + setup["users"]["admin"]},
        json={"action": "approve", "expected_version": 1, "text": "Учебник"},
    )
    assert response.status_code == 200, response.text
    assert response.json()["material_id"]


def test_homework_publish_requires_reviewing_other_actions(setup):
    with Session(setup["engine"]) as db, db.begin():
        draft = db.get(Draft, setup["draft"])
        draft.proposal_set = {
            "schema_version": 2,
            "summary": {"homework": True},
            "runs": [
                {
                    "agent_id": "duplicate_conflict",
                    "status": "proposed",
                    "proposals": [
                        {"proposal_type": "duplicate_conflict", "fields": {}}
                    ],
                }
            ],
        }
    path = f"/groups/{setup['group']}/review/{setup['draft']}"
    headers = {"Authorization": "Bearer " + setup["users"]["admin"]}
    body = {
        "action": "approve",
        "expected_version": 1,
        "text": "Решить номера",
        "lesson_id": setup["lesson"],
    }
    response = setup["client"].post(path + "/decision", headers=headers, json=body)
    assert response.status_code == 422
    assert (
        setup["client"]
        .get(f"/groups/{setup['group']}/assignments", headers=headers)
        .json()
        == []
    )
    response = setup["client"].post(
        path + "/proposals/0/0/decision",
        headers=headers,
        json={"action": "reject", "expected_version": 1},
    )
    assert response.status_code == 200
    body["expected_version"] = 2
    assert (
        setup["client"].post(path + "/decision", headers=headers, json=body).status_code
        == 200
    )


def test_binding_cannot_borrow_subject_from_other_message(setup):
    class Mixed(Provider):
        def complete(self, prompt, payload):
            if "НОВОЕ домашнее" in prompt:
                return json.dumps(
                    {
                        "kind": "new_homework",
                        "text": "Решить № 4, 5",
                        "source_ids": [10],
                        "uncertain": False,
                    }
                )
            # Binding cites both messages. Its only subject evidence is outside the homework.
            return super().complete(prompt, payload)

    connect(setup)
    queue_text_message(setup["engine"], "chat", "topic", 10, "Решить №4, 5", utc_now())
    result = enqueue(setup, Mixed(), 11, "По математике следующая пара завтра")
    with Session(setup["engine"]) as db:
        summary = db.get(Draft, result[0]).proposal_set["summary"]
        assert summary["state"] == "needs_review"
        assert summary["lesson_id"] is None
        assert summary["subject"] is None


def test_legacy_rejected_core_proposal_cannot_be_published(setup):
    with Session(setup["engine"]) as db, db.begin():
        db.get(Draft, setup["draft"]).proposal_set = {
            "summary": {"homework": True},
            "runs": [
                {
                    "proposals": [
                        {
                            "proposal_type": "new_homework",
                            "decision": {"status": "rejected"},
                        }
                    ]
                }
            ],
        }
    response = setup["client"].post(
        f"/groups/{setup['group']}/review/{setup['draft']}/decision",
        headers={"Authorization": "Bearer " + setup["users"]["admin"]},
        json={
            "action": "approve",
            "expected_version": 1,
            "text": "Решить",
            "lesson_id": setup["lesson"],
        },
    )
    assert response.status_code == 422


def test_waiting_draft_is_completed_without_duplication_and_published_only_by_admin(
    setup,
):
    s = setup
    with s["engine"].begin() as db:
        db.execute(
            TelegramIntegration.__table__.insert(),
            {"group_id": s["group"], "chat_id": "chat", "topic_id": "topic"},
        )
    provider = Provider()
    for message_id, text in [
        (10, "К следующей паре по математике нужно решить"),
        (11, "номера 4 и 5 на странице 20"),
    ]:
        queue_text_message(s["engine"], "chat", "topic", message_id, text, utc_now())
        with s["engine"].begin() as db:
            db.execute(
                update(TelegramInbox).values(
                    received_at=utc_now() - timedelta(minutes=1)
                )
            )
        result = process_ready_messages(
            s["engine"], provider, "fixture", five_agents=True
        )
        with Session(s["engine"]) as db:
            draft = db.get(Draft, result[0])
            summary = draft.proposal_set["summary"]
            assert summary["subject"] == "Математика"
            assert summary["lesson_id"] == s["lesson"]
            assert len(draft.proposal_set["runs"]) == 5
            if message_id == 10:
                draft_id = draft.id
                assert summary["state"] == "waiting"
                assert summary["text"] is None
            else:
                assert draft.id == draft_id
                assert draft.version == 2
                assert summary["state"] == "ready"
                assert draft.text == "Решить: стр. 20, № 4, 5"
                assert [m["id"] for m in draft.source_context["messages"]] == [10, 11]
    assert provider.calls == 10
    assert (
        process_ready_messages(s["engine"], provider, "fixture", five_agents=True) == []
    )
    headers = {"Authorization": "Bearer " + s["users"]["admin"]}
    stale = s["client"].post(
        f"/groups/{s['group']}/review/{draft_id}/decision",
        headers=headers,
        json={
            "action": "approve",
            "expected_version": 1,
            "lesson_id": s["lesson"],
            "text": "Старое содержание",
        },
    )
    assert stale.status_code == 409
    assert (
        s["client"].get(f"/groups/{s['group']}/assignments", headers=headers).json()
        == []
    )
    response = s["client"].post(
        f"/groups/{s['group']}/review/{draft_id}/decision",
        headers=headers,
        json={
            "action": "approve",
            "expected_version": 2,
            "lesson_id": s["lesson"],
            "text": "Решить: стр. 20, № 4, 5",
        },
    )
    assert response.status_code == 200
    with Session(s["engine"]) as db:
        assert len(list(db.scalars(select(Draft).where(Draft.id == draft_id)))) == 1
    enqueue(s, Provider(), 12, "номера 4 и 5 на странице 20")
    with Session(s["engine"]) as db:
        approved = db.get(Draft, draft_id)
        assert approved.status == "approved"
        assert approved.version == 3
        assert len(approved.source_context["messages"]) == 2
