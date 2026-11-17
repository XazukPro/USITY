"""Structured outputs for the five independent agent contracts."""

from app.agents.providers import GigaChatProvider


def _object(properties):
    return {"type": "object", "properties": properties,
            "required": list(properties), "additionalProperties": False}


def _array(items):
    return {"type": "array", "items": items}


_string = {"type": "string"}
_nullable_string = {"type": ["string", "null"]}
_boolean = {"type": "boolean"}
_sources = _array({"type": "integer"})
_nullable_strings = {"type": ["array", "null"], "items": _string}

AGENT_SCHEMAS = {
    "homework_detection": GigaChatProvider.OUTPUT_SCHEMA,
    "schedule_binding": _object({
        "subject_mention": _nullable_string,
        "subgroup_mentions": _nullable_strings,
        "deadline_kind": {"type": "string", "enum": ["next_lesson", "date", "none"]},
        "deadline_date": _nullable_string,
        "source_ids": _sources,
    }),
    "duplicate_conflict": _object({"duplicates": _array(_object({
        "assignment_id": _string, "source_ids": _sources,
        "reason": _string, "uncertain": _boolean,
    }))}),
    "material_proposal": _object({"materials": _array(_object({
        "source_ids": _sources, "attachment_id": _string,
        "category_id": _nullable_string, "subject_ids": _nullable_strings,
        "assignment_ids": _nullable_strings, "reason": _string, "uncertain": _boolean,
    }))}),
    "assignment_change": _object({"changes": _array(_object({
        "kind": {"type": "string", "enum": ["cancel", "update"]},
        "assignment_id": _string, "source_ids": _sources, "new_text": _nullable_string,
        "new_due_date": _nullable_string, "reason": _string, "uncertain": _boolean,
    }))}),
}


class _SchemaProvider:
    def __init__(self, delegate, schema):
        self.delegate = delegate
        self.schema = schema
        self.model_name = delegate.model

    def complete(self, system_prompt, event_json):
        return self.delegate.complete(system_prompt, event_json, output_schema=self.schema)


def bind_gigachat_agent(provider, agent_id):
    return _SchemaProvider(provider, AGENT_SCHEMAS[agent_id])
