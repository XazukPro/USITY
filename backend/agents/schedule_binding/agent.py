"""Validate semantic extraction and bind it to a published schedule.

Input is a JSON-compatible EventBundle slice. The caller supplies only the connected
Telegram topic and the group's published schedule. This module never writes data.
"""

import re
import unicodedata
from datetime import date, datetime, time, timedelta
from typing import Dict, List, Optional
from zoneinfo import ZoneInfo

from .provider import PROMPT_VERSION, SemanticModel


AGENT_ID = "schedule_binding"
_TOKEN = re.compile(r"[\w]+", re.UNICODE)


def _words(value: str) -> str:
    normalized = unicodedata.normalize("NFKC", value).casefold().replace("ё", "е")
    return " ".join(_TOKEN.findall(normalized))


def _mentioned(phrase: str, text: str) -> bool:
    needle = _words(phrase)
    return bool(needle and " " + needle + " " in " " + _words(text) + " ")


def _iso_date(value: str) -> date:
    if not isinstance(value, str):
        raise ValueError("date must be ISO text")
    return date.fromisoformat(value)


def _iso_time(value: str) -> time:
    if not isinstance(value, str):
        raise ValueError("time must be ISO text")
    result = time.fromisoformat(value)
    if result.tzinfo is not None:
        raise ValueError("lesson time must be local")
    return result


def _validate_bundle(bundle: dict) -> None:
    if not isinstance(bundle, dict):
        raise ValueError("bundle must be an object")
    if not isinstance(bundle.get("group_id"), str) or not bundle["group_id"]:
        raise ValueError("group ID is required")
    if bundle.get("chat_id") != bundle.get("connected_chat_id") or bundle.get("chat_id") is None:
        raise ValueError("bundle is outside the connected Telegram chat")
    if bundle.get("topic_id") != bundle.get("connected_topic_id") or bundle.get("topic_id") is None:
        raise ValueError("bundle is outside the connected Telegram topic")
    messages = bundle.get("messages")
    if not isinstance(messages, list) or not messages:
        raise ValueError("messages are required")
    ids = set()
    for message in messages:
        if not isinstance(message, dict) or message.get("chat_id") != bundle["chat_id"] or message.get("topic_id") != bundle["topic_id"]:
            raise ValueError("message is outside the connected Telegram chat/topic")
        if type(message.get("id")) is not int or message["id"] in ids:
            raise ValueError("message IDs must be unique integers")
        ids.add(message["id"])
        if not isinstance(message.get("text", ""), str) or not isinstance(message.get("ocr_text", ""), str):
            raise ValueError("message text and OCR text must be strings")
    semester = bundle.get("semester", {})
    if _iso_date(semester["start"]) > _iso_date(semester["end"]):
        raise ValueError("invalid semester dates")
    ZoneInfo(bundle["timezone"])
    subjects = bundle.get("subjects")
    if not isinstance(subjects, list) or not subjects:
        raise ValueError("subjects are required")
    subject_ids = set()
    for subject in subjects:
        if not isinstance(subject.get("id"), str) or not isinstance(subject.get("name"), str):
            raise ValueError("invalid subject")
        if subject["id"] in subject_ids:
            raise ValueError("duplicate subject ID")
        subject_ids.add(subject["id"])
        if not isinstance(subject.get("aliases", []), list) or not all(isinstance(a, str) for a in subject.get("aliases", [])):
            raise ValueError("invalid aliases")
    for pattern in bundle.get("patterns", []):
        if pattern["subject_id"] not in subject_ids or pattern["parity"] not in ("all", "odd", "even"):
            raise ValueError("invalid lesson pattern")
        if type(pattern["weekday"]) is not int or not 0 <= pattern["weekday"] <= 6:
            raise ValueError("invalid weekday")
        _iso_time(pattern["start_time"])
    pattern_ids = [p["id"] for p in bundle.get("patterns", [])]
    if len(pattern_ids) != len(set(pattern_ids)):
        raise ValueError("duplicate pattern ID")
    for override in bundle.get("overrides", []):
        if override["pattern_id"] not in pattern_ids or override["kind"] not in ("cancel", "move"):
            raise ValueError("invalid schedule override")
        _iso_date(override["original_date"])
        if override["kind"] == "move":
            _iso_date(override["new_date"])
            _iso_time(override["new_start_time"])
    for extra in bundle.get("extra_lessons", []):
        if extra["subject_id"] not in subject_ids:
            raise ValueError("invalid extra lesson")
        _iso_date(extra["date"])
        _iso_time(extra["start_time"])


def _read_model_output(raw: str, valid_ids: set) -> dict:
    import json

    data = json.loads(raw)
    if not isinstance(data, dict) or set(data) != {
        "subject_mention", "subgroup_mentions", "deadline_kind", "deadline_date", "source_message_ids"
    }:
        raise ValueError("invalid model response fields")
    if data["subject_mention"] is not None and not isinstance(data["subject_mention"], str):
        raise ValueError("invalid subject mention")
    groups = data["subgroup_mentions"]
    if groups is not None and (not isinstance(groups, list) or not all(isinstance(g, str) for g in groups)):
        raise ValueError("invalid subgroup mentions")
    if data["deadline_kind"] not in ("next_lesson", "date", "none"):
        raise ValueError("invalid deadline kind")
    if data["deadline_kind"] == "date":
        _iso_date(data["deadline_date"])
    elif data["deadline_date"] is not None:
        raise ValueError("unexpected deadline date")
    source_ids = data["source_message_ids"]
    if not isinstance(source_ids, list) or not source_ids or any(type(i) is not int or i not in valid_ids for i in source_ids):
        raise ValueError("invalid source message IDs")
    return data


def _subject_candidates(bundle: dict, mention: Optional[str], evidence: str) -> List[str]:
    if not mention or not _mentioned(mention, evidence):
        return []
    candidates = []
    for subject in bundle["subjects"]:
        names = [subject["name"]] + subject.get("aliases", [])
        if any(_words(mention) == _words(name) for name in names):
            candidates.append(subject["id"])
    return sorted(candidates)


def _subgroups(bundle: dict, mentions: Optional[List[str]], evidence: str, subject_id: str):
    if mentions is None:
        return None, []
    if not mentions:
        return [], []  # Explicitly all subgroups.
    catalog = next(s for s in bundle["subjects"] if s["id"] == subject_id).get("subgroups", [])
    found, unknown = set(), []
    for mention in mentions:
        if not _mentioned(mention, evidence):
            unknown.append(mention)
            continue
        matches = [g["id"] for g in catalog if _words(mention) in [_words(g["name"])] + [_words(a) for a in g.get("aliases", [])]]
        if len(matches) != 1:
            unknown.append(mention)
        else:
            found.add(matches[0])
    return sorted(found) if not unknown else None, unknown


def _occurrences(bundle: dict, from_date: date, through_date: date) -> List[dict]:
    semester = bundle["semester"]
    start, end = _iso_date(semester["start"]), _iso_date(semester["end"])
    overrides: Dict[tuple, dict] = {}
    for item in bundle.get("overrides", []):
        key = (item["pattern_id"], item["original_date"])
        if key in overrides:
            raise ValueError("duplicate schedule override")
        overrides[key] = item
    occurrences = []
    for pattern in bundle.get("patterns", []):
        day = start + timedelta(days=(pattern["weekday"] - start.weekday()) % 7)
        while day <= end:
            week = (day - start).days // 7 + 1
            if pattern["parity"] == "all" or (pattern["parity"] == "odd" and week % 2 == 1) or (pattern["parity"] == "even" and week % 2 == 0):
                override = overrides.get((pattern["id"], day.isoformat()))
                if not override or override["kind"] == "move":
                    actual_day = _iso_date(override["new_date"]) if override else day
                    actual_time = override["new_start_time"] if override else pattern["start_time"]
                    if from_date <= actual_day <= through_date:
                        occurrences.append({
                            "id": pattern["id"] + ":" + day.isoformat(),
                            "date": actual_day.isoformat(), "start_time": actual_time,
                            "subject_id": pattern["subject_id"],
                            "subgroup_ids": pattern.get("subgroup_ids", []),
                        })
            day += timedelta(days=7)
    for extra in bundle.get("extra_lessons", []):
        if from_date <= _iso_date(extra["date"]) <= through_date:
            occurrences.append({key: extra[key] for key in ("id", "date", "start_time", "subject_id", "subgroup_ids")})
    return sorted(occurrences, key=lambda item: (item["date"], item["start_time"], item["id"]))


def bind_schedule(bundle: dict, model: SemanticModel, now: datetime) -> dict:
    """Produce a review-only AgentProposal from an EventBundle slice."""
    _validate_bundle(bundle)
    if now.tzinfo is None:
        raise ValueError("now must include a timezone")
    local_now = now.astimezone(ZoneInfo(bundle["timezone"]))
    messages = bundle["messages"]
    context = {
        "messages": [{"id": m["id"], "text": m.get("text", ""), "ocr_text": m.get("ocr_text", "")} for m in messages],
        "subjects": [{"name": s["name"], "aliases": s.get("aliases", []), "subgroups": s.get("subgroups", [])} for s in bundle["subjects"]],
        "today": local_now.date().isoformat(),
    }
    result = {
        "agent_id": AGENT_ID, "group_id": bundle["group_id"],
        "proposal_type": "schedule_binding", "status": "needs_review",
        "source_message_ids": [m["id"] for m in messages], "subject_id": None,
        "candidate_subject_ids": [], "subgroup_ids": None, "lesson_id": None, "due_at": None,
        "candidate_lessons": [], "uncertainty": [], "prompt_version": PROMPT_VERSION,
        "model_version": model.model_name, "model_response": None,
        "source_context": [dict(m) for m in messages],
    }
    try:
        raw = model.extract(context)
        result["model_response"] = raw
        semantic = _read_model_output(raw, {m["id"] for m in messages})
    except (ValueError, KeyError, TypeError, TimeoutError, OSError, IndexError):
        result["uncertainty"].append("model_response_unavailable_or_invalid")
        return result

    result["source_message_ids"] = semantic["source_message_ids"]
    evidence = "\n".join(
        m.get("text", "") + "\n" + m.get("ocr_text", "")
        for m in messages if m["id"] in semantic["source_message_ids"]
    )
    candidates = _subject_candidates(bundle, semantic["subject_mention"], evidence)
    result["candidate_subject_ids"] = candidates
    if len(candidates) != 1:
        result["uncertainty"].append("subject_missing_or_ambiguous")
        return result
    subject_id = candidates[0]
    result["subject_id"] = subject_id
    subgroup_ids, unknown = _subgroups(bundle, semantic["subgroup_mentions"], evidence, subject_id)
    result["subgroup_ids"] = subgroup_ids
    if unknown:
        result["uncertainty"].append("subgroup_missing_or_ambiguous")
        return result
    if subgroup_ids is None and any(
        p["subject_id"] == subject_id and p.get("subgroup_ids") for p in bundle.get("patterns", [])
    ):
        result["uncertainty"].append("subgroup_unspecified")
        return result
    if semantic["deadline_kind"] == "none":
        result["uncertainty"].append("deadline_not_specified")
        return result
    if semantic["deadline_kind"] == "date":
        target_date = _iso_date(semantic["deadline_date"])
        if target_date < local_now.date():
            result["uncertainty"].append("past_deadline")
            return result
        from_date = target_date
        through_date = target_date
    else:
        from_date = local_now.date()
        through_date = _iso_date(bundle["semester"]["end"])
    lessons = _occurrences(bundle, from_date, through_date)
    lessons = [lesson for lesson in lessons if lesson["subject_id"] == subject_id
               and (subgroup_ids is None or not subgroup_ids or not lesson["subgroup_ids"]
                    or bool(set(subgroup_ids) & set(lesson["subgroup_ids"])))
               and datetime.combine(_iso_date(lesson["date"]), _iso_time(lesson["start_time"]), local_now.tzinfo) > local_now]
    if not lessons:
        result["uncertainty"].append("no_future_matching_lesson")
        return result
    first_slot = (lessons[0]["date"], lessons[0]["start_time"])
    result["candidate_lessons"] = [lesson for lesson in lessons if (lesson["date"], lesson["start_time"]) == first_slot][:10]
    if len(result["candidate_lessons"]) == 1:
        result["lesson_id"] = lessons[0]["id"]
        result["due_at"] = datetime.combine(
            _iso_date(lessons[0]["date"]), _iso_time(lessons[0]["start_time"]), local_now.tzinfo
        ).isoformat()
        result["status"] = "proposed"
    else:
        result["uncertainty"].append("multiple_matching_lessons")
    return result
