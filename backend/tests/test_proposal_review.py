"""Proposal review integration tests with real authentication and foreign keys."""

from concurrent.futures import ThreadPoolExecutor
from copy import deepcopy
from datetime import timedelta
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import event, inspect, select, text, update
from sqlalchemy.orm import Session

from app.api import create_app
from app.db import make_engine
from app.material_library import Material
from app.models import (
    Assignment,
    AssignmentSubgroup,
    Completion,
    Draft,
    Lesson,
    LessonDetails,
    Membership,
    StudyGroup,
    utc_now,
)
from migrate import migrate


def proposal(agent="assignment_change", **fields):
    return {
        "agent_id": agent,
        "proposal_type": "material" if agent == "material_proposal" else agent,
        "source_ids": [1],
        "fields": fields,
        "reason": "Synthetic test evidence",
        "uncertainty": [],
    }


@pytest.fixture
def review(setup):
    s = setup
    aid = "assignment-" + s["draft"]
    source_draft = "original-" + s["draft"]
    props = [
        proposal(kind="update", assignment_id=aid, new_text="Model text"),
        proposal(kind="cancel", assignment_id=aid),
        proposal("duplicate_conflict", assignment_id=aid),
        proposal(
            "material_proposal",
            attachment_id="1:link:0",
            category_id="Ссылки",
            subject_ids=["Математика"],
            assignment_ids=[],
        ),
    ]
    runs = [
        {
            "agent_id": p["agent_id"],
            "status": "proposed",
            "proposals": [p],
            "model_version": "fixture",
            "prompt_version": "fixture-v1",
            "raw_output": "Synthetic model output",
        }
        for p in props
    ]
    with Session(s["engine"]) as db, db.begin():
        original = db.get(Draft, s["draft"])
        db.add(
            Draft(
                id=source_draft,
                group_id=s["group"],
                event_id=source_draft,
                text="Original",
                source_context={},
                model_output={},
                model_version="fixture",
                prompt_version="fixture",
                status="approved",
            )
        )
        db.flush()
        db.add(
            Assignment(
                id=aid,
                group_id=s["group"],
                draft_id=source_draft,
                lesson_id=s["lesson"],
                text="Original",
                version=1,
            )
        )
        db.flush()
        db.add(
            Completion(
                assignment_id=aid,
                user_id=s["users"]["student"],
                version=1,
                completed=True,
            )
        )
        original.proposal_set = {
            "schema_version": 2,
            "runs": runs,
            "summary": {"state": "needs_review", "homework": False},
        }
        original.source_context = {
            "group_id": s["group"],
            "messages": [
                {
                    "id": 1,
                    "text": "Synthetic change",
                    "attachments": [
                        {
                            "id": "1:link:0",
                            "kind": "link",
                            "url": "https://example.test/lecture",
                            "size_bytes": 1,
                        }
                    ],
                }
            ],
            "active_assignments": [
                {
                    "id": aid,
                    "version": 1,
                    "text": "Original",
                    "lesson_id": s["lesson"],
                }
            ],
        }
        db.get(Membership, s["users"]["admin2"]).role = "owner"
    with TestClient(create_app(s["url"])) as client:
        yield {**s, "proposal_client": client, "assignment": aid}


def decide(s, run=0, index=0, who="admin", action="approve", **changes):
    body = {"action": action, "expected_version": 1}
    if action == "approve" and run == 0:
        body.update(text="Human correction", lesson_id=s["lesson"])
    body.update(changes)
    headers = {"Authorization": "Bearer " + s["users"][who]} if who else {}
    return s["proposal_client"].post(
        f"/groups/{s['group']}/review/{s['draft']}/proposals/{run}/{index}/decision",
        json=body,
        headers=headers,
    )


def mutate(s, change):
    with Session(s["engine"]) as db, db.begin():
        draft = db.get(Draft, s["draft"])
        proposals = deepcopy(draft.proposal_set)
        source = deepcopy(draft.source_context)
        change(proposals, source)
        draft.proposal_set, draft.source_context = proposals, source


def unchanged(s):
    with Session(s["engine"]) as db:
        draft = db.get(Draft, s["draft"])
        assignment = db.get(Assignment, s["assignment"])
        assert draft.version == 1
        assert all(
            "decision" not in p
            for r in draft.proposal_set["runs"]
            for p in r["proposals"]
        )
        assert (assignment.text, assignment.version) == ("Original", 1)
        assert assignment.cancelled_at is None
        assert db.get(Completion, (s["assignment"], s["users"]["student"])).completed
        assert not list(
            db.scalars(select(Material).where(Material.group_id == s["group"]))
        )


@pytest.mark.parametrize("who", ["admin", "admin2"])
def test_update_is_human_authored_resets_completion_and_preserves_evidence(review, who):
    s = review
    with Session(s["engine"]) as db:
        draft = db.get(Draft, s["draft"])
        before = deepcopy(draft.proposal_set)
        source = deepcopy(draft.source_context)
    result = decide(s, who=who)
    assert result.status_code == 200, result.text
    assert result.json()["version"] == 2
    assert result.json()["assignment_id"] == s["assignment"]
    with Session(s["engine"]) as db:
        assignment = db.get(Assignment, s["assignment"])
        assert (assignment.text, assignment.version) == ("Human correction", 2)
        assert assignment.draft_id != s["draft"]
        completion = db.get(Completion, (s["assignment"], s["users"]["student"]))
        assert completion.version == 1 and completion.completed
        draft = db.get(Draft, s["draft"])
        assert draft.status == "pending"
        assert draft.human_output is None and draft.decided_by is None
        assert draft.source_context == source
        actual = deepcopy(draft.proposal_set)
        audit = actual["runs"][0]["proposals"][0].pop("decision")
        assert actual == before
        assert audit["status"] == "approved"
        assert audit["decided_by"] == s["users"][who]
        assert audit["decided_at"]
        assert audit["human_output"]["text"] == "Human correction"
        assert audit["previous_assignment_version"] == 1
        assert audit["assignment_version"] == 2
    items = (
        s["client"]
        .get(
            f"/groups/{s['group']}/assignments?include_completed=true",
            headers={"Authorization": "Bearer " + s["users"]["student"]},
        )
        .json()
    )
    assert items[0]["completed"] is False


def test_production_api_update_invalidates_offline_completion_and_accepts_new_version(
    review,
):
    s = review
    headers = {"Authorization": "Bearer " + s["users"]["student"]}
    path = f"/groups/{s['group']}/assignments"
    client = s["proposal_client"]
    assert client.get(path, headers=headers).json() == []
    before = client.get(path, params={"include_completed": True}, headers=headers)
    assert before.status_code == 200
    assert before.json()[0]["completed"] is True
    assert decide(s).status_code == 200
    active = client.get(path, headers=headers)
    assert active.status_code == 200
    assert [(a["id"], a["version"]) for a in active.json()] == [(s["assignment"], 2)]
    completion_path = path + f"/{s['assignment']}/completion"
    stale = client.put(
        completion_path, headers=headers, json={"version": 1, "completed": True}
    )
    assert stale.status_code == 409
    refreshed = client.get(path, params={"include_completed": True}, headers=headers)
    assert refreshed.json()[0]["completed"] is False
    current = client.put(
        completion_path, headers=headers, json={"version": 2, "completed": True}
    )
    assert current.status_code == 200
    assert client.get(path, headers=headers).json() == []
    assert (
        client.get(path, params={"include_completed": True}, headers=headers).json()[0][
            "completed"
        ]
        is True
    )


def test_production_api_hides_cancelled_assignment_and_rejects_offline_completion(
    review,
):
    s = review
    path = f"/groups/{s['group']}/assignments"
    client = s["proposal_client"]
    # The same assignment is visible to these users before cancellation, so
    # absence afterwards cannot be explained by another visibility restriction.
    for who in ("student", "student2", "admin"):
        headers = {"Authorization": "Bearer " + s["users"][who]}
        before = client.get(path, params={"include_completed": True}, headers=headers)
        assert before.status_code == 200
        assert [a["id"] for a in before.json()] == [s["assignment"]]
    assert decide(s, run=1).status_code == 200
    for who in ("student", "student2", "admin"):
        headers = {"Authorization": "Bearer " + s["users"][who]}
        for include_completed in (False, True):
            result = client.get(
                path, params={"include_completed": include_completed}, headers=headers
            )
            assert result.status_code == 200
            assert result.json() == []
        for version in (1, 2):
            for completed in (False, True):
                offline = client.put(
                    path + f"/{s['assignment']}/completion",
                    headers=headers,
                    json={"version": version, "completed": completed},
                )
                assert offline.status_code == 404
    with Session(s["engine"]) as db:
        assert db.get(Assignment, s["assignment"]).version == 2
        completion = db.get(Completion, (s["assignment"], s["users"]["student"]))
        assert completion.completed and completion.version == 1
        assert db.get(Completion, (s["assignment"], s["users"]["student2"])) is None


@pytest.mark.parametrize("who,code", [(None, 401), ("student", 403), ("outsider", 403)])
def test_authorization(review, who, code):
    assert decide(review, who=who).status_code == code
    unchanged(review)


@pytest.mark.parametrize(
    "changes,code",
    [
        ({"text": None}, 422),
        ({"text": "  "}, 422),
        ({"lesson_id": None}, 422),
        ({"expected_version": 2}, 409),
        ({"expected_version": True}, 422),
        ({"expected_version": 0}, 422),
        ({"action": "merge"}, 422),
        ({"assignment_id": "override"}, 422),
    ],
)
def test_invalid_input_leaves_everything_unchanged(review, changes, code):
    assert decide(review, **changes).status_code == code
    unchanged(review)


@pytest.mark.parametrize(
    "lesson,code", [("past", 422), ("other_lesson", 404), ("missing", 404)]
)
def test_invalid_lesson_rolls_back(review, lesson, code):
    assert decide(review, lesson_id=review.get(lesson, "missing")).status_code == code
    unchanged(review)


def test_update_moves_to_future_lesson_preserving_subgroups(review):
    s = review
    lesson_id = "next-" + s["lesson"]
    with Session(s["engine"]) as db, db.begin():
        db.add(
            Lesson(
                id=lesson_id,
                group_id=s["group"],
                subject="Математика",
                starts_at=utc_now() + timedelta(days=3),
                ends_at=utc_now() + timedelta(days=3, hours=1),
            )
        )
        db.add(AssignmentSubgroup(assignment_id=s["assignment"], subgroup=1))
    assert decide(s, lesson_id=lesson_id).status_code == 200
    with Session(s["engine"]) as db:
        assert db.get(Assignment, s["assignment"]).lesson_id == lesson_id
        assert db.get(AssignmentSubgroup, (s["assignment"], 1)) is not None


@pytest.mark.parametrize("mismatch", ["subject", "subgroup"])
def test_move_does_not_silently_change_audience(review, mismatch):
    s = review
    lesson_id = "next-" + s["lesson"]
    with Session(s["engine"]) as db, db.begin():
        db.add(
            Lesson(
                id=lesson_id,
                group_id=s["group"],
                subject="Физика" if mismatch == "subject" else "Математика",
                starts_at=utc_now() + timedelta(days=3),
                ends_at=utc_now() + timedelta(days=3, hours=1),
            )
        )
        db.flush()
        if mismatch == "subgroup":
            db.add(LessonDetails(lesson_id=lesson_id, kind="lecture", subgroup=2))
    assert decide(s, lesson_id=lesson_id).status_code == 422
    unchanged(s)


@pytest.mark.parametrize("run", [0, 1, 2, 3])
def test_rejection_is_per_proposal_and_replay_conflicts(review, run):
    s = review
    assert decide(s, run=run, action="reject").status_code == 200
    replay = decide(s, run=run, action="reject", expected_version=2)
    assert replay.status_code == 409
    assert replay.json()["detail"]["current_version"] == 2
    with Session(s["engine"]) as db:
        draft = db.get(Draft, s["draft"])
        assert draft.status == "pending"
        assert (
            draft.proposal_set["runs"][run]["proposals"][0]["decision"]["status"]
            == "rejected"
        )
        assert db.get(Assignment, s["assignment"]).version == 1
    other = (run + 1) % 4
    assert decide(s, run=other, action="reject", expected_version=2).status_code == 200


@pytest.mark.parametrize("who", ["admin", "admin2"])
def test_cancel_preserves_assignment_relationships_and_audits_previous_state(
    review, who
):
    s = review
    with Session(s["engine"]) as db, db.begin():
        db.add(AssignmentSubgroup(assignment_id=s["assignment"], subgroup=1))
    response = decide(s, run=1, who=who)
    assert response.status_code == 200, response.text
    assert response.json()["status"] == "approved"
    assert response.json()["version"] == 2
    with Session(s["engine"]) as db:
        assignment = db.get(Assignment, s["assignment"])
        assert assignment.cancelled_at is not None
        assert assignment.cancelled_at.utcoffset() == timedelta(0)
        assert assignment.version == 2
        assert assignment.text == "Original" and assignment.lesson_id == s["lesson"]
        assert db.get(AssignmentSubgroup, (s["assignment"], 1)) is not None
        completion = db.get(Completion, (s["assignment"], s["users"]["student"]))
        assert completion.completed and completion.version == 1
        draft = db.get(Draft, s["draft"])
        audit = draft.proposal_set["runs"][1]["proposals"][0]["decision"]
        assert audit["previous_assignment_version"] == 1
        assert audit["assignment_version"] == 2
        assert audit["previous_cancelled_at"] is None
        assert audit["cancelled_at"] == assignment.cancelled_at.isoformat()
        assert audit["decided_by"] == s["users"][who]
        assert draft.status == "pending"
    with TestClient(create_app(s["url"])) as client:
        result = client.get(
            f"/groups/{s['group']}/review",
            headers={"Authorization": "Bearer " + s["users"][who]},
        )
        assert result.status_code == 200
        persisted = next(d for d in result.json() if d["id"] == s["draft"])
        assert persisted["version"] == 2
        assert persisted["proposal_set"]["runs"][1]["proposals"][0]["decision"] == audit


@pytest.mark.parametrize("changes", [{"text": "Cancel it"}, {"lesson_id": "anything"}])
def test_cancel_does_not_accept_update_fields(review, changes):
    assert decide(review, run=1, **changes).status_code == 422
    unchanged(review)


@pytest.mark.parametrize("who,code", [(None, 401), ("student", 403), ("outsider", 403)])
def test_cancel_requires_group_admin(review, who, code):
    assert decide(review, run=1, who=who).status_code == code
    unchanged(review)


def test_cancel_requires_current_assignment_snapshot(review):
    s = review
    with s["engine"].begin() as db:
        db.execute(
            update(Assignment).where(Assignment.id == s["assignment"]).values(version=2)
        )
    assert decide(s, run=1).status_code == 409
    with Session(s["engine"]) as db:
        assert db.get(Assignment, s["assignment"]).cancelled_at is None
        assert db.get(Draft, s["draft"]).version == 1


@pytest.mark.parametrize("run", [0, 1])
def test_cancelled_assignment_cannot_be_changed_even_with_current_snapshot(review, run):
    s = review
    cancelled = utc_now()
    with s["engine"].begin() as db:
        db.execute(
            update(Assignment)
            .where(Assignment.id == s["assignment"])
            .values(
                version=2,
                cancelled_at=cancelled,
            )
        )
    mutate(s, lambda ps, source: source["active_assignments"][0].update(version=2))
    assert decide(s, run=run).status_code == 409
    with Session(s["engine"]) as db:
        assignment = db.get(Assignment, s["assignment"])
        assert assignment.cancelled_at == cancelled and assignment.version == 2
        assert db.get(Draft, s["draft"]).version == 1


def test_cancel_replay_conflicts_and_concurrent_admins_only_cancel_once(review):
    s = review
    with ThreadPoolExecutor(2) as pool:
        results = list(
            pool.map(lambda who: decide(s, run=1, who=who), ["admin", "admin2"])
        )
    assert sorted(r.status_code for r in results) == [200, 409]
    assert decide(s, run=1, expected_version=2).status_code == 409
    with Session(s["engine"]) as db:
        assert db.get(Assignment, s["assignment"]).version == 2


@pytest.mark.parametrize(
    "kind", ["new_homework", "incomplete_homework", "schedule_binding"]
)
@pytest.mark.parametrize("action", ["approve", "reject"])
def test_core_proposals_require_whole_draft_decision(review, kind, action):
    mutate(
        review,
        lambda ps, source: ps["runs"][0]["proposals"][0].update(proposal_type=kind),
    )
    assert decide(review, action=action).status_code == 422
    unchanged(review)


def test_duplicate_approval_only_marks_reviewed(review):
    s = review
    response = decide(s, run=2)
    assert response.status_code == 200, response.text
    assert response.json()["status"] == "reviewed"
    with Session(s["engine"]) as db:
        assert db.get(Assignment, s["assignment"]).version == 1
        assert db.get(Assignment, s["assignment"]).text == "Original"
        assert (
            len(
                list(
                    db.scalars(
                        select(Assignment).where(Assignment.group_id == s["group"])
                    )
                )
            )
            == 1
        )


@pytest.mark.parametrize(
    "run,index,code", [(-1, 0, 422), (0, -1, 422), (99, 0, 404), (0, 99, 404)]
)
def test_invalid_proposal_address(review, run, index, code):
    assert decide(review, run=run, index=index, action="reject").status_code == code
    unchanged(review)


def test_stale_assignment_snapshot_cannot_overwrite_newer_human_revision(review):
    s = review
    with s["engine"].begin() as db:
        db.execute(
            update(Assignment)
            .where(Assignment.id == s["assignment"])
            .values(
                text="Newer human edit",
                version=2,
            )
        )
    response = decide(s)
    assert response.status_code == 409
    with Session(s["engine"]) as db:
        assert db.get(Draft, s["draft"]).version == 1
        assert db.get(Assignment, s["assignment"]).text == "Newer human edit"


@pytest.mark.parametrize("run", [0, 1])
def test_immutable_proposal_version_rejects_old_change_after_context_refresh(
    review, run
):
    s = review
    with s["engine"].begin() as db:
        db.execute(
            update(Assignment)
            .where(Assignment.id == s["assignment"])
            .values(
                text="Newer human edit",
                version=2,
            )
        )

    def continuation(ps, source):
        ps["runs"][run]["proposals"][0]["assignment_snapshot_version"] = 1
        source["active_assignments"][0].update(version=2, text="Newer human edit")

    mutate(s, continuation)
    response = decide(s, run=run)
    assert response.status_code == 409, response.text
    assert response.json()["detail"]["current_assignment_version"] == 2
    with Session(s["engine"]) as db:
        assignment = db.get(Assignment, s["assignment"])
        assert (assignment.text, assignment.version) == ("Newer human edit", 2)
        assert assignment.cancelled_at is None
        draft = db.get(Draft, s["draft"])
        assert draft.version == 1
        assert "decision" not in draft.proposal_set["runs"][run]["proposals"][0]


@pytest.mark.parametrize("run", [0, 1])
@pytest.mark.parametrize("version", [None, True, "1", 1.0, {}, []])
def test_present_invalid_proposal_version_never_falls_back_to_context(
    review, run, version
):
    mutate(
        review,
        lambda ps, source: ps["runs"][run]["proposals"][0].update(
            assignment_snapshot_version=version,
        ),
    )
    assert decide(review, run=run).status_code == 422
    unchanged(review)


@pytest.mark.parametrize("run", [0, 1])
@pytest.mark.parametrize("context_version", [None, 99])
def test_valid_immutable_proposal_version_does_not_depend_on_refreshed_context(
    review, run, context_version
):
    def continuation(ps, source):
        ps["runs"][run]["proposals"][0]["assignment_snapshot_version"] = 1
        if context_version is None:
            source.pop("active_assignments")
        else:
            source["active_assignments"][0]["version"] = context_version

    mutate(review, continuation)
    response = decide(review, run=run)
    assert response.status_code == 200, response.text
    with Session(review["engine"]) as db:
        assert db.get(Assignment, review["assignment"]).version == 2


@pytest.mark.parametrize("run", [0, 1])
@pytest.mark.parametrize(
    "invalid", ["missing_snapshot", "wrong_source", "unknown_target", "foreign_target"]
)
def test_assignment_change_requires_a_trusted_target_and_source(review, invalid, run):
    s = review
    if invalid == "foreign_target":
        with s["engine"].begin() as db:
            db.execute(
                update(Assignment)
                .where(Assignment.id == s["assignment"])
                .values(group_id=s["other"])
            )

    def change(ps, source):
        p = ps["runs"][run]["proposals"][0]
        if invalid == "missing_snapshot":
            source["active_assignments"] = []
        elif invalid == "wrong_source":
            p["source_ids"] = [999]
        elif invalid == "unknown_target":
            p["fields"]["assignment_id"] = "missing"

    mutate(s, change)
    assert decide(s, run=run).status_code in (404, 422)
    unchanged(s)


def test_two_admins_only_one_wins(review):
    s = review
    with ThreadPoolExecutor(2) as pool:
        responses = list(pool.map(lambda who: decide(s, who=who), ["admin", "admin2"]))
    assert sorted(r.status_code for r in responses) == [200, 409]
    with Session(s["engine"]) as db:
        assert db.get(Assignment, s["assignment"]).version == 2
        assert db.get(Draft, s["draft"]).version == 2


@pytest.mark.parametrize("run", [0, 1])
def test_failed_assignment_write_rolls_back_decision(review, run):
    def fail(*args):
        raise RuntimeError("synthetic update failure")

    event.listen(Assignment, "before_update", fail)
    try:
        with pytest.raises(RuntimeError, match="synthetic update failure"):
            decide(review, run=run)
    finally:
        event.remove(Assignment, "before_update", fail)
    unchanged(review)
    assert decide(review, run=run).status_code == 200


def test_material_link_uses_attachment_url_not_model_url(review):
    s = review
    mutate(
        s,
        lambda ps, source: ps["runs"][3]["proposals"][0]["fields"].update(
            url="https://untrusted.test/model-invented",
        ),
    )
    result = decide(s, run=3, text="Лекция")
    assert result.status_code == 200, result.text
    with Session(s["engine"]) as db:
        material = db.scalar(select(Material).where(Material.group_id == s["group"]))
        assert material.url == "https://example.test/lecture"
        assert material.title == "Лекция"
        assert material.status == "published" and material.scope == "group"
        assert material.reviewed_by == s["users"]["admin"]
        assert material.subjects == ["Математика"]
        assert material.id == result.json()["material_id"]
        assert material.blob_key is None
    assert decide(s, run=3, expected_version=2).status_code == 409


@pytest.mark.parametrize(
    "invalid",
    [
        "file",
        "missing_attachment",
        "uncited_attachment",
        "unsafe_url",
        "unknown_category",
        "unknown_subject",
        "assignment_link",
        "ambiguous_attachment",
    ],
)
def test_unsafe_or_unsupported_material_approval_does_not_publish(review, invalid):
    def change(ps, source):
        p = ps["runs"][3]["proposals"][0]
        attachment = source["messages"][0]["attachments"][0]
        if invalid == "file":
            attachment["kind"] = "file"
        elif invalid == "missing_attachment":
            p["fields"]["attachment_id"] = "nonexistent"
        elif invalid == "uncited_attachment":
            source["messages"].append({"id": 2, "attachments": []})
            p["source_ids"] = [2]
        elif invalid == "unsafe_url":
            attachment["url"] = "javascript:alert(1)"
        elif invalid == "unknown_category":
            p["fields"]["category_id"] = "Unknown"
        elif invalid == "unknown_subject":
            p["fields"]["subject_ids"] = ["Unknown"]
        elif invalid == "assignment_link":
            p["fields"]["assignment_ids"] = [review["assignment"]]
        elif invalid == "ambiguous_attachment":
            source["messages"][0]["attachments"].append(deepcopy(attachment))

    mutate(review, change)
    assert decide(review, run=3).status_code == 422
    unchanged(review)


def test_cancellation_migration_preserves_existing_assignments_and_is_repeatable(
    tmp_path,
):
    url = f"sqlite:///{tmp_path}/legacy.db"
    engine = make_engine(url)
    migrations = Path(__file__).resolve().parents[1] / "migrations"
    # Build a real pre-cancellation database, including its migration ledger.
    with engine.begin() as db:
        db.exec_driver_sql(
            "CREATE TABLE usity_schema (version VARCHAR(32) PRIMARY KEY)"
        )
        for path in sorted(migrations.glob("*.sql")):
            if path.name >= "007":
                break
            for statement in path.read_text().split(";"):
                if statement.strip():
                    db.exec_driver_sql(statement)
            db.execute(
                text("INSERT INTO usity_schema VALUES (:version)"),
                {"version": path.stem},
            )
        db.execute(StudyGroup.__table__.insert(), {"id": "legacy-group"})
        db.execute(
            Membership.__table__.insert(),
            {
                "user_id": "legacy-user",
                "group_id": "legacy-group",
                "role": "student",
            },
        )
        db.execute(
            Lesson.__table__.insert(),
            {
                "id": "legacy-lesson",
                "group_id": "legacy-group",
                "subject": "Math",
                "starts_at": utc_now(),
                "ends_at": utc_now() + timedelta(hours=1),
            },
        )
        db.execute(
            Draft.__table__.insert(),
            {
                "id": "legacy-draft",
                "group_id": "legacy-group",
                "event_id": "legacy-event",
                "text": "Original",
                "source_context": {},
                "model_output": {},
                "model_version": "fixture",
                "prompt_version": "fixture",
                "status": "approved",
            },
        )
        db.execute(
            Assignment.__table__.insert(),
            {
                "id": "legacy-assignment",
                "group_id": "legacy-group",
                "draft_id": "legacy-draft",
                "lesson_id": "legacy-lesson",
                "text": "Original",
            },
        )
        db.execute(
            Completion.__table__.insert(),
            {
                "assignment_id": "legacy-assignment",
                "user_id": "legacy-user",
                "completed": True,
                "version": 1,
            },
        )
    try:
        migrate(url)
        migrate(url)
        with engine.connect() as db:
            columns = {c["name"]: c for c in inspect(db).get_columns("assignments")}
            assert "cancelled_at" in columns
            assert columns["cancelled_at"]["nullable"]
        with Session(engine) as db, db.begin():
            assignment = db.get(Assignment, "legacy-assignment")
            assert assignment.text == "Original" and assignment.version == 1
            assert assignment.cancelled_at is None
            assert db.get(Completion, ("legacy-assignment", "legacy-user")).completed
            assignment.cancelled_at = utc_now()
            assignment.version += 1
        with Session(engine) as db:
            assert db.get(
                Assignment, "legacy-assignment"
            ).cancelled_at.utcoffset() == timedelta(0)
    finally:
        engine.dispose()


def test_migration_handles_metadata_created_schema(review):
    migrate(review["url"])
    migrate(review["url"])
    with Session(review["engine"]) as db:
        assert db.get(Assignment, review["assignment"]).cancelled_at is None
