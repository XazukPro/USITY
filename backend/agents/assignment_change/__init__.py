"""Assignment change agent. No other agent is required to call it."""

from .agent import AgentRunError, detect_changes

__all__ = ["AgentRunError", "detect_changes"]
