import json
from datetime import UTC, datetime, timedelta
from unittest.mock import Mock

import pytest
from sqlalchemy import select, update
from sqlalchemy.orm import Session

from app.models import Draft, Membership, TelegramInbox, TelegramIntegration
from app.telegram import (
    ConnectionDenied,
    connect_topic,
    disconnect_topic,
    process_ready_messages,
    queue_text_message,
)


def headers(setup, name="admin"):
    return {"Authorization": "Bearer " + setup["users"][name]}


def test_only_owner_issues_one_time_code_and_controls_topic(setup):
    s = setup
    path = f"/groups/{s['group']}/telegram/connect-code"
    assert s["client"].post(path, headers=headers(s)).status_code == 403
    with s["engine"].begin() as db:
        db.execute(
            update(Membership)
            .where(Membership.user_id == s["users"]["admin"])
            .values(role="owner")
        )
    response = s["client"].post(path, headers=headers(s))
    assert response.status_code == 200
    code = response.json()["code"]
    assert len(code) >= 30
    group_id = connect_topic(s["engine"], code, "-100123", "42", "telegram-owner")
    assert group_id == s["group"]
    assert s["client"].get(
        f"/groups/{s['group']}/telegram", headers=headers(s)
    ).json() == {"connected": True, "chat_id": "-100123", "topic_id": "42"}
    with pytest.raises(ConnectionDenied):
        connect_topic(s["engine"], code, "-100123", "43", "telegram-owner")
    with pytest.raises(ConnectionDenied):
        disconnect_topic(s["engine"], "-100123", "42", "another-user")
    assert disconnect_topic(s["engine"], "-100123", "42", "telegram-owner")
    assert s["client"].get(
        f"/groups/{s['group']}/telegram", headers=headers(s)
    ).json() == {"connected": False}


def test_only_connected_topic_is_batched_and_retries_are_idempotent(setup):
    s = setup
    with s["engine"].begin() as db:
        db.execute(
            TelegramIntegration.__table__.insert(),
            {
                "group_id": s["group"],
                "chat_id": "-100123",
                "topic_id": "42",
                "owner_telegram_id": "tg-owner",
            },
        )
    sent = datetime.now(UTC)
    assert not queue_text_message(s["engine"], "-999", "42", 1, "чужой чат", sent)
    assert not queue_text_message(s["engine"], "-100123", "99", 2, "другая тема", sent)
    assert not queue_text_message(s["engine"], "-100123", "42", 3, "/status", sent)
    assert queue_text_message(s["engine"], "-100123", "42", 10, "ДЗ:", sent)
    assert queue_text_message(
        s["engine"], "-100123", "42", 11, "решить 4 и 5", sent + timedelta(seconds=20)
    )
    assert queue_text_message(s["engine"], "-100123", "42", 11, "повтор", sent)
    provider = Mock()
    provider.complete.return_value = json.dumps(
        {
            "kind": "new_homework",
            "text": "Решить 4 и 5",
            "source_ids": [10, 11],
            "uncertain": False,
        }
    )
    assert process_ready_messages(s["engine"], provider, "fixture") == []
    with s["engine"].begin() as db:
        db.execute(
            update(TelegramInbox).values(
                received_at=datetime.now(UTC) - timedelta(minutes=1)
            )
        )
    result = process_ready_messages(s["engine"], provider, "fixture")
    assert len(result) == 1 and result[0]
    assert process_ready_messages(s["engine"], provider, "fixture") == []
    assert provider.complete.call_count == 1
    with Session(s["engine"]) as db:
        draft = db.get(Draft, result[0])
        assert [message["id"] for message in draft.source_context["messages"]] == [
            10, 11
        ]
        assert draft.status == "pending"
        assert db.scalar(select(TelegramInbox.text).where(TelegramInbox.message_id == 11)) == "решить 4 и 5"
    assert disconnect_topic(s["engine"], "-100123", "42", "tg-owner")
    assert not queue_text_message(s["engine"], "-100123", "42", 12, "новое", sent)


def test_failed_model_call_keeps_original_bundle_for_retry(setup):
    s = setup
    with s["engine"].begin() as db:
        db.execute(
            TelegramIntegration.__table__.insert(),
            {
                "group_id": s["group"],
                "chat_id": "-100123",
                "topic_id": "42",
                "owner_telegram_id": "tg-owner",
            },
        )
    sent = datetime.now(UTC)
    assert queue_text_message(s["engine"], "-100123", "42", 10, "ДЗ: 4 и 5", sent)
    with s["engine"].begin() as db:
        db.execute(
            update(TelegramInbox).values(
                received_at=datetime.now(UTC) - timedelta(minutes=1)
            )
        )
    provider = Mock()
    provider.complete.side_effect = RuntimeError("temporary model error")
    with pytest.raises(RuntimeError):
        process_ready_messages(s["engine"], provider, "fixture")
    assert queue_text_message(
        s["engine"], "-100123", "42", 11, "ДЗ: 6 и 7", sent + timedelta(seconds=15)
    )
    provider.complete.side_effect = None
    provider.complete.return_value = json.dumps(
        {
            "kind": "new_homework",
            "text": "Решить 4 и 5",
            "source_ids": [10],
            "uncertain": False,
        }
    )
    results = process_ready_messages(s["engine"], provider, "fixture")
    assert len(results) == 1
    with Session(s["engine"]) as db:
        assert [
            row.message_id
            for row in db.scalars(
                select(TelegramInbox).where(TelegramInbox.processed_at.is_(None))
            )
        ] == [11]
