from contextlib import asynccontextmanager
from typing import Annotated

from fastapi import Depends, FastAPI, Header, HTTPException
from sqlalchemy import exists, select, update
from sqlalchemy.orm import Session

from app.auth import authenticate, require_group
from app.db import make_engine
from app.models import Assignment, Completion, Draft, Lesson, utc_now
from app.schemas import CompletionInput, DecisionInput, LessonInput


def lesson_json(lesson):
    return {
        key: getattr(lesson, key)
        for key in ("id", "subject", "starts_at", "ends_at", "teacher", "location")
    }


def create_app(database_url):
    engine = make_engine(database_url)

    @asynccontextmanager
    async def lifespan(app):
        yield
        engine.dispose()

    app = FastAPI(title="USITY API", version="0.1.0", lifespan=lifespan)

    def database():
        with Session(engine) as session:
            yield session

    DB = Annotated[Session, Depends(database)]

    def current_member(db: DB, authorization: Annotated[str | None, Header()] = None):
        return authenticate(db, authorization)

    Member = Annotated[object, Depends(current_member)]

    @app.get("/me")
    def profile(member: Member):
        return {
            "user_id": member.user_id,
            "group_id": member.group_id,
            "role": member.role,
        }

    @app.get("/health")
    def health():
        return {"status": "ok"}

    @app.get("/groups/{group_id}/lessons")
    def lessons(group_id: str, db: DB, member: Member):
        require_group(member, group_id)
        return [
            lesson_json(row)
            for row in db.scalars(
                select(Lesson)
                .where(Lesson.group_id == group_id)
                .order_by(Lesson.starts_at, Lesson.id)
            )
        ]

    @app.post("/groups/{group_id}/lessons", status_code=201)
    def create_lesson(group_id: str, body: LessonInput, db: DB, member: Member):
        require_group(member, group_id, admin=True)
        lesson = Lesson(group_id=group_id, **body.model_dump())
        db.add(lesson)
        db.commit()
        return lesson_json(lesson)

    @app.get("/groups/{group_id}/review")
    def review(group_id: str, db: DB, member: Member):
        require_group(member, group_id, admin=True)
        return [
            {
                key: getattr(row, key)
                for key in (
                    "id",
                    "text",
                    "version",
                    "status",
                    "source_context",
                    "model_output",
                    "model_version",
                    "prompt_version",
                )
            }
            for row in db.scalars(
                select(Draft)
                .where(Draft.group_id == group_id, Draft.status == "pending")
                .order_by(Draft.created_at, Draft.id)
            )
        ]

    @app.post("/groups/{group_id}/review/{draft_id}/decision")
    def decision(
        group_id: str, draft_id: str, body: DecisionInput, db: DB, member: Member
    ):
        require_group(member, group_id, admin=True)
        status = "approved" if body.action == "approve" else "rejected"
        result = db.execute(
            update(Draft)
            .where(
                Draft.id == draft_id,
                Draft.group_id == group_id,
                Draft.status == "pending",
                Draft.version == body.expected_version,
            )
            .values(
                status=status,
                version=Draft.version + 1,
                decided_by=member.user_id,
                decided_at=utc_now(),
                human_output=body.model_dump(),
            )
            .execution_options(synchronize_session=False)
        )
        if result.rowcount != 1:
            db.rollback()
            current = db.scalar(
                select(Draft).where(Draft.id == draft_id, Draft.group_id == group_id)
            )
            if current is None:
                raise HTTPException(404, "Черновик не найден")
            published_id = db.scalar(
                select(Assignment.id).where(Assignment.draft_id == draft_id)
            )
            raise HTTPException(
                409,
                {
                    "message": "Черновик уже обработан или изменен",
                    "current_status": current.status,
                    "current_version": current.version,
                    "assignment_id": published_id,
                },
            )
        if body.action == "approve":
            lesson = db.scalar(
                select(Lesson)
                .where(Lesson.id == body.lesson_id, Lesson.group_id == group_id)
                .with_for_update()
            )
            if lesson is None:
                raise HTTPException(404, "Пара не найдена")
            if lesson.starts_at <= utc_now():
                raise HTTPException(422, "Выберите новый срок: эта пара уже началась")
        assignment_id = None
        if body.action == "approve":
            assignment = Assignment(
                group_id=group_id,
                lesson_id=body.lesson_id,
                draft_id=draft_id,
                text=body.text,
            )
            db.add(assignment)
            db.flush()
            assignment_id = assignment.id
        db.commit()
        return {"status": status, "assignment_id": assignment_id}

    @app.get("/groups/{group_id}/assignments")
    def assignments(group_id: str, db: DB, member: Member):
        require_group(member, group_id)
        completed = exists().where(
            Completion.assignment_id == Assignment.id,
            Completion.user_id == member.user_id,
            Completion.version == Assignment.version,
            Completion.completed.is_(True),
        )
        rows = db.scalars(
            select(Assignment)
            .where(Assignment.group_id == group_id, ~completed)
            .order_by(Assignment.id)
        )
        return [
            {key: getattr(row, key) for key in ("id", "lesson_id", "text", "version")}
            for row in rows
        ]

    @app.put("/groups/{group_id}/assignments/{assignment_id}/completion")
    def complete(
        group_id: str, assignment_id: str, body: CompletionInput, db: DB, member: Member
    ):
        require_group(member, group_id)
        # Lock the assignment so two devices cannot race an insert or revision change.
        assignment = db.scalar(
            select(Assignment)
            .where(Assignment.id == assignment_id, Assignment.group_id == group_id)
            .with_for_update()
        )
        if assignment is None:
            raise HTTPException(404, "ДЗ не найдено")
        if assignment.version != body.version:
            raise HTTPException(409, "ДЗ изменилось, обновите данные")
        # Database-native upsert also serializes writes under SQLite (no FOR UPDATE).
        if engine.dialect.name == "postgresql":
            from sqlalchemy.dialects.postgresql import insert
        else:
            from sqlalchemy.dialects.sqlite import insert
        values = {
            "assignment_id": assignment_id,
            "user_id": member.user_id,
            "version": body.version,
            "completed": body.completed,
            "updated_at": utc_now(),
        }
        db.execute(
            insert(Completion)
            .values(**values)
            .on_conflict_do_update(
                index_elements=["assignment_id", "user_id"], set_=values
            )
        )
        db.commit()
        return {"completed": body.completed, "version": body.version}

    return app
