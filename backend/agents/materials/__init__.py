"""Проверка предложений агента учебных материалов."""

from .validation import MaterialValidationError, validate_material_proposal

__all__ = ["MaterialValidationError", "validate_material_proposal"]
