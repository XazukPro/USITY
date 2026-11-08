import json
from datetime import UTC, date, datetime, timedelta
from hashlib import sha256
from typing import Annotated
from uuid import UUID

from fastapi import HTTPException
from pydantic import AwareDatetime, Field, field_validator, model_validator
from sqlalchemy import (
    CheckConstraint,
    ForeignKey,
    Index,
    String,
    Text,
    and_,
    or_,
    select,
)
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base, UTCDateTime
from app.models import Account, utc_now
from app.schemas import InputModel
from app.schemas import Text as TaskTitle

ARCHIVE_WINDOW = timedelta(days=3)


class PersonalTask(Base):
    __tablename__ = "personal_tasks"
    __table_args__ = (
        CheckConstraint("version >= 1"),
        CheckConstraint("duration BETWEEN 1 AND 1440"),
        CheckConstraint("start IS NULL OR (start >= 0 AND start + duration <= 1440)"),
        Index("ix_personal_tasks_user_completed", "user_id", "completed_at"),
    )
    user_id: Mapped[str] = mapped_column(
        ForeignKey("accounts.id", ondelete="CASCADE"), primary_key=True
    )
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    title: Mapped[str] = mapped_column(Text)
    day: Mapped[date]
    start: Mapped[int | None]
    duration: Mapped[int]
    remind: Mapped[bool]
    completed_at: Mapped[datetime | None] = mapped_column(UTCDateTime())
    version: Mapped[int]


class TaskReceipt(Base):
    __tablename__ = "personal_task_receipts"
    user_id: Mapped[str] = mapped_column(
        ForeignKey("accounts.id", ondelete="CASCADE"), primary_key=True
    )
    mutation_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    result_hash: Mapped[str] = mapped_column(String(64))


class TaskFields(InputModel):
    title: TaskTitle = Field(pattern=r"^[^\x00]*$")
    day: date
    start: Annotated[int, Field(strict=True, ge=0, lt=1440)] | None
    duration: int = Field(strict=True, ge=1, le=1440)
    remind: bool = Field(strict=True)
    completed_at: AwareDatetime | None


class TaskMutation(TaskFields):
    expected_version: int = Field(strict=True, ge=0)
    mutation_id: UUID

    @field_validator("day", mode="before")
    @classmethod
    def calendar_day(cls, value):
        if not isinstance(value, str) or date.fromisoformat(value).isoformat() != value:
            raise ValueError("Нужна дата в формате YYYY-MM-DD")
        return value

    @field_validator("completed_at", mode="before")
    @classmethod
    def completion_time(cls, value):
        if value is None:
            return None
        if not isinstance(value, str):
            raise ValueError("Нужна дата и время с часовым поясом")
        return datetime.fromisoformat(value)

    @field_validator("completed_at")
    @classmethod
    def normalize_utc(cls, value):
        if value is None:
            return None
        try:
            return value.astimezone(UTC)
        except OverflowError as exc:
            raise ValueError("Время за пределами допустимого диапазона UTC") from exc

    @model_validator(mode="after")
    def fits_day(self):
        if self.start is not None and self.start + self.duration > 1440:
            raise ValueError("Задача должна заканчиваться в пределах выбранного дня")
        return self


class TaskResult(TaskFields):
    id: str
    version: int


def install_personal_tasks(app, DB, Identity):
    @app.get("/account/tasks", response_model=list[TaskResult])
    def list_tasks(db: DB, session: Identity):
        now = utc_now()
        return db.scalars(
            select(PersonalTask)
            .where(
                PersonalTask.user_id == session.user_id,
                or_(
                    PersonalTask.completed_at.is_(None),
                    and_(
                        PersonalTask.completed_at > now - ARCHIVE_WINDOW,
                        PersonalTask.completed_at <= now,
                    ),
                ),
            )
            .order_by(
                PersonalTask.day, PersonalTask.start.nulls_last(), PersonalTask.id
            )
        ).all()

    @app.put("/account/tasks/{id}", response_model=TaskResult)
    def put_task(id: UUID, body: TaskMutation, db: DB, session: Identity):
        uid = session.user_id
        # Even the first PUT has an account row to lock. SQLite uses BEGIN IMMEDIATE.
        db.scalar(select(Account.id).where(Account.id == uid).with_for_update())
        fields = body.model_dump(exclude={"expected_version", "mutation_id"})
        result = TaskResult(id=str(id), version=body.expected_version + 1, **fields)
        # A full replacement request determines its original acknowledgement.
        # Keep its digest so a retry after later edits needs no historical task text.
        encoded = json.dumps(result.model_dump(mode="json"), sort_keys=True)
        digest = sha256(encoded.encode()).hexdigest()
        mutation_id = str(body.mutation_id)
        receipt = db.get(TaskReceipt, (uid, mutation_id))
        if receipt and receipt.result_hash == digest:
            return result

        current = db.get(PersonalTask, (uid, str(id)))
        if (
            current
            and current.completed_at is not None
            and current.completed_at <= utc_now() - ARCHIVE_WINDOW
        ):
            raise HTTPException(409, {"current": None})
        if receipt or body.expected_version != (current.version if current else 0):
            snapshot = (
                TaskResult.model_validate(current, from_attributes=True).model_dump(
                    mode="json"
                )
                if current
                else None
            )
            raise HTTPException(409, {"current": snapshot})

        db.merge(PersonalTask(user_id=uid, **result.model_dump()))
        db.add(TaskReceipt(user_id=uid, mutation_id=mutation_id, result_hash=digest))
        db.commit()
        return result
