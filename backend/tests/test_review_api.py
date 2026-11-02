"""Integration tests: authorization, atomic review and personal completion."""

from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select

from app.api import create_app
from app.models import Assignment, Draft, SessionToken


def headers(s, who="admin"):
    return {"Authorization": "Bearer " + s["users"][who]}


def decide(s, action="approve", **changes):
    data = {"action": action, "expected_version": 1}
    if action == "approve":
        data.update(lesson_id=s["lesson"], text="Решить номера 4 и 5")
    data.update(changes)
    return s["client"].post(
        f"/groups/{s['group']}/review/{s['draft']}/decision",
        json=data,
        headers=headers(s),
    )


def assignments(s, who="student"):
    return (
        s["client"]
        .get(f"/groups/{s['group']}/assignments", headers=headers(s, who))
        .json()
    )


def test_only_human_approval_publishes_and_survives_restart(setup):
    s = setup
    assert assignments(s) == []
    review = s["client"].get(f"/groups/{s['group']}/review", headers=headers(s)).json()
    assert review[0]["source_context"]["messages"][0]["text"] == "ДЗ: 4 и 5"
    result = decide(s)
    assert result.status_code == 200, result.text
    published = assignments(s)
    assert len(published) == 1
    assert published[0]["text"] == "Решить номера 4 и 5"
    assert published[0]["lesson_id"] == s["lesson"]
    assert "source_context" not in published[0]
    with TestClient(create_app(s["url"])) as client:
        assert (
            len(
                client.get(
                    f"/groups/{s['group']}/assignments", headers=headers(s, "student")
                ).json()
            )
            == 1
        )
    with s["engine"].connect() as db:
        row = db.execute(select(Draft).where(Draft.id == s["draft"])).mappings().one()
        assert row["human_output"]["text"] == "Решить номера 4 и 5"
        assert row["decided_by"] == s["users"]["admin"]


def test_reject_does_not_publish_and_cannot_be_approved_later(setup):
    assert decide(setup, "reject").status_code == 200
    assert decide(setup).status_code == 409
    assert assignments(setup) == []


def test_auth_and_group_boundaries(setup):
    s = setup
    path = f"/groups/{s['group']}/review"
    assert s["client"].get(path).status_code == 401
    assert (
        s["client"].get(path, headers={"Authorization": "Bearer unknown"}).status_code
        == 401
    )
    for who in ("student", "outsider"):
        assert s["client"].get(path, headers=headers(s, who)).status_code == 403
        assert (
            s["client"]
            .post(
                path + f"/{s['draft']}/decision",
                json={
                    "action": "approve",
                    "expected_version": 1,
                    "lesson_id": s["lesson"],
                    "text": "Попытка",
                },
                headers=headers(s, who),
            )
            .status_code
            == 403
        )
    assert (
        s["client"]
        .get(f"/groups/{s['other']}/assignments", headers=headers(s, "student"))
        .status_code
        == 403
    )
    assert assignments(s) == []


def test_expired_session_is_rejected(setup):
    s = setup
    with s["engine"].begin() as db:
        db.execute(
            SessionToken.__table__.update()
            .where(SessionToken.user_id == s["users"]["admin"])
            .values(expires_at=datetime.now(UTC) - timedelta(seconds=1))
        )
    assert (
        s["client"].get(f"/groups/{s['group']}/review", headers=headers(s)).status_code
        == 401
    )


@pytest.mark.parametrize("invalid", ["past", "other_lesson", "missing"])
def test_invalid_lesson_does_not_consume_draft(setup, invalid):
    s = setup
    assert decide(s, lesson_id=s.get(invalid, "missing")).status_code in (404, 422)
    assert assignments(s) == []
    assert decide(s).status_code == 200


def test_invalid_decision_cannot_publish(setup):
    for change in (
        {"text": "   "},
        {"lesson_id": None},
        {"expected_version": 0},
        {"text": "X" * 20001},
        {"role": "owner"},
    ):
        assert decide(setup, **change).status_code == 422
    assert decide(setup, expected_version=2).status_code == 409
    assert assignments(setup) == []


def test_two_admins_only_one_wins(setup):
    s = setup

    def submit(who):
        with TestClient(create_app(s["url"])) as client:
            return client.post(
                f"/groups/{s['group']}/review/{s['draft']}/decision",
                json={
                    "action": "approve",
                    "expected_version": 1,
                    "lesson_id": s["lesson"],
                    "text": "ДЗ",
                },
                headers=headers(s, who),
            ).status_code

    with ThreadPoolExecutor(2) as pool:
        assert sorted(pool.map(submit, ["admin", "admin2"])) == [200, 409]
    assert len(assignments(s)) == 1


def test_completion_is_personal_and_versioned(setup):
    s = setup
    decide(s)
    assignment = assignments(s)[0]
    path = f"/groups/{s['group']}/assignments/{assignment['id']}/completion"
    assert (
        s["client"]
        .put(
            path, json={"version": 1, "completed": True}, headers=headers(s, "student")
        )
        .status_code
        == 200
    )
    assert assignments(s) == []
    assert len(assignments(s, "student2")) == 1
    # A newer assignment revision must win over stale offline completion.
    with s["engine"].begin() as db:
        db.execute(
            Assignment.__table__.update()
            .where(Assignment.id == assignment["id"])
            .values(version=2)
        )
    assert len(assignments(s)) == 1
    assert (
        s["client"]
        .put(
            path, json={"version": 1, "completed": True}, headers=headers(s, "student")
        )
        .status_code
        == 409
    )
    assert (
        s["client"]
        .put(
            path, json={"version": 2, "completed": True}, headers=headers(s, "student")
        )
        .status_code
        == 200
    )
    assert (
        s["client"]
        .put(
            path, json={"version": 2, "completed": False}, headers=headers(s, "student")
        )
        .status_code
        == 200
    )
    assert len(assignments(s)) == 1


def test_admin_creates_lesson_with_valid_times_only(setup):
    s = setup
    data = {
        "subject": "Информатика",
        "starts_at": "2026-12-01T10:00:00+03:00",
        "ends_at": "2026-12-01T11:30:00+03:00",
        "teacher": "Иванов",
        "location": "201",
    }
    path = f"/groups/{s['group']}/lessons"
    assert (
        s["client"].post(path, json=data, headers=headers(s, "student")).status_code
        == 403
    )
    result = s["client"].post(path, json=data, headers=headers(s))
    assert result.status_code == 201, result.text
    assert result.json()["subject"] == "Информатика"
    assert (
        s["client"]
        .post(path, json={**data, "ends_at": data["starts_at"]}, headers=headers(s))
        .status_code
        == 422
    )
    assert (
        s["client"]
        .post(
            path, json={**data, "starts_at": "2026-12-01T10:00:00"}, headers=headers(s)
        )
        .status_code
        == 422
    )
    assert any(
        item["id"] == result.json()["id"]
        for item in s["client"].get(path, headers=headers(s, "student")).json()
    )


def test_publication_failure_rolls_back_decision(setup):
    from sqlalchemy import event

    def fail_insert(*args):
        raise RuntimeError("synthetic storage failure")

    event.listen(Assignment, "before_insert", fail_insert)
    try:
        with pytest.raises(RuntimeError, match="synthetic storage failure"):
            decide(setup)
    finally:
        event.remove(Assignment, "before_insert", fail_insert)
    assert assignments(setup) == []
    assert decide(setup).status_code == 200


def test_losing_admin_receives_current_decision(setup):
    result = decide(setup).json()
    conflict = decide(setup)
    assert conflict.status_code == 409
    assert conflict.json()["detail"]["current_status"] == "approved"
    assert conflict.json()["detail"]["current_version"] == 2
    assert conflict.json()["detail"]["assignment_id"] == result["assignment_id"]


def test_concurrent_completion_cannot_replace_newer_revision(setup):
    from threading import Event

    from sqlalchemy import event
    from sqlalchemy.engine import Engine

    s = setup
    decide(s)
    assignment_id = assignments(s)[0]["id"]
    path = f"/groups/{s['group']}/assignments/{assignment_id}/completion"
    paused, fresh_done = Event(), Event()

    def before_upsert(conn, cursor, statement, parameters, context, many):
        if (
            "INSERT INTO assignment_completions" in statement
            and context.compiled_parameters[0].get("version") == 1
        ):
            paused.set()
            fresh_done.wait(timeout=0.3)

    def request(version):
        with TestClient(create_app(s["url"])) as client:
            return client.put(
                path,
                json={"version": version, "completed": True},
                headers=headers(s, "student"),
            ).status_code

    def fresh():
        assert paused.wait(timeout=5)
        with s["engine"].begin() as db:
            db.execute(
                Assignment.__table__.update()
                .where(Assignment.id == assignment_id)
                .values(version=2)
            )
        result = request(2)
        fresh_done.set()
        return result

    event.listen(Engine, "before_cursor_execute", before_upsert)
    try:
        with (
            ThreadPoolExecutor(1, thread_name_prefix="stale") as old_pool,
            ThreadPoolExecutor(1) as new_pool,
        ):
            old = old_pool.submit(request, 1)
            new = new_pool.submit(fresh)
            assert old.result(timeout=10) == 200
            assert new.result(timeout=10) == 200
    finally:
        event.remove(Engine, "before_cursor_execute", before_upsert)
    assert assignments(s) == []


def test_session_profile_drives_client_permissions(setup):
    s = setup
    assert s["client"].get("/me").status_code == 401
    profile = s["client"].get("/me", headers=headers(s, "student")).json()
    assert profile == {
        "user_id": s["users"]["student"],
        "group_id": s["group"],
        "role": "student",
    }


def test_processed_draft_reports_conflict_even_after_lesson_started(setup):
    s = setup
    result = decide(s).json()
    with s["engine"].begin() as db:
        from app.models import Lesson

        db.execute(
            Lesson.__table__.update()
            .where(Lesson.id == s["lesson"])
            .values(starts_at=datetime.now(UTC) - timedelta(hours=1))
        )
    conflict = decide(s)
    assert conflict.status_code == 409
    assert conflict.json()["detail"]["assignment_id"] == result["assignment_id"]
