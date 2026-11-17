"""Install independent human decisions for schema-v2 agent proposals.

Decisions live at runs[i].proposals[j].decision; the model evidence, summary and
draft-wide human_output/status are preserved. Every decision increments the
draft version, including rejections. The enclosing draft stays pending for the
existing whole-draft workflow; this endpoint does not finalize the bundle.

Supported approvals: assignment updates and soft cancellation, duplicate
acknowledgement (no merge), and trusted HTTPS attachment links. Cancellation
preserves assignment, audience and completion rows and increments the revision.
Files and material/assignment associations require additional integration and
return 422 without consuming the proposal. Core homework/binding proposals use
the whole-draft workflow to keep the publication summary consistent.
"""

from copy import deepcopy
from typing import Annotated, Literal

from fastapi import HTTPException, Path
from pydantic import Field, ValidationError, model_validator
from sqlalchemy import select, update

from app.auth import require_group
from app.material_library import LinkInput, Material, _validate_catalog
from app.models import Assignment, Draft, Lesson, LessonDetails, utc_now
from app.schemas import Identifier, InputModel, Text


class ProposalDecision(InputModel):
    action: Literal["approve", "reject"]
    expected_version: int = Field(ge=1, strict=True)
    text: Text | None = None
    lesson_id: Identifier | None = None

    @model_validator(mode="after")
    def reject_has_no_changes(self):
        if self.action == "reject" and (
            self.text is not None or self.lesson_id is not None
        ):
            raise ValueError("Отклонение не содержит публикуемых полей")
        return self


def _conflict(draft, decision=None):
    return HTTPException(
        409,
        {
            "message": "Черновик или предложение уже обработаны либо изменены",
            "current_status": draft.status,
            "current_version": draft.version,
            "decision": decision,
        },
    )


def _select_proposal(proposals, run_index, proposal_index):
    if not isinstance(proposals, dict) or proposals.get("schema_version") != 2:
        raise HTTPException(422, "Нужен набор предложений версии 2")
    runs = proposals.get("runs")
    if not isinstance(runs, list):
        raise HTTPException(422, "Некорректный набор предложений")
    if run_index >= len(runs):
        raise HTTPException(404, "Предложение не найдено")
    run = runs[run_index]
    if not isinstance(run, dict) or run.get("status") != "proposed":
        raise HTTPException(422, "Запуск агента не содержит доступных предложений")
    items = run.get("proposals")
    if not isinstance(items, list):
        raise HTTPException(422, "Некорректный набор предложений")
    if proposal_index >= len(items):
        raise HTTPException(404, "Предложение не найдено")
    proposal = items[proposal_index]
    if not isinstance(proposal, dict) or not isinstance(proposal.get("fields"), dict):
        raise HTTPException(422, "Некорректное предложение")
    if proposal.get("agent_id", run.get("agent_id")) != run.get("agent_id"):
        raise HTTPException(422, "Агент предложения не совпадает с запуском")
    return run, proposal


def _source_messages(draft, proposal):
    context = draft.source_context
    if (
        not isinstance(context, dict)
        or context.get("group_id", draft.group_id) != draft.group_id
    ):
        raise HTTPException(422, "Контекст не принадлежит группе")
    messages = context.get("messages")
    ids = proposal.get("source_ids")
    if (
        not isinstance(messages, list)
        or not isinstance(ids, list)
        or not ids
        or any(type(i) is not int for i in ids)
        or len(set(ids)) != len(ids)
        or any(
            not isinstance(m, dict) or type(m.get("id")) is not int for m in messages
        )
    ):
        raise HTTPException(422, "Некорректные источники предложения")
    known = {m["id"] for m in messages}
    if len(known) != len(messages) or not set(ids).issubset(known):
        raise HTTPException(422, "Предложение ссылается на неизвестные источники")
    return messages


def _update_assignment(db, draft, proposal, body):
    fields = proposal["fields"]
    kind = fields.get("kind")
    if kind not in {"update", "cancel"}:
        raise HTTPException(422, "Неизвестный вид изменения ДЗ")
    if kind == "cancel" and (body.text is not None or body.lesson_id is not None):
        raise HTTPException(422, "Отмена ДЗ не содержит нового текста или пары")
    if kind == "update" and (body.text is None or body.lesson_id is None):
        raise HTTPException(422, "Для изменения ДЗ явно укажите текст и будущую пару")
    _source_messages(draft, proposal)
    assignment_id = fields.get("assignment_id")
    if not isinstance(assignment_id, str) or not assignment_id:
        raise HTTPException(422, "Не указан идентификатор ДЗ")
    assignment = db.scalar(
        select(Assignment)
        .where(
            Assignment.id == assignment_id,
            Assignment.group_id == draft.group_id,
        )
        .with_for_update()
    )
    if assignment is None:
        raise HTTPException(404, "ДЗ не найдено")
    if assignment.cancelled_at is not None:
        raise HTTPException(
            409,
            {
                "message": "ДЗ уже отменено",
                "assignment_id": assignment.id,
                "current_assignment_version": assignment.version,
                "current_version": draft.version,
            },
        )
    if "assignment_snapshot_version" in proposal:
        # Continuations refresh source_context but retain earlier proposals.
        # Their immutable version must not be replaced by that newer context,
        # including when the stamped value is malformed or explicitly null.
        snapshot_version = proposal["assignment_snapshot_version"]
    else:
        # Legacy proposals predate the immutable per-proposal stamp.
        snapshots = draft.source_context.get("active_assignments")
        matches = (
            [
                item
                for item in snapshots
                if isinstance(item, dict) and item.get("id") == assignment_id
            ]
            if isinstance(snapshots, list)
            else []
        )
        snapshot_version = matches[0].get("version") if len(matches) == 1 else None
    if type(snapshot_version) is not int:
        raise HTTPException(422, "Нет исходной версии ДЗ; требуется новое предложение")
    if snapshot_version != assignment.version:
        raise HTTPException(
            409,
            {
                "message": "ДЗ изменилось после работы агента; требуется новое предложение",
                "assignment_id": assignment.id,
                "current_assignment_version": assignment.version,
                "current_version": draft.version,
            },
        )
    if kind == "cancel":
        previous_version = assignment.version
        previous = {
            "text": assignment.text,
            "lesson_id": assignment.lesson_id,
            "version": previous_version,
            "cancelled_at": None,
        }
        assignment.cancelled_at = utc_now()
        assignment.version += 1
        return {
            "assignment_id": assignment.id,
            "previous_assignment_version": previous_version,
            "assignment_version": assignment.version,
            "previous_cancelled_at": None,
            "cancelled_at": assignment.cancelled_at.isoformat(),
            "previous_assignment": previous,
        }
    lesson = db.scalar(
        select(Lesson)
        .where(
            Lesson.id == body.lesson_id,
            Lesson.group_id == draft.group_id,
        )
        .with_for_update()
    )
    if lesson is None:
        raise HTTPException(404, "Пара не найдена")
    if lesson.starts_at <= utc_now():
        raise HTTPException(422, "Выберите будущую пару: эта пара уже началась")
    original = db.get(Lesson, assignment.lesson_id)
    old_details = db.get(LessonDetails, assignment.lesson_id)
    new_details = db.get(LessonDetails, lesson.id)
    if (
        original is None
        or original.group_id != draft.group_id
        or original.subject != lesson.subject
        or (old_details.subgroup if old_details else None)
        != (new_details.subgroup if new_details else None)
    ):
        raise HTTPException(
            422, "Изменение предмета или подгруппы этим действием не поддерживается"
        )
    previous_version = assignment.version
    assignment.text = body.text
    assignment.lesson_id = lesson.id
    # Existing completion rows remain as history. Readers compare their version
    # with Assignment.version, so every approved correction resets completion.
    assignment.version += 1
    return {
        "assignment_id": assignment.id,
        "previous_assignment_version": previous_version,
        "assignment_version": assignment.version,
    }


def _publish_link(db, draft, proposal, body, member):
    if body.lesson_id is not None:
        raise HTTPException(422, "Материал не привязывается к паре этим действием")
    messages = _source_messages(draft, proposal)
    fields = proposal["fields"]
    attachment_id = fields.get("attachment_id")
    if not isinstance(attachment_id, str) or not attachment_id:
        raise HTTPException(422, "Не указано исходное вложение")
    matches = [
        (message["id"], attachment)
        for message in messages
        for attachment in (message.get("attachments") or [])
        if isinstance(attachment, dict) and attachment.get("id") == attachment_id
    ]
    if len(matches) != 1 or matches[0][0] not in proposal["source_ids"]:
        raise HTTPException(422, "Нет однозначного вложения в указанных источниках")
    attachment = matches[0][1]
    if attachment.get("kind") != "link":
        raise HTTPException(
            422,
            "Публикация файлов требует безопасной загрузки и пока не поддерживается",
        )
    if fields.get("assignment_ids") not in (None, []):
        raise HTTPException(422, "Привязка материала к ДЗ пока не поддерживается")
    url = attachment.get("url")
    try:
        metadata = LinkInput(
            scope="group",
            title=body.text or (url[:200] if isinstance(url, str) else None),
            category=fields.get("category_id"),
            subjects=fields.get("subject_ids"),
            url=url,
        )
    except ValidationError as exc:
        raise HTTPException(
            422, "Проверьте HTTPS-ссылку, название, категорию и предметы материала"
        ) from exc
    _validate_catalog(db, draft.group_id, metadata)
    material = Material(
        group_id=draft.group_id,
        creator=member.user_id,
        reviewed_by=member.user_id,
        status="published",
        **metadata.model_dump(exclude={"subjects"}),
        subjects=list(dict.fromkeys(metadata.subjects)),
    )
    db.add(material)
    db.flush()
    return {"material_id": material.id}


def install_proposal_review(app, DB, Member):
    path = "/groups/{group_id}/review/{draft_id}/proposals/{run_index}/{proposal_index}/decision"

    @app.post(path)
    def decide_proposal(
        group_id: str,
        draft_id: str,
        run_index: Annotated[int, Path(ge=0)],
        proposal_index: Annotated[int, Path(ge=0)],
        body: ProposalDecision,
        db: DB,
        member: Member,
    ):
        require_group(member, group_id, admin=True)
        # Authentication already starts the session transaction. Do not nest a
        # db.begin() here; the decision and all side effects share this transaction.
        try:
            draft = db.scalar(
                select(Draft)
                .where(
                    Draft.id == draft_id,
                    Draft.group_id == group_id,
                )
                .with_for_update()
            )
            if draft is None:
                raise HTTPException(404, "Черновик не найден")
            if draft.status != "pending" or draft.version != body.expected_version:
                raise _conflict(draft)
            proposals = deepcopy(draft.proposal_set)
            run, proposal = _select_proposal(proposals, run_index, proposal_index)
            if proposal.get("proposal_type") in {
                "new_homework",
                "incomplete_homework",
                "schedule_binding",
            }:
                raise HTTPException(
                    422,
                    "Рассмотрите ДЗ и привязку к паре через решение по всему черновику",
                )
            if proposal.get("decision") is not None:
                raise _conflict(draft, proposal["decision"])
            status = "rejected"
            effects = {}
            if body.action == "approve":
                kind = proposal.get("proposal_type")
                agent = run.get("agent_id")
                if kind == "assignment_change" and agent == "assignment_change":
                    effects = _update_assignment(db, draft, proposal, body)
                    status = "approved"
                elif kind == "duplicate_conflict" and agent == "duplicate_conflict":
                    if body.text is not None or body.lesson_id is not None:
                        raise HTTPException(422, "Проверка дубля не изменяет ДЗ")
                    status = "reviewed"
                elif kind == "material" and agent == "material_proposal":
                    effects = _publish_link(db, draft, proposal, body, member)
                    status = "approved"
                else:
                    raise HTTPException(
                        422, "Подтверждение этого типа предложения не поддерживается"
                    )
            audit = {
                "action": body.action,
                "status": status,
                "decided_by": member.user_id,
                "decided_at": utc_now().isoformat(),
                "human_output": body.model_dump(exclude_unset=True),
                **effects,
            }
            proposal["decision"] = audit
            result = db.execute(
                update(Draft)
                .where(
                    Draft.id == draft_id,
                    Draft.group_id == group_id,
                    Draft.status == "pending",
                    Draft.version == body.expected_version,
                )
                .values(
                    version=Draft.version + 1,
                    proposal_set=proposals,
                )
                .execution_options(synchronize_session=False)
            )
            if result.rowcount != 1:
                db.rollback()
                db.refresh(draft)
                raise _conflict(draft)
            db.commit()
            return {
                "status": status,
                "version": body.expected_version + 1,
                "draft_status": "pending",
                "run_index": run_index,
                "proposal_index": proposal_index,
                "decision": audit,
                "assignment_id": effects.get("assignment_id"),
                "material_id": effects.get("material_id"),
            }
        except Exception:
            db.rollback()
            raise
