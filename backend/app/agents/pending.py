"""Temporary worker entry points for the two missing agent implementations."""

from typing import Never


class AgentUnavailable(NotImplementedError):
    """The worker should record a skipped agent separately from a negative result."""


def check_duplicates(_bundle: object) -> Never:
    raise AgentUnavailable("duplicate_check")


def classify_material(_bundle: object) -> Never:
    raise AgentUnavailable("material_classification")
