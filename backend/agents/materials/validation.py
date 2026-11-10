"""Проверяет ссылки и метаданные черновика материала без публикации данных."""

import re
from pathlib import PurePosixPath
from typing import Any, Mapping
from urllib.parse import urlsplit


MAX_FILE_BYTES = 100_000_000

_MIME_BY_EXTENSION = {
    ".pdf": {"application/pdf"},
    ".jpg": {"image/jpeg"},
    ".jpeg": {"image/jpeg"},
    ".png": {"image/png"},
    ".gif": {"image/gif"},
    ".webp": {"image/webp"},
    ".heic": {"image/heic"},
    ".bmp": {"image/bmp"},
    ".tif": {"image/tiff"},
    ".tiff": {"image/tiff"},
    ".doc": {"application/msword"},
    ".docx": {"application/vnd.openxmlformats-officedocument.wordprocessingml.document"},
    ".ppt": {"application/vnd.ms-powerpoint"},
    ".pptx": {"application/vnd.openxmlformats-officedocument.presentationml.presentation"},
    ".xls": {"application/vnd.ms-excel"},
    ".xlsx": {"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"},
}
_ALLOWED_MIME = set().union(*_MIME_BY_EXTENSION.values())
_PROPOSAL_FIELDS = {
    "kind", "source_message_ids", "material_type", "attachment_id", "link_url",
    "category_id", "subject_ids", "assignment_ids", "uncertain", "reason",
}


class MaterialValidationError(ValueError):
    """Недопустимый пакет или черновик; текст ошибки не содержит пользовательских данных."""


def _object_id(value: Any) -> bool:
    return (type(value) is int) or (isinstance(value, str) and bool(value.strip()))


def _id_set(items: Any, label: str) -> set:
    if not isinstance(items, list):
        raise MaterialValidationError("{}: ожидается список".format(label))
    found = set()
    for item in items:
        if not isinstance(item, Mapping) or not _object_id(item.get("id")) or item["id"] in found:
            raise MaterialValidationError("{}: недопустимый или повторяющийся ID".format(label))
        found.add(item["id"])
    return found


def _reference_ids(value: Any, allowed: set, label: str, allow_empty: bool) -> list:
    if not isinstance(value, list) or (not allow_empty and not value):
        raise MaterialValidationError("{}: ожидается непустой список ID".format(label))
    if any(not _object_id(item) for item in value) or len(value) != len(set(value)):
        raise MaterialValidationError("{}: недопустимый или повторяющийся ID".format(label))
    if not set(value).issubset(allowed):
        raise MaterialValidationError("{}: ID отсутствует в событии".format(label))
    return list(value)


def _check_file(attachment: Mapping[str, Any]) -> None:
    if attachment.get("kind") not in ("file", "photo"):
        raise MaterialValidationError("вложение не является файлом или фото")
    size = attachment.get("size_bytes")
    if type(size) is not int or not 0 < size <= MAX_FILE_BYTES:
        raise MaterialValidationError("размер файла неизвестен или превышает 100 МБ")
    mime = attachment.get("mime_type")
    name = attachment.get("file_name")
    if mime is not None and (not isinstance(mime, str) or mime not in _ALLOWED_MIME | {"application/octet-stream"}):
        raise MaterialValidationError("неподдерживаемый тип файла")
    if name is not None:
        if not isinstance(name, str):
            raise MaterialValidationError("недопустимое имя файла")
        extension = PurePosixPath(name).suffix.casefold()
        if extension not in _MIME_BY_EXTENSION:
            raise MaterialValidationError("неподдерживаемое расширение файла")
        if mime not in (None, "application/octet-stream") and mime not in _MIME_BY_EXTENSION[extension]:
            raise MaterialValidationError("тип файла не соответствует расширению")
    elif mime not in _ALLOWED_MIME:
        raise MaterialValidationError("тип файла неизвестен")


def _check_link(url: Any, messages: list) -> None:
    if not isinstance(url, str) or not url:
        raise MaterialValidationError("ссылка отсутствует")
    try:
        parsed = urlsplit(url)
    except ValueError:
        raise MaterialValidationError("недопустимая ссылка") from None
    if any(char.isspace() for char in url) or parsed.scheme not in ("http", "https") or not parsed.hostname or parsed.username or parsed.password:
        raise MaterialValidationError("недопустимая ссылка")
    if not any(
        any(match.group(0).rstrip(".,;!?") == url for match in re.finditer(r"https?://[^\s<>()]+", message.get("text", "")))
        or any(item.get("kind") == "link" and item.get("url") == url for item in message.get("attachments", []))
        for message in messages
    ):
        raise MaterialValidationError("ссылка отсутствует в исходных сообщениях")


def validate_material_proposal(bundle: Mapping[str, Any], proposal: Mapping[str, Any]) -> dict:
    """Возвращает проверенный черновик либо вызывает MaterialValidationError.

    Пакет формирует доверенный backend из подключённой темы. Проверка метаданных
    не заменяет анализ содержимого файла на этапе загрузки и решение админа.
    """
    if not isinstance(bundle, Mapping) or not isinstance(proposal, Mapping):
        raise MaterialValidationError("пакет и черновик должны быть объектами")
    if not _object_id(bundle.get("group_id")):
        raise MaterialValidationError("не указан ID группы")
    chat_id, topic_id = bundle.get("chat_id"), bundle.get("topic_id")
    if chat_id is None or topic_id is None or chat_id != bundle.get("connected_chat_id") or topic_id != bundle.get("connected_topic_id"):
        raise MaterialValidationError("событие не из подключённой темы")
    messages = bundle.get("messages")
    message_ids = _id_set(messages, "сообщения")
    if not message_ids:
        raise MaterialValidationError("нет исходных сообщений")
    for message in messages:
        if message.get("chat_id") != chat_id or message.get("topic_id") != topic_id:
            raise MaterialValidationError("сообщение не из подключённой темы")
        if not isinstance(message.get("text", ""), str):
            raise MaterialValidationError("недопустимый текст сообщения")
        _id_set(message.get("attachments", []), "вложения")
    subject_ids = _id_set(bundle.get("subjects"), "предметы")
    category_ids = _id_set(bundle.get("categories"), "категории")
    assignments = bundle.get("assignments")
    assignment_ids = _id_set(assignments, "ДЗ")
    if any(item.get("subject_id") not in subject_ids for item in assignments):
        raise MaterialValidationError("ДЗ связано с неизвестным предметом")

    if set(proposal) != _PROPOSAL_FIELDS or proposal.get("kind") != "material":
        raise MaterialValidationError("неверный набор полей черновика")
    if type(proposal.get("uncertain")) is not bool or not isinstance(proposal.get("reason"), str) or not proposal["reason"].strip():
        raise MaterialValidationError("нет признака неопределённости или объяснения")
    source_ids = _reference_ids(proposal["source_message_ids"], message_ids, "источники", False)
    cited = [message for message in messages if message["id"] in source_ids]

    material_type = proposal["material_type"]
    attachment_id, link_url = proposal["attachment_id"], proposal["link_url"]
    if material_type == "file" and _object_id(attachment_id) and link_url is None:
        matching = [attachment for message in cited for attachment in message.get("attachments", []) if attachment["id"] == attachment_id]
        if len(matching) != 1:
            raise MaterialValidationError("вложение отсутствует в указанных сообщениях")
        _check_file(matching[0])
    elif material_type == "link" and attachment_id is None:
        _check_link(link_url, cited)
    else:
        raise MaterialValidationError("материал должен ссылаться на один файл или ссылку")

    category_id = proposal["category_id"]
    if category_id is not None and category_id not in category_ids:
        raise MaterialValidationError("неизвестная категория")
    selected_subjects = proposal["subject_ids"]
    if selected_subjects is not None:
        selected_subjects = _reference_ids(selected_subjects, subject_ids, "предметы черновика", False)
    selected_assignments = proposal["assignment_ids"]
    if selected_assignments is not None:
        selected_assignments = _reference_ids(selected_assignments, assignment_ids, "ДЗ черновика", True)
        by_id = {item["id"]: item["subject_id"] for item in assignments}
        if selected_subjects is not None and any(by_id[item] not in selected_subjects for item in selected_assignments):
            raise MaterialValidationError("ДЗ не относится к выбранным предметам")
    if None in (category_id, selected_subjects, selected_assignments) and not proposal["uncertain"]:
        raise MaterialValidationError("неизвестные поля требуют отметки о неопределённости")
    return {
        **proposal,
        "source_message_ids": source_ids,
        "subject_ids": selected_subjects,
        "assignment_ids": selected_assignments,
        "reason": proposal["reason"].strip(),
    }
