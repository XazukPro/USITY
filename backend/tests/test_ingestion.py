import json
from unittest.mock import Mock

import pytest
from sqlalchemy import select

from app.agents.homework import EventBundle, Message, ProposalError
from app.ingestion import IngestionConflict, SourceNotConnected, ingest_homework
from app.models import Draft, TelegramIntegration


@pytest.fixture
def incoming(setup):
    s = setup
    with s["engine"].begin() as db:
        db.execute(
            TelegramIntegration.__table__.insert(),
            {"group_id": s["group"], "chat_id": "-100123", "topic_id": "42"},
        )
    bundle = EventBundle(
        s["group"],
        "42",
        (
            Message(10, "На математику решить", "2026-11-02T10:00:00+03:00"),
            Message(11, "4 и 5", "2026-11-02T10:01:00+03:00"),
        ),
    )
    provider = Mock()
    provider.complete.return_value = json.dumps(
        {
            "kind": "new_homework",
            "text": "Решить 4 и 5",
            "source_ids": [10, 11],
            "uncertain": False,
        }
    )
    return s, bundle, provider


def ingest(incoming, **overrides):
    s, bundle, provider = incoming
    kwargs = {
        "engine": s["engine"],
        "event_id": "new-event",
        "chat_id": "-100123",
        "bundle": bundle,
        "provider": provider,
        "model_version": "fixture-v1",
    }
    kwargs.update(overrides)
    return ingest_homework(**kwargs)


def test_agent_preserves_source_raw_output_versions_without_publishing(incoming):
    s, _bundle, provider = incoming
    draft_id = ingest(incoming)
    with s["engine"].connect() as db:
        draft = db.execute(select(Draft).where(Draft.id == draft_id)).mappings().one()
        assert draft["status"] == "pending"
        assert len(draft["source_context"]["messages"]) == 2
        assert draft["source_context"]["chat_id"] == "-100123"
        assert draft["model_output"]["source_ids"] == [10, 11]
        assert draft["raw_output"] == provider.complete.return_value
        assert draft["model_version"] == "fixture-v1"
        assert draft["prompt_version"] == "homework-v1"


def test_wrong_chat_or_topic_never_reaches_model(incoming):
    _, bundle, provider = incoming
    with pytest.raises(SourceNotConnected):
        ingest(incoming, chat_id="-999")
    with pytest.raises(SourceNotConnected):
        ingest(incoming, bundle=EventBundle(bundle.group_id, "99", bundle.messages))
    provider.complete.assert_not_called()


def test_retry_is_idempotent_but_changed_payload_conflicts(incoming):
    _, bundle, provider = incoming
    first = ingest(incoming)
    assert ingest(incoming) == first
    assert provider.complete.call_count == 1
    with pytest.raises(IngestionConflict):
        ingest(
            incoming,
            bundle=EventBundle(
                bundle.group_id,
                "42",
                (Message(12, "Другой текст", "2026-11-02T10:02:00+03:00"),),
            ),
        )


def test_noise_and_model_failure_are_different(incoming):
    s, _, provider = incoming
    provider.complete.return_value = "not json"
    with pytest.raises(ProposalError):
        ingest(incoming)
    with s["engine"].connect() as db:
        assert (
            db.execute(
                select(Draft.id).where(
                    Draft.event_id == "new-event", Draft.group_id == s["group"]
                )
            ).first()
            is None
        )
    provider.complete.return_value = (
        '{"kind":"none","text":null,"source_ids":[],"uncertain":false}'
    )
    assert ingest(incoming) is None
    assert ingest(incoming) is None
    assert provider.complete.call_count == 2


def test_disconnect_during_model_call_does_not_store_draft(incoming):
    s, _, provider = incoming
    response = provider.complete.return_value

    def disconnect(*args):
        with s["engine"].begin() as db:
            db.execute(
                TelegramIntegration.__table__.delete().where(
                    TelegramIntegration.group_id == s["group"]
                )
            )
        return response

    provider.complete.side_effect = disconnect
    with pytest.raises(SourceNotConnected):
        ingest(incoming)


def test_parallel_event_retry_creates_one_draft(incoming):
    from concurrent.futures import ThreadPoolExecutor
    from threading import Barrier

    s, _, provider = incoming
    rendezvous = Barrier(2)
    response = provider.complete.return_value

    def model(*args):
        rendezvous.wait(timeout=5)
        return response

    provider.complete.side_effect = model
    with ThreadPoolExecutor(2) as pool:
        results = list(pool.map(lambda _: ingest(incoming), range(2)))
    assert results[0] == results[1]
    with s["engine"].connect() as db:
        assert (
            len(
                db.execute(
                    select(Draft.id).where(
                        Draft.group_id == s["group"], Draft.event_id == "new-event"
                    )
                ).all()
            )
            == 1
        )


def test_source_check_and_save_are_atomic_with_disconnect(incoming):
    from concurrent.futures import ThreadPoolExecutor
    from threading import Event

    from sqlalchemy import event

    s, _, _ = incoming
    inserting, disconnected = Event(), Event()

    def before_insert(conn, cursor, statement, parameters, context, many):
        if "INSERT INTO review_drafts" in statement:
            inserting.set()
            disconnected.wait(timeout=0.3)

    def disconnect():
        assert inserting.wait(timeout=5)
        with s["engine"].begin() as db:
            db.execute(
                TelegramIntegration.__table__.delete().where(
                    TelegramIntegration.group_id == s["group"]
                )
            )
            seen = db.execute(
                select(Draft.id).where(
                    Draft.group_id == s["group"], Draft.event_id == "new-event"
                )
            ).first()
        disconnected.set()
        return seen

    event.listen(s["engine"], "before_cursor_execute", before_insert)
    try:
        with ThreadPoolExecutor(2) as pool:
            deleting = pool.submit(disconnect)
            draft_id = ingest(incoming)
            seen_at_disconnect = deleting.result(timeout=10)
    finally:
        event.remove(s["engine"], "before_cursor_execute", before_insert)
    assert seen_at_disconnect is not None
    assert seen_at_disconnect[0] == draft_id
