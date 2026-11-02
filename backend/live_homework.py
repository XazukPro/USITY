"""Run Anton's agent on synthetic messages with a configured LLM endpoint."""

import json
import os
from dataclasses import asdict

from app.agents.homework import EventBundle, Message, detect_homework
from app.agents.providers import ChatCompletionsProvider


def main() -> None:
    names = ("USITY_LLM_ENDPOINT", "USITY_LLM_MODEL", "USITY_LLM_API_KEY")
    missing = [name for name in names if not os.environ.get(name)]
    if missing:
        raise SystemExit("Set environment variables: " + ", ".join(missing))
    provider = ChatCompletionsProvider(
        endpoint=os.environ["USITY_LLM_ENDPOINT"],
        model=os.environ["USITY_LLM_MODEL"],
        api_key=os.environ["USITY_LLM_API_KEY"],
    )
    bundle = EventBundle(
        group_id="study-group-demo",
        topic_id="math-topic-demo",
        messages=(
            Message(101, "По математике к понедельнику:", "2026-11-02T09:00:00+03:00"),
            Message(102, "решить номера 4 и 5", "2026-11-02T09:01:00+03:00"),
        ),
    )
    result = detect_homework(bundle, provider)
    print(json.dumps(asdict(result) if result else None, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
