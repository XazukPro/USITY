import os
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, date, datetime, timedelta
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.engine import make_url
from sqlalchemy.orm import Session
from sqlalchemy.schema import CreateSchema, DropSchema

from app.api import create_app
from app.db import make_engine
from app.mail_codes import LoginMail
from app.models import Draft, EmailCode
from migrate import migrate


@pytest.fixture
def database_url(tmp_path):
    configured = os.getenv("USITY_TEST_DATABASE_URL", "")
    if not configured.startswith("postgresql"):
        yield f"sqlite:///{tmp_path}/db"
        return
    engine = make_engine(configured)
    schema = "test_account_" + uuid4().hex
    with engine.begin() as connection:
        connection.execute(CreateSchema(schema))
    try:
        yield (
            make_url(configured)
            .update_query_dict({"options": f"-csearch_path={schema}"})
            .render_as_string(hide_password=False)
        )
    finally:
        with engine.begin() as connection:
            connection.execute(DropSchema(schema, cascade=True))
        engine.dispose()


@pytest.fixture
def stand(database_url):
    url = database_url
    migrate(url)
    migrate(url)
    inbox = {}
    with TestClient(
        create_app(url, login_mail=LoginMail(b"x" * 32, inbox.__setitem__))
    ) as client:
        yield client, inbox, url


def login(stand, name):
    c, box, _ = stand
    address = name + "@example.test"
    assert c.post("/auth/code", json={"email": address}).json() == {"sent": True}
    r = c.post("/auth/verify", json={"email": address, "code": box[address]})
    assert r.status_code == 200, r.text
    return {"Authorization": "Bearer " + r.json()["token"]}


def test_upgrades_existing_groups_without_losing_data(database_url):
    engine = make_engine(database_url)
    with engine.begin() as db:
        db.exec_driver_sql("CREATE TABLE study_groups (id VARCHAR(100) PRIMARY KEY)")
        db.exec_driver_sql("INSERT INTO study_groups (id) VALUES ('existing')")
    migrate(database_url)
    migrate(database_url)
    with engine.connect() as db:
        assert (
            db.exec_driver_sql("SELECT id FROM study_groups").scalar_one() == "existing"
        )
        assert db.exec_driver_sql("SELECT count(*) FROM usity_schema").scalar_one() >= 3
    engine.dispose()


def semester():
    return {
        "name": "Тест",
        "start": "2026-09-01",
        "end": "2026-09-30",
        "alternating": True,
        "subjects": [{"name": "Алгебра", "id": 1, "groups": 2, "kinds": ["lecture"]}],
        "slots": [
            {
                "subject_id": 1,
                "weekday": 1,
                "start": 600,
                "end": 690,
                "kind": "lecture",
                "room": "201",
                "teacher": "Пример",
                "subgroup": g,
                "pattern": "even",
            }
            for g in [None, 1, 2]
        ],
    }


def test_otp_consumption_throttle_expiry_and_logout(stand):
    c, inbox, url = stand
    auth = login(stand, "a")
    email = "a@example.test"
    assert (
        c.post("/auth/verify", json={"email": email, "code": inbox[email]}).status_code
        == 401
    )
    assert c.post("/auth/code", json={"email": email}).status_code == 429
    assert c.get("/account", headers=auth).json()["group_id"] is None
    assert c.post("/account/logout", headers=auth).is_success
    assert c.get("/account", headers=auth).status_code == 401
    email = "b@example.test"
    c.post("/auth/code", json={"email": email})
    wrong = "000000" if inbox[email] != "000000" else "000001"
    for _ in range(5):
        assert (
            c.post("/auth/verify", json={"email": email, "code": wrong}).status_code
            == 401
        )
    assert (
        c.post("/auth/verify", json={"email": email, "code": inbox[email]}).status_code
        == 401
    )
    with make_engine(url).begin() as db:
        db.execute(
            EmailCode.__table__.update().values(
                attempts=0, expires_at=datetime.now(UTC) - timedelta(seconds=1)
            )
        )
    assert (
        c.post("/auth/verify", json={"email": email, "code": inbox[email]}).status_code
        == 401
    )


def test_atomic_group_join_and_subgroup_isolation(stand):
    c, _, _ = stand
    owner, student, outsider = [login(stand, n) for n in ["owner", "student", "other"]]
    invalid = semester()
    invalid["slots"][0]["end"] = 500
    assert c.post("/account/group", headers=owner, json=invalid).status_code == 422
    group = c.post("/account/group", headers=owner, json=semester())
    assert group.status_code == 201, group.text
    p = group.json()
    invite = p["invite_url"].split("/")[-1]
    path = "/groups/" + p["group_id"]
    assert (
        c.post("/account/join", headers=student, json={"invite": "bad"}).status_code
        == 404
    )
    assert (
        c.post(
            "/account/join", headers=student, json={"invite": invite, "role": "owner"}
        ).status_code
        == 422
    )
    joined = c.post("/account/join", headers=student, json={"invite": invite}).json()
    assert joined["role"] == "student" and joined["invite_url"] is None
    assert c.post("/account/group", headers=student, json=semester()).status_code == 409
    assert c.get(path + "/review", headers=student).status_code == 403
    assert c.get(path + "/lessons", headers=outsider).status_code in (401, 403)
    assert len(c.get(path + "/lessons", headers=owner).json()) == 6
    assert len(c.get(path + "/lessons", headers=student).json()) == 2
    assert (
        c.put(
            "/account/subgroups", headers=student, json={"choices": {"Алгебра": 3}}
        ).status_code
        == 422
    )
    first = c.put(
        "/account/subgroups", headers=student, json={"choices": {"Алгебра": 1}}
    )
    assert first.json()["choices"] == {"Алгебра": 1}
    group1 = c.get(path + "/lessons", headers=student).json()
    c.put("/account/subgroups", headers=student, json={"choices": {"Алгебра": 2}})
    group2 = c.get(path + "/lessons", headers=student).json()
    assert len(group1) == len(group2) == 4
    assert (
        len({lesson["id"] for lesson in group1} & {lesson["id"] for lesson in group2})
        == 2
    )


def test_code_can_only_create_one_session_concurrently(stand):
    client, inbox, _ = stand
    address = "parallel@example.test"
    assert client.post("/auth/code", json={"email": address}).status_code == 202

    def verify(_):
        return client.post(
            "/auth/verify", json={"email": address, "code": inbox[address]}
        ).status_code

    with ThreadPoolExecutor(max_workers=2) as pool:
        assert sorted(pool.map(verify, range(2))) == [200, 401]


def test_admin_chooses_multiple_subgroups_and_student_cannot_guess_assignment(stand):
    c, _, url = stand
    owner, student = [login(stand, name) for name in ["owner", "student"]]
    config = semester()
    start = date.today() + timedelta(days=7)
    config.update(
        start=start.isoformat(),
        end=(start + timedelta(days=30)).isoformat(),
        alternating=False,
    )
    config["subjects"][0]["groups"] = 3
    group = c.post("/account/group", headers=owner, json=config).json()
    group_id = group["group_id"]
    invite = group["invite_url"].split("/")[-1]
    assert c.post("/account/join", headers=student, json={"invite": invite}).is_success
    path = f"/groups/{group_id}"
    lessons = c.get(path + "/lessons", headers=owner).json()
    lesson = next(row for row in lessons if row["subgroup"] is None)
    with Session(make_engine(url)) as db:
        draft = Draft(
            group_id=group_id,
            event_id="synthetic",
            text="Задача",
            source_context={},
            model_output={},
            model_version="test",
            prompt_version="test",
        )
        db.add(draft)
        db.flush()
        decision = path + f"/review/{draft.id}/decision"
        db.commit()
    body = {
        "action": "approve",
        "expected_version": 1,
        "text": "ДЗ",
        "lesson_id": lesson["id"],
    }
    assert (
        c.post(decision, headers=owner, json={**body, "subgroups": [4]}).status_code
        == 422
    )
    published = c.post(decision, headers=owner, json={**body, "subgroups": [1, 3]})
    assert published.is_success, published.text
    assignments = path + "/assignments"
    completion = assignments + "/" + published.json()["assignment_id"] + "/completion"
    for subgroup, visible in [(0, False), (1, True), (2, False), (3, True)]:
        choices = {"Алгебра": subgroup} if subgroup else {}
        assert c.put(
            "/account/subgroups", headers=student, json={"choices": choices}
        ).is_success
        assert bool(c.get(assignments, headers=student).json()) == visible
        result = c.put(
            completion, headers=student, json={"version": 1, "completed": False}
        )
        assert result.status_code == (200 if visible else 404)
