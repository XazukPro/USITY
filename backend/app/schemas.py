from typing import Annotated, Literal

from pydantic import (
    AwareDatetime,
    BaseModel,
    ConfigDict,
    Field,
    StringConstraints,
    model_validator,
)

Text = Annotated[
    str, StringConstraints(strip_whitespace=True, min_length=1, max_length=20000)
]
Identifier = Annotated[str, StringConstraints(min_length=1, max_length=100)]


class InputModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class LessonInput(InputModel):
    subject: Annotated[
        str, StringConstraints(strip_whitespace=True, min_length=1, max_length=200)
    ]
    starts_at: AwareDatetime
    ends_at: AwareDatetime
    teacher: str = Field(default="", max_length=200)
    location: str = Field(default="", max_length=500)

    @model_validator(mode="after")
    def valid_times(self):
        if self.ends_at <= self.starts_at:
            raise ValueError("Окончание должно быть после начала")
        return self


class DecisionInput(InputModel):
    action: Literal["approve", "reject"]
    expected_version: int = Field(ge=1, strict=True)
    lesson_id: Identifier | None = None
    text: Text | None = None
    subgroups: list[Annotated[int, Field(strict=True, ge=1, le=100)]] = Field(
        default_factory=list, max_length=100
    )

    @model_validator(mode="after")
    def approval_requires_lesson(self):
        if self.action == "approve" and (self.lesson_id is None or self.text is None):
            raise ValueError("Для публикации выберите пару и заполните текст")
        if self.action == "reject" and (
            self.lesson_id is not None or self.text is not None or self.subgroups
        ):
            raise ValueError("Отклонение не содержит публикуемых полей")
        return self


class CompletionInput(InputModel):
    version: int = Field(ge=1, strict=True)
    completed: bool = Field(strict=True)
