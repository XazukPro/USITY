"""Run the assignment change agent independently: JSON EventBundle on stdin."""

import json
import os
import sys
from datetime import datetime

from .agent import AgentRunError, detect_changes
from .provider import CHAT_URL, GigaChatModel


def model_from_env() -> GigaChatModel:
    credentials = os.environ.get("GIGACHAT_CREDENTIALS", "")
    if not credentials:
        raise SystemExit("Set GIGACHAT_CREDENTIALS in the environment")
    return GigaChatModel(
        credentials,
        os.environ.get("GIGACHAT_MODEL", "GigaChat-2"),
        os.environ.get("GIGACHAT_CA_BUNDLE_FILE") or None,
        chat_url=os.environ.get("GIGACHAT_CHAT_URL") or CHAT_URL,
    )


def main() -> None:
    model = model_from_env()
    bundle = json.load(sys.stdin)
    try:
        result = detect_changes(bundle, model, datetime.now().astimezone())
    except AgentRunError as exc:
        json.dump({"error": str(exc), "model_response": exc.model_response}, sys.stderr, ensure_ascii=False)
        sys.stderr.write("\n")
        raise SystemExit(1)
    json.dump(result, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
