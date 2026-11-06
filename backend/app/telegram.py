"""Telegram topic connection and durable text inbox.

Only the connected chat and topic are stored. The bot never trusts a group ID
from a Telegram message; it resolves the group from the active integration.
"""

from datetime import UTC, datetime, timedelta
from hashlib import sha256
from secrets import token_urlsafe

from sqlalchemy import delete, select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.dialects.sqlite import insert as sqlite_insert
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.agents.homework import EventBundle, Message
from app.ingestion import SourceNotConnected, ingest_homework
from app.models import (
    Membership,
    TelegramConnectCode,
    TelegramInbox,
    TelegramIntegration,
    utc_now,
)

CONNECT_CODE_LIFETIME = timedelta(minutes=10)
QUIET_PERIOD = timedelta(seconds=30)
ADJACENT_WINDOW = timedelta(seconds=90)
MAX_BUNDLE_MESSAGES = 20


class ConnectionDenied(ValueError):
    pass


def _hash(value):
    return sha256(value.encode()).hexdigest()


def issue_connect_code(db: Session, member: Membership) -> tuple[str, datetime]:
    if member.role != "owner":
        raise ConnectionDenied("Код подключения доступен только владельцу")
    code = token_urlsafe(24)
    expires_at = utc_now() + CONNECT_CODE_LIFETIME
    db.merge(
        TelegramConnectCode(
            group_id=member.group_id,
            code_hash=_hash(code),
            expires_at=expires_at,
        )
    )
    db.commit()
    return code, expires_at


def connection_status(db: Session, group_id: str) -> dict:
    integration = db.get(TelegramIntegration, group_id)
    return (
        {"connected": False}
        if integration is None
        else {
            "connected": True,
            "chat_id": integration.chat_id,
            "topic_id": integration.topic_id,
        }
    )


def connect_topic(engine, code: str, chat_id: str, topic_id: str, user_id: str):
    if not code or len(code) > 200 or not all((chat_id, topic_id, user_id)):
        raise ConnectionDenied("Неверный код или тема")
    try:
        with Session(engine) as db, db.begin():
            pending = db.scalar(
                select(TelegramConnectCode)
                .where(TelegramConnectCode.code_hash == _hash(code))
                .with_for_update()
            )
            if pending is None or pending.expires_at <= utc_now():
                raise ConnectionDenied("Код недействителен или истёк")
            if db.get(TelegramIntegration, pending.group_id) is not None:
                raise ConnectionDenied("Для группы уже подключена тема")
            if db.scalar(
                select(TelegramIntegration.group_id).where(
                    TelegramIntegration.chat_id == chat_id,
                    TelegramIntegration.topic_id == topic_id,
                )
            ):
                raise ConnectionDenied("Эта тема уже подключена")
            db.add(
                TelegramIntegration(
                    group_id=pending.group_id,
                    chat_id=chat_id,
                    topic_id=topic_id,
                    owner_telegram_id=user_id,
                )
            )
            group_id = pending.group_id
            db.delete(pending)
    except IntegrityError as exc:
        raise ConnectionDenied("Тема уже подключена") from exc
    return group_id


def disconnect_topic(engine, chat_id: str, topic_id: str, user_id: str) -> bool:
    with Session(engine) as db, db.begin():
        integration = db.scalar(
            select(TelegramIntegration)
            .where(
                TelegramIntegration.chat_id == chat_id,
                TelegramIntegration.topic_id == topic_id,
            )
            .with_for_update()
        )
        if integration is None:
            return False
        if integration.owner_telegram_id != user_id:
            raise ConnectionDenied("Отключить тему может только владелец")
        db.execute(
            delete(TelegramInbox).where(TelegramInbox.group_id == integration.group_id)
        )
        db.delete(integration)
    return True


def topic_status(engine, chat_id: str, topic_id: str) -> bool:
    with Session(engine) as db:
        return (
            db.scalar(
                select(TelegramIntegration.group_id).where(
                    TelegramIntegration.chat_id == chat_id,
                    TelegramIntegration.topic_id == topic_id,
                )
            )
            is not None
        )


def queue_text_message(
    engine, chat_id: str, topic_id: str, message_id: int, text: str, sent_at: datetime
) -> bool:
    if (
        type(message_id) is not int
        or message_id <= 0
        or not isinstance(text, str)
        or not text.strip()
        or len(text) > 20000
        or text.lstrip().startswith("/")
        or sent_at.tzinfo is None
        or sent_at.utcoffset() is None
    ):
        return False
    with Session(engine) as db, db.begin():
        integration = db.scalar(
            select(TelegramIntegration).where(
                TelegramIntegration.chat_id == chat_id,
                TelegramIntegration.topic_id == topic_id,
            ).with_for_update()
        )
        if integration is None:
            return False
        insert = pg_insert if engine.dialect.name == "postgresql" else sqlite_insert
        db.execute(
            insert(TelegramInbox)
            .values(
                chat_id=chat_id,
                topic_id=topic_id,
                message_id=message_id,
                group_id=integration.group_id,
                text=text,
                sent_at=sent_at,
                received_at=utc_now(),
            )
            .on_conflict_do_nothing(
                index_elements=["chat_id", "topic_id", "message_id"]
            )
        )
    return True


def _ready_bundles(rows, cutoff):
    """Keep nearby messages together; wait until the latest message is quiet."""
    pending = []
    for row in rows:
        if pending and (
            row.sent_at - pending[-1].sent_at > ADJACENT_WINDOW
            or len(pending) == MAX_BUNDLE_MESSAGES
        ):
            if max(item.received_at for item in pending) <= cutoff:
                yield pending
            pending = []
        pending.append(row)
    if pending and max(item.received_at for item in pending) <= cutoff:
        yield pending


def process_ready_messages(engine, provider, model_version: str) -> list[str | None]:
    """Called by the bot worker; a failed model call leaves messages for retry."""
    cutoff = utc_now() - QUIET_PERIOD
    with Session(engine) as db:
        integrations = list(db.scalars(select(TelegramIntegration)))
    results = []
    for integration in integrations:
        with Session(engine) as db, db.begin():
            rows = list(
                db.scalars(
                    select(TelegramInbox)
                    .where(
                        TelegramInbox.group_id == integration.group_id,
                        TelegramInbox.chat_id == integration.chat_id,
                        TelegramInbox.topic_id == integration.topic_id,
                        TelegramInbox.event_id.is_(None),
                    )
                    .order_by(TelegramInbox.sent_at, TelegramInbox.message_id)
                    .with_for_update()
                )
            )
            for chunk in _ready_bundles(rows, cutoff):
                first, last = chunk[0], chunk[-1]
                event_key = f"{integration.chat_id}:{integration.topic_id}:{first.message_id}:{last.message_id}"
                event_id = "tg:" + _hash(event_key)
                for row in chunk:
                    row.event_id = event_id
        with Session(engine) as db:
            pending = list(
                db.scalars(
                    select(TelegramInbox)
                    .where(
                        TelegramInbox.group_id == integration.group_id,
                        TelegramInbox.chat_id == integration.chat_id,
                        TelegramInbox.topic_id == integration.topic_id,
                        TelegramInbox.event_id.is_not(None),
                        TelegramInbox.processed_at.is_(None),
                    )
                    .order_by(TelegramInbox.sent_at, TelegramInbox.message_id)
                )
            )
        by_event = {}
        for row in pending:
            by_event.setdefault(row.event_id, []).append(row)
        for event_id, chunk in by_event.items():
            bundle = EventBundle(
                group_id=integration.group_id,
                topic_id=integration.topic_id,
                messages=tuple(
                    Message(
                        id=row.message_id,
                        text=row.text,
                        sent_at=row.sent_at.astimezone(UTC).isoformat(),
                    )
                    for row in chunk
                ),
            )
            draft_id = ingest_homework(
                engine, event_id, integration.chat_id, bundle, provider, model_version
            )
            with Session(engine) as marking, marking.begin():
                active = marking.get(TelegramIntegration, integration.group_id)
                if (
                    active is None
                    or active.chat_id != integration.chat_id
                    or active.topic_id != integration.topic_id
                ):
                    raise SourceNotConnected("Источник отключен")
                for row in chunk:
                    current = marking.get(
                        TelegramInbox,
                        (row.chat_id, row.topic_id, row.message_id),
                    )
                    if current is not None and current.event_id == event_id:
                        current.processed_at = utc_now()
            results.append(draft_id)
    return results
