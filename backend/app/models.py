from datetime import UTC, datetime
from uuid import uuid4

from sqlalchemy import (
    JSON,
    Boolean,
    CheckConstraint,
    ForeignKey,
    Integer,
    String,
    Text,
    UniqueConstraint,
)
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base, UTCDateTime


def new_id():
    return str(uuid4())


def utc_now():
    return datetime.now(UTC)


class StudyGroup(Base):
    __tablename__ = "study_groups"
    id: Mapped[str] = mapped_column(String(100), primary_key=True, default=new_id)


class Membership(Base):
    __tablename__ = "memberships"
    __table_args__ = (CheckConstraint("role IN ('owner','admin','student')"),)
    user_id: Mapped[str] = mapped_column(String(100), primary_key=True)
    group_id: Mapped[str] = mapped_column(ForeignKey("study_groups.id"), index=True)
    role: Mapped[str] = mapped_column(String(20))


class SessionToken(Base):
    __tablename__ = "session_tokens"
    token_hash: Mapped[str] = mapped_column(String(64), primary_key=True)
    user_id: Mapped[str] = mapped_column(ForeignKey("memberships.user_id"))
    expires_at: Mapped[datetime] = mapped_column(UTCDateTime())


class Lesson(Base):
    __tablename__ = "lessons"
    __table_args__ = (CheckConstraint("ends_at > starts_at"),)
    id: Mapped[str] = mapped_column(String(100), primary_key=True, default=new_id)
    group_id: Mapped[str] = mapped_column(ForeignKey("study_groups.id"), index=True)
    subject: Mapped[str] = mapped_column(String(200))
    starts_at: Mapped[datetime] = mapped_column(UTCDateTime())
    ends_at: Mapped[datetime] = mapped_column(UTCDateTime())
    teacher: Mapped[str] = mapped_column(String(200), default="")
    location: Mapped[str] = mapped_column(String(500), default="")


class TelegramIntegration(Base):
    __tablename__ = "telegram_integrations"
    __table_args__ = (UniqueConstraint("chat_id", "topic_id"),)
    group_id: Mapped[str] = mapped_column(
        ForeignKey("study_groups.id"), primary_key=True
    )
    chat_id: Mapped[str] = mapped_column(String(100))
    topic_id: Mapped[str] = mapped_column(String(100))


class IngestedEvent(Base):
    __tablename__ = "ingested_events"
    group_id: Mapped[str] = mapped_column(
        ForeignKey("study_groups.id"), primary_key=True
    )
    event_id: Mapped[str] = mapped_column(String(200), primary_key=True)
    payload_hash: Mapped[str] = mapped_column(String(64))
    draft_id: Mapped[str | None] = mapped_column(
        ForeignKey("review_drafts.id"), nullable=True
    )


class Draft(Base):
    __tablename__ = "review_drafts"
    __table_args__ = (
        UniqueConstraint("group_id", "event_id"),
        CheckConstraint("status IN ('pending','approved','rejected')"),
        CheckConstraint("version >= 1"),
    )
    id: Mapped[str] = mapped_column(String(100), primary_key=True, default=new_id)
    group_id: Mapped[str] = mapped_column(ForeignKey("study_groups.id"), index=True)
    event_id: Mapped[str] = mapped_column(String(200))
    text: Mapped[str] = mapped_column(Text)
    source_context: Mapped[dict] = mapped_column(JSON)
    model_output: Mapped[dict] = mapped_column(JSON)
    raw_output: Mapped[str | None] = mapped_column(Text, nullable=True)
    model_version: Mapped[str] = mapped_column(String(200))
    prompt_version: Mapped[str] = mapped_column(String(100))
    proposal_set: Mapped[dict | None] = mapped_column(JSON, nullable=True)
    status: Mapped[str] = mapped_column(String(20), default="pending")
    version: Mapped[int] = mapped_column(Integer, default=1)
    created_at: Mapped[datetime] = mapped_column(UTCDateTime(), default=utc_now)
    human_output: Mapped[dict | None] = mapped_column(JSON, nullable=True)
    decided_by: Mapped[str | None] = mapped_column(String(100), nullable=True)
    decided_at: Mapped[datetime | None] = mapped_column(UTCDateTime(), nullable=True)


class Assignment(Base):
    __tablename__ = "assignments"
    __table_args__ = (CheckConstraint("version >= 1"),)
    id: Mapped[str] = mapped_column(String(100), primary_key=True, default=new_id)
    group_id: Mapped[str] = mapped_column(ForeignKey("study_groups.id"), index=True)
    lesson_id: Mapped[str] = mapped_column(ForeignKey("lessons.id"))
    draft_id: Mapped[str] = mapped_column(ForeignKey("review_drafts.id"), unique=True)
    text: Mapped[str] = mapped_column(Text)
    version: Mapped[int] = mapped_column(Integer, default=1)


class Completion(Base):
    __tablename__ = "assignment_completions"
    assignment_id: Mapped[str] = mapped_column(
        ForeignKey("assignments.id"), primary_key=True
    )
    user_id: Mapped[str] = mapped_column(
        ForeignKey("memberships.user_id"), primary_key=True
    )
    version: Mapped[int] = mapped_column(Integer)
    completed: Mapped[bool] = mapped_column(Boolean)
    updated_at: Mapped[datetime] = mapped_column(UTCDateTime(), default=utc_now)
