"""Небольшой набор синтетических примеров для независимой оценки модели."""

import json
import os
from copy import deepcopy
from datetime import datetime
from zoneinfo import ZoneInfo

from .agent import bind_schedule
from .provider import PROMPT_VERSION, GigaChatModel

NOW = datetime(2026, 9, 7, 9, 0, tzinfo=ZoneInfo("Europe/Moscow"))


def cases():
    base = {
        "group_id": "group-a", "chat_id": -100123, "connected_chat_id": -100123,
        "topic_id": 11, "connected_topic_id": 11, "timezone": "Europe/Moscow",
        "semester": {"start": "2026-09-01", "end": "2026-12-20"},
        "subjects": [
            {"id": "math", "name": "Математический анализ", "aliases": ["матан"], "subgroups": []},
            {"id": "physics", "name": "Физика", "aliases": ["физика"], "subgroups": []},
        ],
        "patterns": [{"id": "math-mon", "subject_id": "math", "weekday": 0, "start_time": "11:00", "parity": "all", "subgroup_ids": []}],
        "overrides": [], "extra_lessons": [],
    }

    def example(name, text, subject, lesson, mutate=None):
        item = deepcopy(base)
        item["messages"] = [{"id": 1, "chat_id": -100123, "topic_id": 11, "text": text, "ocr_text": ""}]
        if mutate:
            mutate(item)
        return name, item, subject, lesson

    def even(item):
        item["patterns"][0]["parity"] = "even"

    def cancel(item):
        item["overrides"] = [{"pattern_id": "math-mon", "original_date": "2026-09-07", "kind": "cancel"}]

    def ambiguous(item):
        item["subjects"][0]["aliases"].append("анге")
        item["subjects"][1]["aliases"].append("анге")

    return [
        example("alias_next", "По матан задачу 4 к следующей паре", "math", "math-mon:2026-09-07"),
        example("even_week", "Матан: упражнение к следующей паре", "math", "math-mon:2026-09-14", even),
        example("cancellation", "Матан к следующей паре, пожалуйста", "math", "math-mon:2026-09-14", cancel),
        example("ambiguous_alias", "По анге задание к следующей паре", None, None, ambiguous),
        example("unknown_subject", "По химии задача к следующей паре", None, None),
        example("past_date", "Матан сдаем к 5 сентября", "math", None),
    ]


def main():
    credentials = os.environ.get("GIGACHAT_CREDENTIALS", "")
    model_name = os.environ.get("GIGACHAT_MODEL", "GigaChat-2")
    if not credentials:
        raise SystemExit("Set GIGACHAT_CREDENTIALS in the environment")
    model = GigaChatModel(credentials, model_name, os.environ.get("GIGACHAT_CA_BUNDLE_FILE"))
    rows = []
    for name, item, expected_subject, expected_lesson in cases():
        proposal = bind_schedule(item, model, NOW)
        rows.append({
            "case": name,
            "subject_correct": proposal["subject_id"] == expected_subject,
            "lesson_correct": proposal["lesson_id"] == expected_lesson,
            "review_correct": (proposal["status"] == "needs_review") == (expected_lesson is None),
            "status": proposal["status"],
            "uncertainty": proposal["uncertainty"],
        })
    summary = {
        "model": model_name, "prompt_version": PROMPT_VERSION,
        "cases": len(rows),
        "subject_correct": sum(row["subject_correct"] for row in rows),
        "lesson_correct": sum(row["lesson_correct"] for row in rows),
        "review_correct": sum(row["review_correct"] for row in rows),
        "results": rows,
    }
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
