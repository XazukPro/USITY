import os
from datetime import UTC, datetime, timedelta
from hashlib import sha256
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from app.api import create_app
from app.db import Base, make_engine
from app.models import Draft, Lesson, Membership, SessionToken, StudyGroup


@pytest.fixture
def setup(tmp_path):
    url = os.getenv("USITY_TEST_DATABASE_URL", f"sqlite:///{tmp_path}/review.db")
    engine = make_engine(url)
    Base.metadata.create_all(engine)
    suffix = uuid4().hex
    group, other = "group-" + suffix, "other-" + suffix
    users = {
        name: name + suffix
        for name in ("admin", "admin2", "student", "student2", "outsider")
    }
    now = datetime.now(UTC)
    with engine.begin() as db:
        db.execute(StudyGroup.__table__.insert(), [{"id": group}, {"id": other}])
        for name, user in users.items():
            db.execute(
                Membership.__table__.insert(),
                {
                    "user_id": user,
                    "group_id": other if name == "outsider" else group,
                    "role": "admin"
                    if name.startswith("admin") or name == "outsider"
                    else "student",
                },
            )
            db.execute(
                SessionToken.__table__.insert(),
                {
                    "token_hash": sha256(user.encode()).hexdigest(),
                    "user_id": user,
                    "expires_at": now + timedelta(hours=1),
                },
            )
        db.execute(
            Lesson.__table__.insert(),
            [
                {
                    "id": "lesson-" + suffix,
                    "group_id": group,
                    "subject": "Математика",
                    "starts_at": now + timedelta(days=2),
                    "ends_at": now + timedelta(days=2, hours=1),
                    "teacher": "Преподаватель",
                    "location": "401",
                },
                {
                    "id": "other-lesson-" + suffix,
                    "group_id": other,
                    "subject": "Чужой предмет",
                    "starts_at": now + timedelta(days=2),
                    "ends_at": now + timedelta(days=2, hours=1),
                    "teacher": "",
                    "location": "",
                },
                {
                    "id": "past-" + suffix,
                    "group_id": group,
                    "subject": "Математика",
                    "starts_at": now - timedelta(days=1),
                    "ends_at": now - timedelta(hours=23),
                    "teacher": "",
                    "location": "",
                },
            ],
        )
        db.execute(
            Draft.__table__.insert(),
            {
                "id": "draft-" + suffix,
                "group_id": group,
                "event_id": "event-" + suffix,
                "text": "Решить 4 и 5",
                "source_context": {"messages": [{"id": 1, "text": "ДЗ: 4 и 5"}]},
                "model_output": {"kind": "new_homework", "source_ids": [1]},
                "model_version": "fixture",
                "prompt_version": "homework-v1",
                "status": "pending",
                "version": 1,
            },
        )
    app = create_app(url)
    with TestClient(app) as client:
        yield {
            "client": client,
            "engine": engine,
            "url": url,
            "group": group,
            "other": other,
            "users": users,
            "draft": "draft-" + suffix,
            "lesson": "lesson-" + suffix,
            "other_lesson": "other-lesson-" + suffix,
            "past": "past-" + suffix,
        }
    with engine.begin() as db:
        from app.models import TelegramIntegration

        db.execute(
            TelegramIntegration.__table__.delete().where(
                TelegramIntegration.group_id.in_([group, other])
            )
        )
    engine.dispose()
