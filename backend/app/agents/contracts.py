"""Shared, read-only contracts for the five independent AI agents."""

from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class Attachment:
    id: str
    kind: str
    size_bytes: int | None = None
    mime_type: str | None = None
    file_name: str | None = None
    url: str | None = None


@dataclass(frozen=True)
class SourceMessage:
    id: int
    chat_id: str
    topic_id: str
    text: str
    sent_at: str
    ocr_raw: str | None = None
    ocr_corrected: str | None = None
    attachments: tuple[Attachment, ...] = ()


@dataclass(frozen=True)
class EventBundle:
    group_id: str
    chat_id: str
    topic_id: str
    connected_chat_id: str
    connected_topic_id: str
    messages: tuple[SourceMessage, ...]
    subjects: tuple[Mapping[str, Any], ...] = ()
    lessons: tuple[Mapping[str, Any], ...] = ()
    active_assignments: tuple[Mapping[str, Any], ...] = ()
    categories: tuple[Mapping[str, Any], ...] = ()

    def validate_source(self) -> None:
        if not self.group_id:
            raise ValueError("group_id is required")
        if self.chat_id != self.connected_chat_id:
            raise ValueError("chat is not connected")
        if self.topic_id != self.connected_topic_id:
            raise ValueError("topic is not connected")
        if not self.messages:
            raise ValueError("messages are required")
        ids: set[int] = set()
        for message in self.messages:
            if type(message.id) is not int or message.id in ids:
                raise ValueError("message IDs must be unique integers")
            ids.add(message.id)
            if message.chat_id != self.chat_id:
                raise ValueError("message chat differs from bundle chat")
            if message.topic_id != self.topic_id:
                raise ValueError("message topic differs from bundle topic")
            if not isinstance(message.text, str):
                raise ValueError("message text must be a string")

    @property
    def message_ids(self) -> frozenset[int]:
        return frozenset(message.id for message in self.messages)


@dataclass(frozen=True)
class AgentProposal:
    agent_id: str
    proposal_type: str
    source_ids: tuple[int, ...]
    fields: Mapping[str, Any]
    reason: str
    uncertainty: tuple[str, ...] = ()

    def validate(self, bundle: EventBundle) -> None:
        if not self.proposal_type or not self.reason.strip():
            raise ValueError("proposal type and reason are required")
        if not self.source_ids or len(set(self.source_ids)) != len(self.source_ids):
            raise ValueError("proposal must cite unique source IDs")
        if not set(self.source_ids).issubset(bundle.message_ids):
            raise ValueError("proposal cites unknown source IDs")


@dataclass(frozen=True)
class AgentRun:
    agent_id: str
    status: str
    proposals: tuple[AgentProposal, ...] = ()
    raw_output: str | None = None
    model_version: str | None = None
    prompt_version: str | None = None
    error: str | None = None

    @classmethod
    def not_found(
        cls, agent_id: str, model_version: str, prompt_version: str, raw_output: str | None = None
    ) -> AgentRun:
        return cls(
            agent_id=agent_id,
            status="not_found",
            raw_output=raw_output,
            model_version=model_version,
            prompt_version=prompt_version,
        )

    @classmethod
    def failed(cls, agent_id: str, error: str) -> AgentRun:
        return cls(agent_id=agent_id, status="error", error=error)

    def validate(self, bundle: EventBundle) -> None:
        if self.status not in {"not_found", "proposed", "error"}:
            raise ValueError("invalid agent run status")
        if self.status == "proposed" and not self.proposals:
            raise ValueError("proposed run requires a proposal")
        if self.status != "proposed" and self.proposals:
            raise ValueError("only proposed runs may contain proposals")
        for proposal in self.proposals:
            if proposal.agent_id != self.agent_id:
                raise ValueError("proposal agent ID differs from run")
            proposal.validate(bundle)

