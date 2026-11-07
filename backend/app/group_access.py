from datetime import UTC, date, datetime, time, timedelta
from typing import Annotated, Literal
from zoneinfo import ZoneInfo

from fastapi import HTTPException
from pydantic import Field, StringConstraints, model_validator
from sqlalchemy import exists, select, true

from app.models import (
    Assignment,
    AssignmentSubgroup,
    GroupDetails,
    Lesson,
    LessonDetails,
    SubjectChoice,
)
from app.schemas import InputModel

Name = Annotated[
    str, StringConstraints(strip_whitespace=True, min_length=1, max_length=200)
]
Kind = Literal["lecture", "seminar", "lab"]


class SubjectSpec(InputModel):
    id: int = Field(ge=0)
    name: Name
    groups: int = Field(ge=0, le=100)
    kinds: list[Kind] = Field(min_length=1, max_length=3)


class SlotSpec(InputModel):
    subject_id: int
    weekday: int = Field(ge=1, le=7)
    start: int = Field(ge=0, lt=1440)
    end: int = Field(gt=0, le=1440)
    teacher: Name
    room: Name
    kind: Kind
    subgroup: int | None = Field(default=None, ge=1)
    pattern: Literal["all", "even", "odd"] = "all"


class SemesterInput(InputModel):
    name: Annotated[
        str, StringConstraints(strip_whitespace=True, min_length=1, max_length=100)
    ]
    start: date
    end: date
    subjects: list[SubjectSpec] = Field(min_length=1, max_length=80)
    slots: list[SlotSpec] = Field(min_length=1, max_length=150)
    alternating: bool

    @model_validator(mode="after")
    def validate_rules(self):
        if not 0 <= (self.end - self.start).days <= 366:
            raise ValueError("Семестр должен укладываться в год")
        subjects = {s.id: s for s in self.subjects}
        if len(subjects) != len(self.subjects) or len(
            {s.name.casefold() for s in self.subjects}
        ) != len(self.subjects):
            raise ValueError("Предметы должны быть уникальными")
        for slot in self.slots:
            subject = subjects.get(slot.subject_id)
            if (
                subject is None
                or slot.kind not in subject.kinds
                or slot.start >= slot.end
                or (slot.subgroup or 0) > subject.groups
                or not next(self.dates(slot), None)
            ):
                raise ValueError("Проверьте параметры занятия")
        return self

    def dates(self, slot):
        monday = self.start - timedelta(days=self.start.weekday())
        day = self.start + timedelta(days=(slot.weekday - self.start.isoweekday()) % 7)
        while day <= self.end:
            week = 1 + (day - monday).days // 7
            if (
                not self.alternating
                or slot.pattern == "all"
                or (slot.pattern == "even") == (week % 2 == 0)
            ):
                yield day
            day += timedelta(days=7)

    def publish(self, db, group_id):
        subjects = {s.id: s for s in self.subjects}
        for slot in self.slots:
            for day in self.dates(slot):
                midnight = datetime.combine(day, time.min, ZoneInfo("Europe/Moscow"))
                lesson = Lesson(
                    group_id=group_id,
                    subject=subjects[slot.subject_id].name,
                    teacher=slot.teacher,
                    location=slot.room,
                    starts_at=(midnight + timedelta(minutes=slot.start)).astimezone(
                        UTC
                    ),
                    ends_at=(midnight + timedelta(minutes=slot.end)).astimezone(UTC),
                )
                db.add(lesson)
                db.flush()
                db.add(
                    LessonDetails(
                        lesson_id=lesson.id, kind=slot.kind, subgroup=slot.subgroup
                    )
                )


def allowed_lessons(member):
    query = (
        select(Lesson.id)
        .outerjoin(LessonDetails)
        .where(Lesson.group_id == member.group_id)
    )
    if member.role == "student":
        matching = exists().where(
            SubjectChoice.user_id == member.user_id,
            SubjectChoice.subject == Lesson.subject,
            SubjectChoice.subgroup == LessonDetails.subgroup,
        )
        query = query.where(LessonDetails.subgroup.is_(None) | matching)
    return query


def validated_choices(catalog, choices):
    limits = {s["name"]: s["groups"] for s in catalog["subjects"]}
    if any(
        name not in limits or not 1 <= group <= limits[name]
        for name, group in choices.items()
    ):
        raise HTTPException(422, "Неизвестная подгруппа")
    return choices


def subject_group_counts(db, group_id):
    details = db.get(GroupDetails, group_id)
    return (
        {s["name"]: s["groups"] for s in details.semester["subjects"]}
        if details
        else {}
    )


def assignment_audience(db, lesson, selected):
    if not selected:
        return []
    count = subject_group_counts(db, lesson.group_id).get(lesson.subject, 0)
    details = db.get(LessonDetails, lesson.id)
    if max(selected) > count or (
        details and details.subgroup and set(selected) != {details.subgroup}
    ):
        raise HTTPException(422, "Проверьте подгруппы для выбранной пары")
    return sorted(set(selected))


def audience_visible_to(member):
    if member.role != "student":
        return true()
    restricted = exists().where(AssignmentSubgroup.assignment_id == Assignment.id)
    included = (
        select(AssignmentSubgroup.assignment_id)
        .join(SubjectChoice, SubjectChoice.subgroup == AssignmentSubgroup.subgroup)
        .join(Lesson, Lesson.subject == SubjectChoice.subject)
        .where(
            AssignmentSubgroup.assignment_id == Assignment.id,
            Lesson.id == Assignment.lesson_id,
            SubjectChoice.user_id == member.user_id,
        )
        .exists()
    )
    return ~restricted | included
