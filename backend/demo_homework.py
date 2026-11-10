"""Standalone contract demo; the provider response is a fixture, not live AI."""

import json

from app.agents.homework import EventBundle, Message, detect_homework


class FixtureProvider:
    def complete(self, system_prompt: str, event_json: str) -> str:
        return json.dumps(
            {
                "kind": "new_homework",
                "text": "Решить номера 4 и 5",
                "source_ids": [101, 102],
                "uncertain": False,
            },
            ensure_ascii=False,
        )


if __name__ == "__main__":
    bundle = EventBundle(
        group_id="study-group-demo",
        topic_id="math-topic-demo",
        messages=(
            Message(101, "По математике на понедельник:", "2026-11-02T09:00:00+03:00"),
            Message(102, "решить номера 4 и 5", "2026-11-02T09:01:00+03:00"),
        ),
    )
    proposal = detect_homework(bundle, FixtureProvider())
    print(json.dumps(proposal.__dict__, ensure_ascii=False, indent=2))
