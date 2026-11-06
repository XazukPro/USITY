"""Synthetic end-to-end demo. The model response is a fixture, not a live LLM."""

import argparse
import json
import os
import secrets
from datetime import UTC, datetime, timedelta
from hashlib import sha256
from pathlib import Path
from tempfile import TemporaryDirectory
from uuid import uuid4

from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from app.agents.homework import EventBundle, Message
from app.api import create_app
from app.db import Base, make_engine
from app.ingestion import ingest_homework
from app.models import Membership, SessionToken, StudyGroup, TelegramIntegration


class FixtureProvider:
    def complete(self, system_prompt, event_json):
        return json.dumps(
            {
                "kind": "new_homework",
                "text": "Решить номера 4 и 5",
                "source_ids": [1, 2],
                "uncertain": False,
            },
            ensure_ascii=False,
        )


def prepare(url, fixture=True):
    engine = make_engine(url)
    Base.metadata.create_all(engine)
    group_id = str(uuid4())
    chat_id = "synthetic-" + group_id
    now = datetime.now(UTC)
    tokens = {
        role: secrets.token_urlsafe(32) for role in ("admin", "student", "student2")
    }
    with Session(engine) as db, db.begin():
        db.add(StudyGroup(id=group_id))
        db.flush()
        for role, token in tokens.items():
            user_id = role + "-" + group_id
            db.add(
                Membership(
                    user_id=user_id,
                    group_id=group_id,
                    role="owner" if role == "admin" else "student",
                )
            )
            db.flush()
            db.add(
                SessionToken(
                    user_id=user_id,
                    token_hash=sha256(token.encode()).hexdigest(),
                    expires_at=now + timedelta(hours=12),
                )
            )
        if fixture:
            db.add(TelegramIntegration(group_id=group_id, chat_id=chat_id, topic_id="42"))
    with TestClient(create_app(url)) as client:
        response = client.post(
            f"/groups/{group_id}/lessons",
            headers={"Authorization": "Bearer " + tokens["admin"]},
            json={
                "subject": "Математика",
                "starts_at": (now + timedelta(hours=1)).isoformat(),
                "ends_at": (now + timedelta(hours=2, minutes=30)).isoformat(),
                "teacher": "Учебный преподаватель",
                "location": "401",
            },
        )
        response.raise_for_status()
        lesson_id = response.json()["id"]
    draft_id = None
    if fixture:
        bundle = EventBundle(
            group_id,
            "42",
            (
                Message(1, "К следующей математике решить", now.isoformat()),
                Message(2, "номера 4 и 5", now.isoformat()),
            ),
        )
        draft_id = ingest_homework(
            engine,
            str(uuid4()),
            chat_id,
            bundle,
            FixtureProvider(),
            "synthetic-fixture-v1",
        )
    engine.dispose()
    return {
        "group_id": group_id,
        "lesson_id": lesson_id,
        "draft_id": draft_id,
        "tokens": tokens,
    }


def demonstrate(url):
    config = prepare(url)
    group = config["group_id"]

    def headers(role):
        return {"Authorization": "Bearer " + config["tokens"][role]}

    with TestClient(create_app(url)) as client:
        path = f"/groups/{group}/assignments"
        before = client.get(path, headers=headers("student")).json()
        decision = client.post(
            f"/groups/{group}/review/{config['draft_id']}/decision",
            headers=headers("admin"),
            json={
                "action": "approve",
                "expected_version": 1,
                "lesson_id": config["lesson_id"],
                "text": "Решить номера 4 и 5. Проверено старостой.",
            },
        )
        decision.raise_for_status()
        published = client.get(path, headers=headers("student")).json()
        result = client.put(
            path + "/" + published[0]["id"] + "/completion",
            headers=headers("student"),
            json={"version": 1, "completed": True},
        )
        result.raise_for_status()
        mine = client.get(path, headers=headers("student")).json()
        peer = client.get(path, headers=headers("student2")).json()
        assert (len(before), len(published), len(mine), len(peer)) == (0, 1, 0, 1)
        return {
            "model": "fixture (not live LLM)",
            "before_review": len(before),
            "after_review": len(published),
            "after_my_completion": len(mine),
            "other_student": len(peer),
        }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--prepare",
        metavar="LOCAL_SESSION_FILE",
        help="Create local synthetic demo and write temporary sessions to a NEW ignored .env.* file",
    )
    parser.add_argument(
        "--prepare-bot",
        metavar="LOCAL_SESSION_FILE",
        help="Create a local group for live Telegram intake, without a fixture draft",
    )
    args = parser.parse_args()
    if args.prepare or args.prepare_bot:
        path = Path(args.prepare or args.prepare_bot)
        if not path.name.startswith(".env.") or path.name == ".env.example":
            parser.error("Используйте игнорируемый файл .env.*, кроме .env.example")
        url = os.environ.get("USITY_DATABASE_URL")
        if not url:
            parser.error("Для постоянного стенда задайте USITY_DATABASE_URL")
        # Exclusive creation prevents accidentally overwriting existing credentials.
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as target:
            json.dump(
                prepare(url, fixture=not bool(args.prepare_bot)),
                target,
                ensure_ascii=False,
                indent=2,
            )
        print(f"Учебный стенд подготовлен. Временные сессии (12 часов): {path}")
    else:
        with TemporaryDirectory() as directory:
            print(
                json.dumps(
                    demonstrate(f"sqlite:///{directory}/demo.db"),
                    ensure_ascii=False,
                    indent=2,
                )
            )


if __name__ == "__main__":
    main()
