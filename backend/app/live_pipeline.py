"""Telegram-to-review pipeline. All model results remain human-reviewed proposals."""

import json
import re
from copy import deepcopy
from dataclasses import asdict
from datetime import timedelta
from hashlib import sha256
from zoneinfo import ZoneInfo

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.agents.contracts import Attachment, EventBundle, SourceMessage
from app.agents.registry import build_default_agents, run_all_agents
from app.ingestion import _run_json, check_source
from app.material_library import CATEGORIES, Category
from app.models import (
    Assignment,
    Draft,
    IngestedEvent,
    Lesson,
    LessonDetails,
    utc_now,
)

CONTINUATION_WINDOW = timedelta(minutes=15)
STUDY_TIMEZONE = ZoneInfo("Europe/Moscow")


def _links(message_id, text):
    urls = dict.fromkeys(re.findall(r"https?://[^\s<>]+", text))
    return tuple(
        Attachment(
            id=f"{message_id}:link:{index}", kind="link", url=url.rstrip(".,;!?)")
        )
        for index, url in enumerate(urls)
    )


def _summary(runs, bundle):
    proposals = [p for run in runs for p in run.proposals]
    homework = next(
        (
            p
            for p in proposals
            if p.proposal_type in {"new_homework", "incomplete_homework"}
        ),
        None,
    )
    binding = next(
        (p for p in proposals if p.proposal_type == "schedule_binding"), None
    )
    if (
        homework
        and binding
        and not set(binding.source_ids).issubset(homework.source_ids)
    ):
        binding = None
    fields = dict(binding.fields) if binding else {}
    lesson = next(
        (
            lesson_row
            for lesson_row in bundle.lessons
            if lesson_row["id"] == fields.get("lesson_id")
        ),
        None,
    )
    subject = next(
        (s["name"] for s in bundle.subjects if s["id"] == fields.get("subject_id")),
        None,
    )
    text = homework.fields.get("text") if homework else None
    waiting = homework is not None and homework.proposal_type == "incomplete_homework"
    missing = []
    if not text:
        missing.append("text")
    if not lesson:
        missing.append("lesson")
    errors = any(run.status == "error" for run in runs)
    uncertain = any(p.uncertainty for p in proposals)
    actions = any(p.proposal_type not in {"schedule_binding"} for p in proposals)
    state = (
        "waiting"
        if waiting
        else "ready"
        if homework and not missing and not errors and not uncertain
        else "needs_review"
    )
    if not homework and not actions and not errors:
        state = "no_action"
    return {
        "state": state,
        "text": text,
        "subject": subject,
        "lesson_id": lesson["id"] if lesson else None,
        "due_at": lesson["starts_at"] if lesson else None,
        "subgroups": [
            int(g) for g in (fields.get("subgroup_ids") or []) if str(g).isdigit()
        ],
        "missing_fields": missing,
        "homework": homework is not None,
    }


def _with_assignment_snapshots(runs, assignments):
    """Pin each change to its own input snapshot, never a later draft context.

    An explicit null records missing/ambiguous legacy evidence so consumers must
    reject it rather than fall back to the continuation's newer context.
    """
    annotated = deepcopy(runs)
    for run in annotated:
        if run.get("agent_id") != "assignment_change":
            continue
        for proposal in run.get("proposals", []):
            if (
                proposal.get("proposal_type") != "assignment_change"
                or "assignment_snapshot_version" in proposal
            ):
                continue
            target = proposal.get("fields", {}).get("assignment_id")
            matches = [
                item for item in (assignments or [])
                if item.get("id") == target
            ]
            version = matches[0].get("version") if len(matches) == 1 else None
            proposal["assignment_snapshot_version"] = (
                version if type(version) is int and version >= 1 else None
            )
    return annotated


def _merge_continuation_runs(previous_runs, current_runs):
    """Retain reviewable ancillary work and decisions; never execute an action.

    Old proposals keep their positions and evidence, including human decisions.
    Newly discovered identities follow them. Latest run diagnostics are retained
    even when an error/not_found run carries proposals from the preceding episode.
    """
    ancillary = {
        "material_proposal": "material",
        "assignment_change": "assignment_change",
        "duplicate_conflict": "duplicate_conflict",
    }

    def identity(proposal):
        kind = proposal.get("proposal_type")
        fields = proposal.get("fields", {})
        if kind == "material":
            target = fields.get("attachment_id")
            return (kind, target) if target else None
        if kind in {"assignment_change", "duplicate_conflict"}:
            target = fields.get("assignment_id")
            if target:
                sources = tuple(sorted(proposal.get("source_ids", [])))
                if kind == "assignment_change":
                    return (kind, target, fields.get("kind"), sources)
                return (kind, target, sources)
        return None

    merged = deepcopy(current_runs)
    by_agent = {run["agent_id"]: run for run in merged}
    for previous in previous_runs:
        agent = previous["agent_id"]
        expected_kind = ancillary.get(agent)
        if expected_kind is None:
            continue
        retained = [
            deepcopy(proposal)
            for proposal in previous.get("proposals", [])
            if proposal.get("proposal_type") == expected_kind
        ]
        if not retained:
            continue
        current = by_agent.get(agent)
        if current is None:
            current = deepcopy(previous)
            current["proposals"] = []
            merged.append(current)
            by_agent[agent] = current
        proposals = []
        positions = {}
        for proposal in retained + current.get("proposals", []):
            key = identity(proposal)
            if key is not None and key in positions:
                # A decided duplicate must win over an undecided copy, including
                # old bundles that already contain the same identity twice.
                position = positions[key]
                if (
                    proposals[position].get("decision") is None
                    and proposal.get("decision") is not None
                ):
                    proposals[position] = proposal
                continue
            if key is not None:
                positions[key] = len(proposals)
            proposals.append(proposal)
        current["proposals"] = proposals
        current["status"] = "proposed"
    return merged


def process_bundle(engine, integration, event_id, chunk, provider):
    now = utc_now().astimezone(STUDY_TIMEZONE)
    input_ids = {row.message_id for row in chunk}
    with Session(engine) as db:
        existing = db.get(IngestedEvent, (integration.group_id, event_id))
        if existing:
            return existing.draft_id
        lessons = list(
            db.scalars(select(Lesson).where(Lesson.group_id == integration.group_id))
        )
        details = {
            d.lesson_id: d
            for d in db.scalars(
                select(LessonDetails).where(
                    LessonDetails.lesson_id.in_(
                        [lesson_row.id for lesson_row in lessons]
                    )
                )
            )
        }
        subjects = {}
        for lesson in lessons:
            subject = subjects.setdefault(
                lesson.subject,
                {
                    "id": lesson.subject,
                    "name": lesson.subject,
                    "aliases": [],
                    "subgroup_ids": [],
                },
            )
            detail = details.get(lesson.id)
            if detail and detail.subgroup is not None:
                value = str(detail.subgroup)
                if value not in subject["subgroup_ids"]:
                    subject["subgroup_ids"].append(value)
        assignments = tuple(
            {"id": a.id, "text": a.text, "lesson_id": a.lesson_id, "version": a.version}
            for a in db.scalars(
                select(Assignment).where(
                    Assignment.group_id == integration.group_id,
                    Assignment.cancelled_at.is_(None),
                )
            )
        )
        candidates = [
            d
            for d in db.scalars(
                select(Draft).where(
                    Draft.group_id == integration.group_id,
                    Draft.status == "pending",
                    Draft.created_at >= now - CONTINUATION_WINDOW,
                )
            )
            if (d.proposal_set or {}).get("summary", {}).get("state") == "waiting"
            and d.source_context.get("chat_id") == integration.chat_id
            and d.source_context.get("topic_id") == integration.topic_id
        ]
        previous = candidates[0] if len(candidates) == 1 else None
        if previous and len(previous.source_context["messages"]) + len(chunk) > 100:
            previous = None
        previous_id = previous.id if previous else None
        previous_version = previous.version if previous else None
        old_messages = previous.source_context["messages"] if previous else []
        categories = tuple(
            {"id": name, "name": name}
            for name in sorted(
                set(CATEGORIES)
                | {
                    c.name
                    for c in db.scalars(
                        select(Category).where(
                            Category.group_id == integration.group_id
                        )
                    )
                }
            )
        )
    messages = [
        SourceMessage(
            id=m["id"],
            chat_id=integration.chat_id,
            topic_id=integration.topic_id,
            text=m["text"],
            sent_at=m["sent_at"],
            attachments=_links(m["id"], m["text"]),
        )
        for m in old_messages
    ]
    old_ids = {m.id for m in messages}
    messages.extend(
        SourceMessage(
            row.message_id,
            row.chat_id,
            row.topic_id,
            row.text,
            row.sent_at.isoformat(),
            attachments=_links(row.message_id, row.text),
        )
        for row in chunk
        if row.message_id not in old_ids
    )
    bundle = EventBundle(
        integration.group_id,
        integration.chat_id,
        integration.topic_id,
        integration.chat_id,
        integration.topic_id,
        tuple(messages),
        subjects=tuple(subjects.values()),
        lessons=tuple(
            {
                "id": lesson_row.id,
                "subject_id": lesson_row.subject,
                "starts_at": lesson_row.starts_at.astimezone(
                    STUDY_TIMEZONE
                ).isoformat(),
                "subgroup_ids": [str(details[lesson_row.id].subgroup)]
                if lesson_row.id in details and details[lesson_row.id].subgroup
                else [],
            }
            for lesson_row in lessons
        ),
        active_assignments=assignments,
        categories=categories,
    )
    with Session(engine) as db:
        check_source(db, bundle, bundle.chat_id)
    runs = run_all_agents(bundle, build_default_agents(provider, now))
    summary = _summary(runs, bundle)
    homework = next(
        (
            p
            for run in runs
            for p in run.proposals
            if p.proposal_type in {"new_homework", "incomplete_homework"}
        ),
        None,
    )
    # Continuation requires evidence from BOTH episodes, not just temporal proximity.
    extends_previous = bool(
        previous_id
        and homework
        and set(homework.source_ids) & old_ids
        and set(homework.source_ids) & input_ids
    )
    if previous_id and not extends_previous:
        # Re-run new input without old context so unrelated text cannot inherit its subject.
        fresh = EventBundle(
            bundle.group_id,
            bundle.chat_id,
            bundle.topic_id,
            bundle.connected_chat_id,
            bundle.connected_topic_id,
            tuple(m for m in bundle.messages if m.id in input_ids),
            subjects=bundle.subjects,
            lessons=bundle.lessons,
            active_assignments=bundle.active_assignments,
            categories=bundle.categories,
        )
        bundle = fresh
        runs = run_all_agents(bundle, build_default_agents(provider, now))
        summary = _summary(runs, bundle)
    context = asdict(bundle)
    fingerprint = sha256(json.dumps(context, sort_keys=True).encode()).hexdigest()
    proposal_set = {
        "schema_version": 2,
        "summary": summary,
        "runs": _with_assignment_snapshots(
            [_run_json(run) for run in runs], bundle.active_assignments
        ),
    }
    with Session(engine) as db, db.begin():
        check_source(db, bundle, bundle.chat_id, lock=True)
        existing = db.get(IngestedEvent, (integration.group_id, event_id))
        if existing:
            return existing.draft_id
        draft = None
        if extends_previous:
            draft = db.scalar(
                select(Draft).where(Draft.id == previous_id).with_for_update()
            )
            if (
                draft is None
                or draft.status != "pending"
                or draft.version != previous_version
            ):
                # Preserve administrator's concurrent decision. Retry on fresh context.
                raise RuntimeError(
                    "Черновик изменился во время обработки; повторите обработку"
                )
            history = list((draft.proposal_set or {}).get("history", []))
            history.append(
                {
                    "version": draft.version,
                    "source_context": draft.source_context,
                    "runs": draft.proposal_set["runs"],
                    "summary": draft.proposal_set["summary"],
                }
            )
            proposal_set["history"] = history
            proposal_set["runs"] = _merge_continuation_runs(
                _with_assignment_snapshots(
                    draft.proposal_set["runs"],
                    draft.source_context.get("active_assignments", []),
                ),
                proposal_set["runs"],
            )
            draft.version += 1
        if summary["state"] != "no_action":
            if draft is None:
                draft = Draft(group_id=bundle.group_id, event_id=event_id)
                db.add(draft)
            draft.text = summary["text"] or (
                "Ожидается продолжение задания"
                if summary["state"] == "waiting"
                else "Предложения требуют проверки"
            )
            draft.source_context = context
            draft.model_output = {"kind": "five_agent_bundle", "summary": summary}
            draft.model_version = getattr(
                provider, "model", getattr(provider, "model_name", "unknown")
            )
            draft.prompt_version = "five-agent-v2"
            draft.proposal_set = proposal_set
            db.flush()
        draft_id = draft.id if draft else None
        db.add(
            IngestedEvent(
                group_id=bundle.group_id,
                event_id=event_id,
                payload_hash=fingerprint,
                draft_id=draft_id,
            )
        )
        return draft_id
