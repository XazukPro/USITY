"""Run the schedule agent independently: JSON EventBundle on stdin."""

import json
import os
import sys
from datetime import datetime

from .agent import bind_schedule
from .provider import OpenAIChatModel


def main() -> None:
    api_key = os.environ.get("OPENAI_API_KEY", "")
    model_name = os.environ.get("OPENAI_MODEL", "")
    if not api_key or not model_name:
        raise SystemExit("Set OPENAI_API_KEY and OPENAI_MODEL in the environment")
    bundle = json.load(sys.stdin)
    proposal = bind_schedule(bundle, OpenAIChatModel(api_key, model_name), datetime.now().astimezone())
    json.dump(proposal, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
