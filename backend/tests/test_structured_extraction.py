"""Regressions for the five-agent extraction boundary (no live model calls)."""

import json
from dataclasses import replace
from datetime import datetime

import pytest

from app.agents.contracts import EventBundle, SourceMessage
from app.agents.gigachat_schemas import bind_gigachat_agent
from app.agents.homework import (
    EventBundle as LegacyBundle,
)
from app.agents.homework import (
    Message,
    ProposalError,
    detect_homework,
    run_homework_detection,
)
from app.agents.providers import GigaChatProvider
from app.agents.schedule_binding import run_schedule_binding

NOW = datetime.fromisoformat("2026-11-17T12:00:00+03:00")
INSTRUCTION = "К следующей паре по математике нужно решить"
CONTINUATION = "номера 4 и 5 на странице 20"


class Provider:
    model_name = "fixture"

    def __init__(self, response):
        self.response = response
        self.calls = []

    def complete(self, system_prompt, event_json):
        self.calls.append((system_prompt, json.loads(event_json)))
        return json.dumps(self.response, ensure_ascii=False)


def event(*texts):
    return EventBundle(
        "group",
        "chat",
        "topic",
        "chat",
        "topic",
        tuple(
            SourceMessage(i, "chat", "topic", text, NOW.isoformat())
            for i, text in enumerate(texts or (INSTRUCTION,), start=10)
        ),
        subjects=({"id": "math", "name": "Математика", "aliases": []},),
        lessons=(lesson("next", "2026-11-18T09:00:00+03:00"),),
    )


def lesson(lesson_id, starts_at, groups=()):
    return {
        "id": lesson_id,
        "subject_id": "math",
        "starts_at": starts_at,
        "subgroup_ids": list(groups),
    }


def homework(kind="incomplete_homework", text=None, source_ids=None, uncertain=True):
    return {
        "kind": kind,
        "text": text,
        "source_ids": [10] if source_ids is None else source_ids,
        "uncertain": uncertain,
    }


def binding(bundle, mention="математике", groups=None, deadline="none", sources=None):
    provider = Provider(
        {
            "subject_mention": mention,
            "subgroup_mentions": groups,
            "deadline_kind": deadline,
            "deadline_date": None,
            "source_ids": [10] if sources is None else sources,
        }
    )
    run = run_schedule_binding(bundle, provider, NOW)
    run.validate(bundle)
    return run.proposals[0]


def test_instruction_only_creates_incomplete_proposal_with_null_text():
    bundle = event()
    provider = Provider(homework())
    run = run_homework_detection(bundle, provider)
    run.validate(bundle)
    assert run.status == "proposed"
    assert run.proposals[0].proposal_type == "incomplete_homework"
    assert run.proposals[0].fields == {"text": None, "uncertain": True}
    assert run.proposals[0].source_ids == (10,)
    assert run.raw_output == json.dumps(homework(), ensure_ascii=False)


def test_structured_prompt_and_context_support_continuation_and_preserve_details():
    bundle = event(INSTRUCTION, CONTINUATION)
    provider = Provider(
        homework("new_homework", "Решить: стр. 20, № 4, 5", [10, 11], False)
    )
    run = run_homework_detection(bundle, provider)
    assert run.proposals[0].fields["text"] == "Решить: стр. 20, № 4, 5"
    assert run.proposals[0].source_ids == (10, 11)
    prompt, payload = provider.calls[0]
    # These are model instructions, not a claim about the live model's accuracy.
    assert INSTRUCTION in prompt
    assert CONTINUATION in prompt
    assert '"kind":"incomplete_homework","text":null' in prompt
    assert "Решить: стр. 20, № 4, 5" in prompt
    assert "важные детали" in prompt
    assert [message["text"] for message in payload["messages"]] == [
        INSTRUCTION,
        CONTINUATION,
    ]


@pytest.mark.parametrize(
    "corrected,expected", [(None, "Решить № 4"), ("Решить № 5", "Решить № 5")]
)
def test_homework_passes_photo_ocr_to_model(corrected, expected):
    bundle = event("")
    bundle = replace(
        bundle,
        messages=(
            replace(bundle.messages[0], ocr_raw="Решить № 4", ocr_corrected=corrected),
        ),
    )
    provider = Provider(homework("new_homework", expected, uncertain=False))
    run = run_homework_detection(bundle, provider)
    assert provider.calls[0][1]["messages"][0]["ocr_text"] == expected
    assert run.proposals[0].fields["text"] == expected


@pytest.mark.parametrize("ids", [[], [999], [True], ["10"], [10, 10], [[10]], [{}]])
def test_incomplete_rejects_invalid_source_ids(ids):
    with pytest.raises(ProposalError, match="source_ids"):
        run_homework_detection(event(), Provider(homework(source_ids=ids)))


@pytest.mark.parametrize(
    "response",
    [
        homework(text="Решить"),
        homework("new_homework"),
        homework("new_homework", "  "),
        homework(uncertain="true"),
        homework("none", source_ids=[10]),
        homework() | {"publish": True},
    ],
)
def test_structured_output_rejects_invalid_contract(response):
    with pytest.raises(ProposalError):
        run_homework_detection(event(), Provider(response))


def test_none_is_not_a_proposal():
    run = run_homework_detection(
        event("Спасибо"), Provider(homework("none", source_ids=[], uncertain=False))
    )
    assert run.status == "not_found"
    assert run.proposals == ()


def test_legacy_detection_keeps_old_contract():
    bundle = LegacyBundle(
        "group", "topic", (Message(10, INSTRUCTION, NOW.isoformat()),)
    )
    with pytest.raises(ProposalError):
        detect_homework(bundle, Provider(homework()))
    proposal = detect_homework(
        bundle, Provider(homework("new_homework", "Номера 4 и 5"))
    )
    assert proposal.kind == "new_homework"
    assert proposal.text == "Номера 4 и 5"


def test_only_bound_five_agent_provider_uses_incomplete_schema():
    class Transport:
        model = "test-model"

        def complete(self, prompt, payload, *, output_schema):
            assert output_schema["properties"]["kind"]["enum"] == [
                "new_homework",
                "incomplete_homework",
                "none",
            ]
            return json.dumps(homework())

    provider = bind_gigachat_agent(Transport(), "homework_detection")
    assert (
        run_homework_detection(event(), provider).proposals[0].proposal_type
        == "incomplete_homework"
    )
    assert GigaChatProvider.OUTPUT_SCHEMA["properties"]["kind"]["enum"] == [
        "new_homework",
        "none",
    ]


@pytest.mark.parametrize("mention", ["математике", "Математика"])
def test_inflected_subject_matches_context_name_and_defaults_to_next_lesson(mention):
    proposal = binding(event(), mention)
    assert proposal.fields["subject_id"] == "math"
    assert proposal.fields["lesson_id"] == "next"
    assert proposal.fields["due_at"] == "2026-11-18T09:00:00+03:00"
    assert "deadline_not_specified" not in proposal.uncertainty


def test_subject_alias_maps_canonical_model_name_to_cited_evidence():
    bundle = replace(
        event("По матану решить листок"),
        subjects=(
            {"id": "math", "name": "Математический анализ", "aliases": ["матан"]},
        ),
    )
    assert binding(bundle, "Математический анализ").fields["subject_id"] == "math"


@pytest.mark.parametrize(
    "mention,text",
    [
        ("Математика", "Решить листок"),
        ("математикатор", "По математикатору решить листок"),
    ],
)
def test_subject_cannot_be_hallucinated_or_matched_by_arbitrary_prefix(mention, text):
    proposal = binding(event(text), mention)
    assert proposal.fields["subject_id"] is None
    assert proposal.fields["lesson_id"] is None
    assert "subject_missing_or_ambiguous" in proposal.uncertainty


def test_subject_evidence_must_be_in_cited_messages():
    proposal = binding(event("Решить листок", "По математике"), "Математика")
    assert proposal.fields["subject_id"] is None


def test_shared_alias_does_not_choose_a_subject():
    bundle = replace(
        event("По матану решить листок"),
        subjects=(
            {"id": "math", "name": "Математика", "aliases": ["матан"]},
            {"id": "analysis", "name": "Анализ", "aliases": ["матан"]},
        ),
    )
    for mention in ("матану", "Математика"):
        proposal = binding(bundle, mention)
        assert proposal.fields["subject_id"] is None
        assert proposal.fields["candidate_subject_ids"] == ["analysis", "math"]


def test_default_lesson_ignores_past_cancelled_and_other_subjects_and_sorts():
    bundle = replace(
        event(),
        lessons=(
            lesson("later", "2026-11-20T09:00:00+03:00"),
            lesson("past", "2026-11-17T11:00:00+03:00"),
            lesson("cancelled", "2026-11-17T13:00:00+03:00") | {"cancelled": True},
            lesson("other", "2026-11-17T14:00:00+03:00") | {"subject_id": "physics"},
            lesson("next", "2026-11-18T09:00:00+03:00"),
        ),
    )
    assert binding(bundle).fields["lesson_id"] == "next"


def test_equal_nearest_lessons_are_ambiguous():
    bundle = replace(
        event(),
        lessons=(
            lesson("a", "2026-11-18T09:00:00+03:00"),
            lesson("b", "2026-11-18T09:00:00+03:00"),
        ),
    )
    proposal = binding(bundle)
    assert proposal.fields["lesson_id"] is None
    assert "multiple_matching_lessons" in proposal.uncertainty


def grouped_event(text="По математике первой подгруппе решить листок"):
    return replace(
        event(text),
        subjects=(
            {
                "id": "math",
                "name": "Математика",
                "aliases": [],
                "subgroups": [
                    {
                        "id": "g1",
                        "name": "первая подгруппа",
                        "aliases": ["первой подгруппе"],
                    },
                    {
                        "id": "g2",
                        "name": "вторая подгруппа",
                        "aliases": ["второй подгруппе"],
                    },
                ],
            },
        ),
        lessons=(
            lesson("group-2", "2026-11-18T09:00:00+03:00", ["g2"]),
            lesson("group-1", "2026-11-19T09:00:00+03:00", ["g1"]),
        ),
    )


def test_subgroups_resolve_to_actual_context_ids_before_filtering_lessons():
    proposal = binding(grouped_event(), groups=["первой подгруппе"])
    assert proposal.fields["subgroup_ids"] == ["g1"]
    assert proposal.fields["lesson_id"] == "group-1"


@pytest.mark.parametrize("groups", [["g999"], ["третьей подгруппе"], ["g2"], None, []])
def test_missing_or_unsupported_subgroup_is_not_guessed(groups):
    proposal = binding(
        grouped_event("По математике третьей подгруппе решить листок"), groups=groups
    )
    assert proposal.fields["subgroup_ids"] is None
    assert proposal.fields["lesson_id"] is None
    assert any("subgroup" in flag for flag in proposal.uncertainty)


def test_all_subgroups_never_selects_a_lesson_for_only_one_subgroup():
    proposal = binding(
        grouped_event("По математике всем подгруппам решить листок"), groups=[]
    )
    assert proposal.fields["subgroup_ids"] == []
    assert proposal.fields["lesson_id"] is None


def test_multiple_subgroups_do_not_match_partial_lesson_coverage():
    proposal = binding(
        grouped_event(
            "По математике первой подгруппе и второй подгруппе решить листок"
        ),
        groups=["первой подгруппе", "второй подгруппе"],
    )
    assert proposal.fields["subgroup_ids"] == ["g1", "g2"]
    assert proposal.fields["lesson_id"] is None


@pytest.mark.parametrize("ids", [[True], ["10"], [[10]], [{}], [10, 10], [999]])
def test_schedule_rejects_invalid_ids_as_validation_errors(ids):
    with pytest.raises(ValueError, match="source"):
        binding(event(), sources=ids)


def test_pipeline_subject_ids_keep_unknown_subgroup_but_can_bind_common_lesson():
    bundle = replace(
        event(),
        subjects=(
            {
                "id": "Математика",
                "name": "Математика",
                "aliases": [],
                "subgroup_ids": ["1", "2"],
            },
        ),
        lessons=(
            lesson("common", "2026-11-18T09:00:00+03:00")
            | {"subject_id": "Математика"},
        ),
    )
    proposal = binding(bundle)
    assert proposal.fields["subject_id"] == "Математика"
    assert proposal.fields["subgroup_ids"] is None
    assert "subgroup_unspecified" in proposal.uncertainty
    assert proposal.fields["lesson_id"] == "common"


@pytest.mark.parametrize(
    "text,expected",
    [
        ("По математике подгруппе 1 решить № 2", ["1"]),
        ("По математике решить № 1", None),
    ],
)
def test_pipeline_numeric_subgroup_ids_need_subgroup_evidence(text, expected):
    bundle = replace(
        event(text),
        subjects=(
            {
                "id": "math",
                "name": "Математика",
                "aliases": [],
                "subgroup_ids": ["1", "2"],
            },
        ),
    )
    proposal = binding(bundle, groups=["1"])
    assert proposal.fields["subgroup_ids"] == expected


def test_shared_subgroup_alias_cannot_be_disambiguated_by_model_id():
    bundle = grouped_event("По математике лабораторной подгруппе решить листок")
    subject = dict(bundle.subjects[0])
    subject["subgroups"] = [
        group | {"aliases": ["лабораторной подгруппе"]}
        for group in subject["subgroups"]
    ]
    bundle = replace(bundle, subjects=(subject,))
    proposal = binding(bundle, groups=["g1"])
    assert proposal.fields["subgroup_ids"] is None
    assert proposal.fields["lesson_id"] is None
    assert "subgroup_missing_or_ambiguous" in proposal.uncertainty
