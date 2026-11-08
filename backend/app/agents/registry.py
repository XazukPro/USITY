"""Registry that runs all five agents independently on the same trusted bundle."""

from collections.abc import Sequence
from typing import Protocol

from app.agents.contracts import AgentRun, EventBundle

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

