"""Trusted worker boundary. Never called directly with client-selected group/source."""

import json
from dataclasses import asdict
from datetime import datetime
from hashlib import sha256

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.agents.homework import detect_homework
from app.models import Draft, IngestedEvent, TelegramIntegration

PROMPT_VERSION = "homework-v1"


class SourceNotConnected(ValueError):
    pass


class IngestionConflict(ValueError):
    pass


class RecordingProvider:
    def __init__(self, delegate):
        self.delegate = delegate
        self.raw = None

    def complete(self, system_prompt, event_json):
        self.raw = self.delegate.complete(system_prompt, event_json)
        return self.raw


def check_source(db, bundle, chat_id, lock=False):
    statement = select(TelegramIntegration).where(
        TelegramIntegration.group_id == bundle.group_id,
        TelegramIntegration.chat_id == chat_id,
        TelegramIntegration.topic_id == bundle.topic_id,
    )
    if lock:
        statement = statement.with_for_update()
    if db.scalar(statement) is None:
        raise SourceNotConnected("Источник не подключен к группе")


def previous_result(event, fingerprint):
    if event.payload_hash != fingerprint:
        raise IngestionConflict("event_id уже использован для другого содержимого")
    return event.draft_id


def ingest_homework(engine, event_id, chat_id, bundle, provider, model_version):
    """Return draft ID or None for noise; failures raise and can be retried.

    Concurrent retries can call the model twice; unique DB keys prevent duplicate
    drafts. Event batching and worker retries belong to the ingestion queue.
    """
    if (
        not event_id
        or len(event_id) > 200
        or not model_version
        or len(model_version) > 200
    ):
        raise ValueError("Нужны event_id и версия модели")
    if not bundle.messages or len(bundle.messages) > 100:
        raise ValueError("Пакет должен содержать от 1 до 100 сообщений")
    ids = [message.id for message in bundle.messages]
    if len(set(ids)) != len(ids) or any(type(i) is not int for i in ids):
        raise ValueError("ID сообщений должны быть уникальными целыми числами")
    for message in bundle.messages:
        if not isinstance(message.text, str) or len(message.text) > 20000:
            raise ValueError("Недопустимый текст сообщения")
        sent_at = datetime.fromisoformat(message.sent_at)
        if sent_at.tzinfo is None or sent_at.utcoffset() is None:
            raise ValueError("Время сообщения требует часовой пояс")
    context = {**asdict(bundle), "chat_id": chat_id}
    encoded = json.dumps(context, ensure_ascii=False, sort_keys=True)
    if len(encoded.encode()) > 200000:
        raise ValueError("Пакет слишком велик")
    fingerprint = sha256(encoded.encode()).hexdigest()
    with Session(engine) as db:
        check_source(db, bundle, chat_id)
        existing = db.get(IngestedEvent, (bundle.group_id, event_id))
        if existing:
            return previous_result(existing, fingerprint)
    recording = RecordingProvider(provider)
    proposal = detect_homework(bundle, recording)
    if proposal and len(proposal.text) > 20000:
        raise ValueError("Предложение слишком велико")
    try:
        with Session(engine) as db, db.begin():
            # The group can be disconnected while an external model is running.
            check_source(db, bundle, chat_id, lock=True)
            existing = db.get(IngestedEvent, (bundle.group_id, event_id))
            if existing:
                return previous_result(existing, fingerprint)
            draft_id = None
            if proposal:
                draft = Draft(
                    group_id=bundle.group_id,
                    event_id=event_id,
                    text=proposal.text,
                    source_context=json.loads(encoded),
                    raw_output=recording.raw,
                    model_output=json.loads(recording.raw),
                    model_version=model_version,
                    prompt_version=PROMPT_VERSION,
                )
                db.add(draft)
                db.flush()
                draft_id = draft.id
            db.add(
                IngestedEvent(
                    group_id=bundle.group_id,
                    event_id=event_id,
                    payload_hash=fingerprint,
                    draft_id=draft_id,
                )
            )
        return draft_id
    except IntegrityError:
        # SQLite has no row locks; unique keys are the final concurrency guard.
        with Session(engine) as db:
            existing = db.get(IngestedEvent, (bundle.group_id, event_id))
            if existing:
                return previous_result(existing, fingerprint)
        raise
