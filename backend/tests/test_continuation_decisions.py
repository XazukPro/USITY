"""Continuation must retain independent review work and never replay its effects."""

import json
from copy import deepcopy
from datetime import timedelta

import pytest
from sqlalchemy import select, update
from sqlalchemy.orm import Session

from app.material_library import Material
from app.models import Assignment, Draft, TelegramInbox, TelegramIntegration, utc_now
from app.telegram import process_ready_messages, queue_text_message


class ContinuationProvider:
    model_name = "continuation-fixture"

    def __init__(self, material_on_continuation="repeat"):
        self.material_on_continuation = material_on_continuation

    def complete(self, prompt, payload):
        messages = json.loads(payload)["messages"]
        ids = [message["id"] for message in messages]
        complete = 11 in ids
        if "НОВОЕ домашнее" in prompt:
            response = {
                "kind": "new_homework" if complete else "incomplete_homework",
                "text": "Решить № 4, 5" if complete else None,
                "source_ids": ids,
                "uncertain": not complete,
            }
        elif "привязываешь" in prompt:
            response = {
                "subject_mention": "математике",
                "subgroup_mentions": None,
                "deadline_kind": "next_lesson",
                "deadline_date": None,
                "source_ids": ids,
            }
        elif "учебные материалы" in prompt:
            if complete and self.material_on_continuation == "error":
                raise RuntimeError("synthetic material agent outage")
            response = {"materials": []}
            if not complete or self.material_on_continuation == "repeat":
                response["materials"] = [
                    {
                        "source_ids": ids if complete else [10],
                        "attachment_id": "10:link:0",
                        "category_id": "Ссылки",
                        "subject_ids": ["Математика"],
                        "assignment_ids": [],
                        "reason": "Новый вывод модели"
                        if complete
                        else "Исходная ссылка",
                        "uncertain": False,
                    }
                ]
        elif "дубли" in prompt:
            response = {"duplicates": []}
        else:
            response = {"changes": []}
        return json.dumps(response, ensure_ascii=False)


def enqueue(s, provider, message_id, text):
    queue_text_message(s["engine"], "chat", "topic", message_id, text, utc_now())
    with s["engine"].begin() as db:
        db.execute(
            update(TelegramInbox).values(received_at=utc_now() - timedelta(minutes=1))
        )
    return process_ready_messages(s["engine"], provider, "fixture", five_agents=True)[0]


def start(s, provider):
    with s["engine"].begin() as db:
        db.execute(
            TelegramIntegration.__table__.insert(),
            {
                "group_id": s["group"],
                "chat_id": "chat",
                "topic_id": "topic",
            },
        )
    return enqueue(
        s,
        provider,
        10,
        "К следующей паре по математике нужно решить. https://example.test/book",
    )


def decide_material(s, draft_id, version, action="approve"):
    return s["client"].post(
        f"/groups/{s['group']}/review/{draft_id}/proposals/3/0/decision",
        headers={"Authorization": "Bearer " + s["users"]["admin"]},
        json={"action": action, "expected_version": version},
    )


@pytest.mark.parametrize("action", ["approve", "reject"])
@pytest.mark.parametrize("mode", ["repeat", "omit", "error"])
def test_continuation_preserves_material_decision_and_cannot_publish_again(
    setup, action, mode
):
    s = setup
    provider = ContinuationProvider(mode)
    draft_id = start(s, provider)
    decision = decide_material(s, draft_id, 1, action)
    assert decision.status_code == 200, decision.text
    with Session(s["engine"]) as db:
        old = deepcopy(db.get(Draft, draft_id).proposal_set)
    assert enqueue(s, provider, 11, "номера 4 и 5 на странице 20") == draft_id
    with Session(s["engine"]) as db:
        draft = db.get(Draft, draft_id)
        run = draft.proposal_set["runs"][3]
        assert draft.version == 3
        assert run["status"] == "proposed"
        assert run["proposals"] == old["runs"][3]["proposals"]
        assert draft.proposal_set["history"][0]["runs"] == old["runs"]
    repeat = decide_material(s, draft_id, 3)
    assert repeat.status_code == 409, repeat.text
    with Session(s["engine"]) as db:
        materials = list(
            db.scalars(select(Material).where(Material.group_id == s["group"]))
        )
        assert len(materials) == (1 if action == "approve" else 0)


@pytest.mark.parametrize("mode", ["omit", "error"])
def test_unresolved_material_survives_missing_result_and_remains_actionable(
    setup, mode
):
    s = setup
    provider = ContinuationProvider(mode)
    draft_id = start(s, provider)
    assert enqueue(s, provider, 11, "номера 4 и 5 на странице 20") == draft_id
    with Session(s["engine"]) as db:
        draft = db.get(Draft, draft_id)
        run = draft.proposal_set["runs"][3]
        assert run["status"] == "proposed"
        assert len(run["proposals"]) == 1
        assert run["proposals"][0]["fields"]["attachment_id"] == "10:link:0"
        assert run["proposals"][0].get("decision") is None
        assert [message["id"] for message in draft.source_context["messages"]] == [
            10,
            11,
        ]
    result = decide_material(s, draft_id, 2)
    assert result.status_code == 200, result.text
    with Session(s["engine"]) as db:
        materials = list(
            db.scalars(select(Material).where(Material.group_id == s["group"]))
        )
        assert len(materials) == 1
        assert materials[0].url == "https://example.test/book"


@pytest.mark.parametrize(
    "agent,kind,fields,changed_fields",
    [
        (
            "assignment_change",
            "assignment_change",
            {"assignment_id": "a", "kind": "update"},
            {"assignment_id": "a", "kind": "cancel"},
        ),
        (
            "duplicate_conflict",
            "duplicate_conflict",
            {"assignment_id": "a"},
            {"assignment_id": "b"},
        ),
    ],
)
def test_merge_keeps_decisions_by_target_kind_and_unordered_sources(
    agent, kind, fields, changed_fields
):
    from app.live_pipeline import _merge_continuation_runs

    original = {
        "proposal_type": kind,
        "source_ids": [10, 11],
        "fields": fields,
        "reason": "original",
        "decision": {"status": "rejected"},
    }
    unresolved = {
        "proposal_type": kind,
        "source_ids": [12],
        "fields": fields,
        "reason": "awaiting review",
    }
    new_target = {
        "proposal_type": kind,
        "source_ids": [10, 11],
        "fields": changed_fields,
        "reason": "different action",
    }
    new_sources = {
        "proposal_type": kind,
        "source_ids": [13],
        "fields": fields,
        "reason": "different evidence",
    }
    repeated = {k: v for k, v in original.items() if k != "decision"}
    repeated.update(source_ids=[11, 10], reason="re-extracted")
    old = [
        {"agent_id": agent, "status": "proposed", "proposals": [original, unresolved]}
    ]
    new = [
        {
            "agent_id": agent,
            "status": "proposed",
            "proposals": [new_target, repeated, new_sources, deepcopy(repeated)],
        }
    ]
    before = deepcopy((old, new))
    merged = _merge_continuation_runs(old, new)
    assert merged[0]["proposals"] == [original, unresolved, new_target, new_sources]
    assert (old, new) == before
    merged[0]["proposals"][0]["decision"]["status"] = "changed by caller"
    assert (old, new) == before


def test_merge_restores_absent_ancillary_run_without_overwriting_current_homework():
    from app.live_pipeline import _merge_continuation_runs

    material = {
        "proposal_type": "material",
        "fields": {"attachment_id": "10:link:0"},
        "source_ids": [10],
    }
    old = [
        {
            "agent_id": "homework_detection",
            "status": "proposed",
            "proposals": [{"proposal_type": "incomplete_homework"}],
        },
        {
            "agent_id": "material_proposal",
            "status": "proposed",
            "proposals": [material],
        },
    ]
    new = [
        {
            "agent_id": "homework_detection",
            "status": "proposed",
            "proposals": [{"proposal_type": "new_homework"}],
        }
    ]
    assert _merge_continuation_runs(old, new) == [new[0], old[1]]


class AssignmentContinuationProvider(ContinuationProvider):
    def __init__(self, mode="repeat"):
        super().__init__()
        self.mode = mode

    def complete(self, prompt, payload):
        if "отмены и изменения активных ДЗ" not in prompt:
            return super().complete(prompt, payload)
        context = json.loads(payload)
        continued = any(message["id"] == 11 for message in context["messages"])
        source_ids = [] if continued and self.mode == "omit" else [10]
        if continued and self.mode == "new_source":
            source_ids.append(11)
        return json.dumps(
            {
                "changes": [
                    {
                        "kind": "update",
                        "assignment_id": context["active_assignments"][0]["id"],
                        "source_ids": [source_id],
                        "new_text": "Решить № 3",
                        "new_due_date": None,
                        "reason": "Исправление номера",
                        "uncertain": False,
                    }
                    for source_id in source_ids
                ]
            }
        )


def seed_assignment(s):
    assignment_id = "existing-" + s["draft"]
    with Session(s["engine"]) as db, db.begin():
        db.get(Draft, s["draft"]).status = "approved"
        db.add(
            Assignment(
                id=assignment_id,
                group_id=s["group"],
                draft_id=s["draft"],
                lesson_id=s["lesson"],
                text="Решить № 2",
                version=1,
            )
        )
    return assignment_id


def test_assignment_proposal_captures_version_at_creation_outside_model_fields(setup):
    seed_assignment(setup)
    draft_id = start(setup, AssignmentContinuationProvider())
    with Session(setup["engine"]) as db:
        proposal = db.get(Draft, draft_id).proposal_set["runs"][4]["proposals"][0]
        assert proposal.get("assignment_snapshot_version") == 1
        assert "assignment_snapshot_version" not in proposal["fields"]


@pytest.mark.parametrize("legacy", [False, True])
@pytest.mark.parametrize("mode", ["repeat", "omit", "new_source"])
def test_continuation_preserves_original_assignment_version_after_assignment_changes(
    setup, legacy, mode
):
    s = setup
    assignment_id = seed_assignment(s)
    provider = AssignmentContinuationProvider(mode)
    draft_id = start(s, provider)
    with Session(s["engine"]) as db, db.begin():
        draft = db.get(Draft, draft_id)
        if legacy:
            proposals = deepcopy(draft.proposal_set)
            proposals["runs"][4]["proposals"][0].pop(
                "assignment_snapshot_version", None
            )
            draft.proposal_set = proposals
        assignment = db.get(Assignment, assignment_id)
        assignment.text = "Изменено другим админом"
        assignment.version = 2
    assert enqueue(s, provider, 11, "номера 4 и 5 на странице 20") == draft_id
    with Session(s["engine"]) as db:
        draft = db.get(Draft, draft_id)
        assert draft.source_context["active_assignments"][0]["version"] == 2
        proposals = draft.proposal_set["runs"][4]["proposals"]
        assert proposals[0]["source_ids"] == [10]
        assert proposals[0].get("assignment_snapshot_version") == 1
        assert "assignment_snapshot_version" not in proposals[0]["fields"]
        if mode == "new_source":
            assert proposals[1]["source_ids"] == [11]
            assert proposals[1].get("assignment_snapshot_version") == 2
        assert db.get(Assignment, assignment_id).text == "Изменено другим админом"


def test_existing_proposal_snapshot_is_not_refreshed_from_later_context():
    from app.live_pipeline import _with_assignment_snapshots

    runs = [
        {
            "agent_id": "assignment_change",
            "proposals": [
                {
                    "proposal_type": "assignment_change",
                    "fields": {"assignment_id": "a"},
                    "assignment_snapshot_version": 1,
                },
            ],
        }
    ]
    before = deepcopy(runs)
    result = _with_assignment_snapshots(runs, [{"id": "a", "version": 2}])
    assert result[0]["proposals"][0]["assignment_snapshot_version"] == 1
    assert runs == before
