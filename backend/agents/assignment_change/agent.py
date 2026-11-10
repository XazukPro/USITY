"""Detect edits and cancellations of published homework in a Telegram topic.

Input is an EventBundle (contract v0.1) with the group's active assignments in
`context.active_assignments`. The model only reads the messages; this module
validates its answer and returns review-only proposals. Nothing is written.
"""

import json
import re
import unicodedata
from datetime import date, datetime

from .provider import PROMPT_VERSION, ChangeModel

SCHEMA_VERSION = "0.1"
AGENT_ID = "assignment_change"
_KINDS = {"update": "assignment_update", "cancel": "assignment_cancel"}
_CHANGE_FIELDS = {
    "kind", "assignment_id", "candidate_assignment_ids", "new_text", "new_due_kind",
    "new_due_date", "evidence", "source_message_ids", "uncertain", "reason",
}
_TOKEN = re.compile(r"\w+", re.UNICODE)


class AgentRunError(RuntimeError):
    """The model call failed or its answer is unusable; never means "no changes"."""

    def __init__(self, message: str, model_response: str | None = None):
        super().__init__(message)
        self.model_response = model_response


def _words(value: str) -> str:
    normalized = unicodedata.normalize("NFKC", value).casefold().replace("ё", "е")
    return " ".join(_TOKEN.findall(normalized))


def _is_quoted(evidence: str, text: str) -> bool:
    needle = _words(evidence)
    return bool(needle) and " " + needle + " " in " " + _words(text) + " "


def _ocr_text(message: dict) -> str:
    return "\n".join(
        a.get("ocr_text") or "" for a in message.get("attachments", []) if a.get("kind") == "photo"
    )


def _non_empty_str(value) -> bool:
    return isinstance(value, str) and bool(value.strip())


def _validate_bundle(bundle: dict) -> None:
    if not isinstance(bundle, dict):
        raise ValueError("bundle must be an object")
    for key in ("event_id", "group_id"):
        if not _non_empty_str(bundle.get(key)):
            raise ValueError(key + " is required")
    if bundle.get("schema_version") != SCHEMA_VERSION:
        raise ValueError("unsupported schema_version")
    messages = bundle.get("messages")
    if not isinstance(messages, list) or not messages:
        raise ValueError("messages are required")
    ids = set()
    for message in messages:
        if not isinstance(message, dict) or not _non_empty_str(message.get("id")) or message["id"] in ids:
            raise ValueError("message IDs must be unique non-empty strings")
        ids.add(message["id"])
        if not isinstance(message.get("text", ""), str) or not isinstance(message.get("attachments", []), list):
            raise ValueError("invalid message text or attachments")
    context = bundle.get("context")
    if not isinstance(context, dict):
        raise ValueError("context is required")
    assignment_ids = set()
    for assignment in context.get("active_assignments", []):
        if not isinstance(assignment, dict) or not _non_empty_str(assignment.get("id")):
            raise ValueError("invalid active assignment")
        if assignment["id"] in assignment_ids:
            raise ValueError("duplicate assignment ID")
        assignment_ids.add(assignment["id"])
        if not isinstance(assignment.get("text"), str):
            raise ValueError("assignment text is required")
    for subject in context.get("subjects", []):
        if not isinstance(subject, dict) or not _non_empty_str(subject.get("id")) or not isinstance(subject.get("name"), str):
            raise ValueError("invalid subject")


def _model_context(bundle: dict, today: date) -> dict:
    """Only what the agent needs: no chat IDs, personal data or other groups."""
    context = bundle["context"]
    subject_names = {s["id"]: s["name"] for s in context.get("subjects", [])}
    return {
        "today": today.isoformat(),
        "messages": [
            {"id": m["id"], "sent_at": m.get("sent_at"), "text": m.get("text", ""), "ocr_text": _ocr_text(m)}
            for m in bundle["messages"]
        ],
        "subjects": [
            {"id": s["id"], "name": s["name"], "aliases": s.get("aliases", [])}
            for s in context.get("subjects", [])
        ],
        "active_assignments": [
            {
                "id": a["id"], "subject": subject_names.get(a.get("subject_id")),
                "text": a["text"], "due_at": a.get("due_at"),
            }
            for a in context.get("active_assignments", [])
        ],
    }


def _parse_change(item, message_ids: set) -> dict:
    """Reject answers that break the response format or cite unknown messages."""
    if not isinstance(item, dict) or set(item) != _CHANGE_FIELDS:
        raise ValueError("invalid change fields")
    if item["kind"] not in _KINDS:
        raise ValueError("invalid change kind")
    if item["assignment_id"] is not None and not isinstance(item["assignment_id"], str):
        raise ValueError("invalid assignment ID")
    candidates = item["candidate_assignment_ids"]
    if not isinstance(candidates, list) or not all(isinstance(c, str) for c in candidates):
        raise ValueError("invalid candidate assignment IDs")
    if item["new_text"] is not None and not isinstance(item["new_text"], str):
        raise ValueError("invalid new text")
    if item["new_due_kind"] not in (None, "date", "next_lesson"):
        raise ValueError("invalid new due kind")
    if item["new_due_kind"] == "date":
        date.fromisoformat(item["new_due_date"])
    elif item["new_due_date"] is not None:
        raise ValueError("new due date without due kind 'date'")
    sources = item["source_message_ids"]
    if (not isinstance(sources, list) or not sources or len(set(sources)) != len(sources)
            or any(s not in message_ids for s in sources)):
        raise ValueError("invalid source message IDs")
    if not isinstance(item["evidence"], str) or not _non_empty_str(item["reason"]):
        raise ValueError("evidence and reason are required")
    if not isinstance(item["uncertain"], bool):
        raise ValueError("invalid uncertain flag")
    return item


def _read_model_output(raw: str, message_ids: set) -> list[dict]:
    try:
        data = json.loads(raw)
    except (TypeError, ValueError):
        raise ValueError("model response is not JSON") from None
    if not isinstance(data, dict) or set(data) != {"changes"} or not isinstance(data["changes"], list):
        raise ValueError("model response must be {\"changes\": [...]}")
    return [_parse_change(item, message_ids) for item in data["changes"]]


def _proposal(change: dict, bundle: dict, today: date) -> dict:
    """Turn one model change into a proposal; doubts become review flags, not guesses."""
    known = {a["id"] for a in bundle["context"].get("active_assignments", [])}
    flags: list[str] = []
    if change["uncertain"]:
        flags.append("model_uncertain")

    candidates = []
    for candidate in change["candidate_assignment_ids"]:
        if candidate not in known:
            flags.append("unknown_candidate_assignment")
        elif candidate not in candidates:
            candidates.append(candidate)
    target = change["assignment_id"]
    if target is not None and target not in known:
        flags.append("unknown_assignment")
        target = None
    if target is not None and target not in candidates:
        candidates.insert(0, target)
    if target is None:
        flags.append("target_ambiguous" if len(candidates) > 1 else "target_not_found")

    cited = "\n".join(
        m.get("text", "") + "\n" + _ocr_text(m)
        for m in bundle["messages"] if m["id"] in change["source_message_ids"]
    )
    if not _is_quoted(change["evidence"], cited):
        flags.append("evidence_not_in_source")

    new_text = change["new_text"].strip() if change["new_text"] else None
    new_due = None
    if change["new_due_kind"] == "date":
        new_due = {"kind": "date", "date": change["new_due_date"]}
        if date.fromisoformat(change["new_due_date"]) < today:
            flags.append("past_due_date")
    elif change["new_due_kind"] == "next_lesson":
        new_due = {"kind": "next_lesson"}

    if change["kind"] == "cancel" and (new_text or new_due):
        flags.append("cancel_with_new_values")
        new_text, new_due = None, None
    if change["kind"] == "update" and not new_text and not new_due:
        flags.append("change_unspecified")

    return {
        "kind": _KINDS[change["kind"]],
        "source_message_ids": list(change["source_message_ids"]),
        "uncertain": bool(flags),
        "reason": change["reason"].strip(),
        "fields": {
            "assignment_id": target,
            "candidate_assignment_ids": candidates,
            "new_text": new_text,
            "new_due": new_due,
            "evidence": change["evidence"],
            "review_flags": flags,
        },
    }


def detect_changes(bundle: dict, model: ChangeModel, now: datetime) -> dict:
    """Return an AgentRunResult for one EventBundle. Raises AgentRunError on model failure."""
    _validate_bundle(bundle)
    if now.tzinfo is None:
        raise ValueError("now must include a timezone")
    today = now.date()
    try:
        raw = model.extract(_model_context(bundle, today))
    except (OSError, TimeoutError, ValueError) as exc:
        raise AgentRunError("model call failed: " + type(exc).__name__) from None
    try:
        changes = _read_model_output(raw, {m["id"] for m in bundle["messages"]})
    except (ValueError, TypeError) as exc:
        raise AgentRunError("invalid model response: " + str(exc), raw) from None
    return {
        "schema_version": SCHEMA_VERSION,
        "event_id": bundle["event_id"],
        "agent_id": AGENT_ID,
        "model_version": model.model_name,
        "prompt_version": PROMPT_VERSION,
        "proposals": [_proposal(change, bundle, today) for change in changes],
        # Stored by the caller separately from the reviewed result and admin decision.
        "model_response": raw,
    }
