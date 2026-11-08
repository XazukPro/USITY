"""Registry that runs all five agents independently on the same trusted bundle."""

from collections.abc import Sequence
from dataclasses import dataclass
from datetime import datetime
from typing import Protocol

from app.agents.assignment_changes import run_assignment_change
from app.agents.contracts import AgentRun, EventBundle
from app.agents.duplicates import run_duplicate_conflict
from app.agents.homework import run_homework_detection
from app.agents.materials import run_material_proposal
from app.agents.schedule_binding import run_schedule_binding

AGENT_IDS = (
    "homework_detection",
    "schedule_binding",
    "duplicate_conflict",
    "material_proposal",
    "assignment_change",
)


class RegisteredAgent(Protocol):
    agent_id: str

    def run(self, bundle: EventBundle) -> AgentRun: ...


@dataclass(frozen=True)
class _BoundAgent:
    agent_id: str
    provider: object
    now: datetime

    def run(self, bundle: EventBundle) -> AgentRun:
        if self.agent_id == "homework_detection":
            return run_homework_detection(bundle, self.provider)
        if self.agent_id == "schedule_binding":
            return run_schedule_binding(bundle, self.provider, self.now)
        if self.agent_id == "duplicate_conflict":
            return run_duplicate_conflict(bundle, self.provider)
        if self.agent_id == "material_proposal":
            return run_material_proposal(bundle, self.provider)
        return run_assignment_change(bundle, self.provider, self.now.date())


def build_default_agents(provider: object, now: str | datetime) -> tuple[RegisteredAgent, ...]:
    """Bind the same replaceable LLM adapter to each independent agent."""
    current = datetime.fromisoformat(now) if isinstance(now, str) else now
    if current.tzinfo is None:
        raise ValueError("now must include a timezone")
    return tuple(_BoundAgent(agent_id, provider, current) for agent_id in AGENT_IDS)


def run_all_agents(
    bundle: EventBundle, agents: Sequence[RegisteredAgent]
) -> tuple[AgentRun, ...]:
    """Run every named agent; an individual failure remains visible to the admin."""
    bundle.validate_source()
    if tuple(agent.agent_id for agent in agents) != AGENT_IDS:
        raise ValueError("agents must be registered once in the required order")

    runs = []
    for agent in agents:
        try:
            run = agent.run(bundle)
            if run.agent_id != agent.agent_id:
                raise ValueError("agent returned another agent ID")
            run.validate(bundle)
        except Exception as exc:
            run = AgentRun.failed(agent.agent_id, type(exc).__name__)
        runs.append(run)
    return tuple(runs)

