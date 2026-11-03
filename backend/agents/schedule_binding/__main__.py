"""Run the schedule agent independently: JSON EventBundle on stdin."""

import json
import os
import sys
from datetime import datetime

from .agent import bind_schedule
from .provider import GigaChatModel


def main() -> None:
    credentials = os.environ.get("GIGACHAT_CREDENTIALS", "")
    model_name = os.environ.get("GIGACHAT_MODEL", "GigaChat-2")
    if not credentials:
        raise SystemExit("Set GIGACHAT_CREDENTIALS in the environment")
    bundle = json.load(sys.stdin)
    model = GigaChatModel(credentials, model_name, os.environ.get("GIGACHAT_CA_BUNDLE_FILE"))
    proposal = bind_schedule(bundle, model, datetime.now().astimezone())
    json.dump(proposal, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
