from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta, timezone
from threading import Barrier
from uuid import uuid4

import pytest
from test_account_access import database_url as database_url
from test_account_access import login
from test_account_access import stand as stand

TASKS = "/account/tasks"


def mutation(version=0, **changes):
    return {
        "expected_version": version,
        "mutation_id": str(uuid4()),
        "title": "Подготовить доклад",
        "day": "2026-11-09",
        "start": None,
        "duration": 30,
        "remind": False,
        "completed_at": None,
        **changes,
    }


def assert_conflict(response, current):
    assert response.status_code == 409, response.text
    assert response.json() == {"detail": {"current": current}}


def test_account_owns_task_and_mutation_ids(stand):
    client, _, _ = stand
    alice, bob = [login(stand, name) for name in ("alice", "bob")]
    task_id = str(uuid4())
    url = f"{TASKS}/{task_id}"
    body = mutation()
    assert client.get(TASKS).status_code == 401
    assert client.put(url, json=body).status_code == 401
    created = client.put(url, headers=alice, json=body)
    assert created.status_code == 200, created.text
    assert created.json() == {
        "id": task_id,
        "title": "Подготовить доклад",
        "day": "2026-11-09",
        "start": None,
        "duration": 30,
        "remind": False,
        "completed_at": None,
        "version": 1,
    }
    assert client.get(TASKS, headers=bob).json() == []
    assert_conflict(client.put(url, headers=bob, json=mutation(1)), None)
    other = client.put(url, headers=bob, json={**body, "title": "Моя задача"})
    assert other.status_code == 200, other.text
    assert other.json()["title"] == "Моя задача"
    assert client.get(TASKS, headers=alice).json() == [created.json()]
    assert client.get(TASKS, headers=bob).json() == [other.json()]


def test_replays_accepted_mutations_across_edits_and_detects_stale_versions(stand):
    client, _, _ = stand
    auth = login(stand, "offline")
    url = f"{TASKS}/{uuid4()}"
    create = mutation()
    original = client.put(url, headers=auth, json=create)
    assert original.status_code == 200, original.text
    assert_conflict(client.put(url, headers=auth, json=mutation()), original.json())
    edit = mutation(1, title="Другой день", day="2026-11-10", start=600, remind=True)
    updated = client.put(url, headers=auth, json=edit)
    assert updated.status_code == 200, updated.text
    assert updated.json() == {
        **original.json(),
        "title": "Другой день",
        "day": "2026-11-10",
        "start": 600,
        "remind": True,
        "version": 2,
    }
    for body, ack in [(create, original), (edit, updated)]:
        retry = client.put(url, headers=auth, json=body)
        assert retry.status_code == 200, retry.text
        assert retry.json() == ack.json()
    assert_conflict(client.put(url, headers=auth, json=mutation(1)), updated.json())
    for reused in [{**edit, "title": "Подмена"}, {**edit, "expected_version": 2}]:
        assert_conflict(client.put(url, headers=auth, json=reused), updated.json())
    assert_conflict(client.put(f"{TASKS}/{uuid4()}", headers=auth, json=create), None)
    assert client.get(TASKS, headers=auth).json() == [updated.json()]


def test_only_recent_completions_can_be_listed_and_restored(stand):
    client, _, _ = stand
    auth = login(stand, "archive")
    now = datetime.now(UTC)
    recent = now - timedelta(days=3) + timedelta(minutes=1)
    expired = now - timedelta(days=3, seconds=1)
    recent_url, old_url, future_url = [f"{TASKS}/{uuid4()}" for _ in range(3)]
    for url, when in [
        (recent_url, recent),
        (old_url, expired),
        (future_url, now + timedelta(hours=1)),
    ]:
        created = client.put(url, headers=auth, json=mutation())
        assert created.status_code == 200, created.text
        value = when.astimezone(timezone(timedelta(hours=3))).isoformat()
        done = client.put(url, headers=auth, json=mutation(1, completed_at=value))
        assert done.status_code == 200, done.text
        assert datetime.fromisoformat(done.json()["completed_at"]) == when
    visible = client.get(TASKS, headers=auth).json()
    assert [row["id"] for row in visible] == [recent_url.split("/")[-1]]
    assert datetime.fromisoformat(visible[0]["completed_at"]) == recent
    restored = client.put(recent_url, headers=auth, json=mutation(2))
    assert restored.status_code == 200, restored.text
    assert restored.json()["completed_at"] is None
    assert restored.json()["version"] == 3
    for body in (mutation(2), mutation(), mutation(2, completed_at=recent.isoformat())):
        assert_conflict(client.put(old_url, headers=auth, json=body), None)
    assert client.get(TASKS, headers=auth).json() == [restored.json()]


@pytest.mark.parametrize(
    "changes",
    [
        {"expected_version": -1},
        {"mutation_id": "invalid"},
        {"title": " "},
        {"title": "Нулевой\x00символ"},
        {"day": "2026-02-30"},
        {"day": "2026-11-09T00:00:00Z"},
        {"start": -1},
        {"start": 1440},
        {"duration": 0},
        {"duration": 1441},
        {"start": 1430, "duration": 20},
        {"remind": "false"},
        {"completed_at": "2026-11-09T10:00:00"},
        {"completed_at": 1794218400},
        {"completed_at": "0001-01-01T00:00:00+01:00"},
        {"user_id": "other"},
    ],
)
def test_invalid_mutation_leaves_no_task(stand, changes):
    client, _, _ = stand
    auth = login(stand, "invalid")
    response = client.put(f"{TASKS}/{uuid4()}", headers=auth, json=mutation(**changes))
    assert response.status_code == 422, response.text
    assert client.get(TASKS, headers=auth).json() == []


@pytest.mark.parametrize("version", [0, 1], ids=["create", "edit"])
@pytest.mark.parametrize("replay", [True, False], ids=["retry", "competing"])
def test_simultaneous_puts_apply_once(stand, version, replay):
    client, _, _ = stand
    auth = login(stand, "race")
    url = f"{TASKS}/{uuid4()}"
    if version:
        assert client.put(url, headers=auth, json=mutation()).status_code == 200
    first = mutation(version, title="Первое")
    second = first if replay else mutation(version, title="Второе")
    gate = Barrier(2)

    def put(body):
        gate.wait(timeout=10)
        return client.put(url, headers=auth, json=body)

    with ThreadPoolExecutor(max_workers=2) as pool:
        responses = sorted(pool.map(put, (first, second)), key=lambda r: r.status_code)
    winner, other = responses
    assert winner.status_code == 200, winner.text
    assert winner.json()["version"] == version + 1
    if replay:
        assert other.status_code == 200, other.text
        assert other.json() == winner.json()
    else:
        assert_conflict(other, winner.json())
    assert client.get(TASKS, headers=auth).json() == [winner.json()]
