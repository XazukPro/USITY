"""Private material library.

SQLite development stands store blobs beside the database in materials/.
USITY_MATERIALS_DIR overrides the private stand directory. For production set
USITY_MATERIALS_S3_BUCKET, optional USITY_MATERIALS_S3_ENDPOINT and configure
the normal AWS credential chain. Provision a private bucket with public access
blocked. Install requirements-materials.txt for S3 and legacy Office uploads.
"""

import base64
import logging
import os
import re
import shutil
import struct
import tempfile
import unicodedata
import zipfile
from contextlib import closing
from datetime import datetime, timedelta
from pathlib import Path
from typing import Annotated, Literal
from urllib.parse import quote, urlsplit
from uuid import uuid4
from xml.etree import ElementTree

from fastapi import Header, HTTPException, Request
from fastapi.responses import Response, StreamingResponse
from pydantic import Field, StringConstraints, ValidationError, field_validator
from sqlalchemy import JSON, ForeignKey, Integer, String, Text, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Mapped, mapped_column
from starlette.background import BackgroundTask
from starlette.concurrency import run_in_threadpool

from app.auth import authenticate, require_group
from app.db import Base, UTCDateTime
from app.group_access import subject_group_counts
from app.models import Lesson, utc_now
from app.schemas import InputModel

log = logging.getLogger(__name__)
MAX_FILE_BYTES = 100 * 1024 * 1024
CHUNK = 256 * 1024
CATEGORIES = (
    "Учебники",
    "Лекции",
    "Практика",
    "Презентации",
    "Фото",
    "Ссылки",
    "Другое",
)
OFFICE = "application/vnd.openxmlformats-officedocument."
MIME = {
    "pdf": "application/pdf",
    "png": "image/png",
    "jpg": "image/jpeg",
    "jpeg": "image/jpeg",
    "webp": "image/webp",
    "gif": "image/gif",
    "doc": "application/msword",
    "ppt": "application/vnd.ms-powerpoint",
    "xls": "application/vnd.ms-excel",
    "docx": OFFICE + "wordprocessingml.document",
    "pptx": OFFICE + "presentationml.presentation",
    "xlsx": OFFICE + "spreadsheetml.sheet",
}
OOXML_PART = {
    "docx": "word/document.xml",
    "pptx": "ppt/presentation.xml",
    "xlsx": "xl/workbook.xml",
}
DANGEROUS_EXT = {
    "exe",
    "dll",
    "msi",
    "cmd",
    "bat",
    "com",
    "js",
    "vbs",
    "ps1",
    "scr",
    "sh",
    "apk",
    "jar",
    "lnk",
    "html",
    "hta",
    "svg",
}
Name = Annotated[
    str, StringConstraints(strip_whitespace=True, min_length=1, max_length=200)
]
CategoryName = Annotated[
    str, StringConstraints(strip_whitespace=True, min_length=1, max_length=80)
]


class Category(Base):
    __tablename__ = "material_categories"
    group_id: Mapped[str] = mapped_column(
        ForeignKey("study_groups.id"), primary_key=True
    )
    normalized: Mapped[str] = mapped_column(String(200), primary_key=True)
    name: Mapped[str] = mapped_column(String(80))


class Material(Base):
    __tablename__ = "library_materials"
    id: Mapped[str] = mapped_column(
        String(32), primary_key=True, default=lambda: uuid4().hex
    )
    group_id: Mapped[str] = mapped_column(ForeignKey("study_groups.id"), index=True)
    creator: Mapped[str] = mapped_column(String(100))
    scope: Mapped[str] = mapped_column(String(10))
    status: Mapped[str] = mapped_column(String(12))
    title: Mapped[str] = mapped_column(String(200))
    category: Mapped[str] = mapped_column(String(80))
    subjects: Mapped[list] = mapped_column(JSON)
    url: Mapped[str | None] = mapped_column(Text)
    filename: Mapped[str | None] = mapped_column(String(180))
    mime: Mapped[str | None] = mapped_column(String(120))
    size: Mapped[int | None] = mapped_column(Integer)
    blob_key: Mapped[str | None] = mapped_column(String(32), unique=True)
    reviewed_by: Mapped[str | None] = mapped_column(String(100))
    created_at: Mapped[datetime] = mapped_column(UTCDateTime(), default=utc_now)


class BlobCleanup(Base):
    """Durable intent for interrupted uploads and committed removals."""

    __tablename__ = "material_blob_cleanup"
    blob_key: Mapped[str] = mapped_column(String(32), primary_key=True)
    due: Mapped[datetime] = mapped_column(UTCDateTime())


class Metadata(InputModel):
    scope: Literal["personal", "group"]
    title: Name
    category: CategoryName
    subjects: list[Name] = Field(default_factory=list, max_length=80)


class LinkInput(Metadata):
    url: str = Field(min_length=1, max_length=2048)

    @field_validator("url")
    @classmethod
    def secure_url(cls, value):
        if "\\" in value or any(
            c.isspace() or unicodedata.category(c).startswith("C") for c in value
        ):
            raise ValueError("Некорректная ссылка")
        uri = urlsplit(value)
        if (
            uri.scheme != "https"
            or not uri.hostname
            or uri.username is not None
            or uri.port == 0
        ):
            raise ValueError("Нужна HTTPS-ссылка без учетных данных")
        return value


class FileInput(Metadata):
    filename: str = Field(min_length=1, max_length=180)

    @field_validator("filename")
    @classmethod
    def safe_name(cls, value):
        name = unicodedata.normalize("NFKC", value)
        parts = name.casefold().split(".")
        if (
            name.startswith(".")
            or name != name.strip()
            or len(parts) < 2
            or parts[-1] not in MIME
            or DANGEROUS_EXT.intersection(parts[:-1])
            or any(
                c in '/\\:<>"|?*' or unicodedata.category(c).startswith("C")
                for c in name
            )
        ):
            raise ValueError("Недопустимое имя или формат файла")
        return name


class CategoryInput(InputModel):
    name: CategoryName


class Decision(InputModel):
    action: Literal["approve", "reject"]


def _invalid():
    return HTTPException(422, "Содержимое файла не соответствует разрешённому формату")


def _validate_ooxml(source, ext, size):
    # Bound central-directory allocation before ZipFile constructs member objects.
    source.seek(max(0, size - 65557))
    tail = source.read()
    offset = tail.rfind(b"PK\x05\x06")
    if offset < 0 or len(tail) - offset < 22:
        raise _invalid()
    _, disk, first, on_disk, total, directory_bytes, _, comment = struct.unpack_from(
        "<4s4H2LH", tail, offset
    )
    if (
        disk
        or first
        or on_disk != total
        or total > 10000
        or directory_bytes > 4 * 1024 * 1024
        or len(tail) != offset + 22 + comment
    ):
        raise _invalid()
    with zipfile.ZipFile(source) as z:
        entries = z.infolist()
        if len(entries) != total or sum(i.file_size for i in entries) > 512 * 1024**2:
            raise _invalid()
        names = set()
        for entry in entries:
            name = entry.filename.casefold()
            parts = name.split("/")
            if (
                name in names
                or name.startswith("/")
                or ".." in parts
                or "\\" in name
                or entry.flag_bits & 1
                or name.rsplit(".", 1)[-1] in DANGEROUS_EXT
                or "vbaproject" in name
                or {"activex", "embeddings", "macrosheets"} & set(parts)
            ):
                raise _invalid()
            names.add(name)
        main = OOXML_PART[ext]
        if main not in names or z.getinfo("[Content_Types].xml").file_size > 512 * 1024:
            raise _invalid()
        xml = z.read("[Content_Types].xml")
        if b"<!" in xml or b"\0" in xml:
            raise _invalid()
        declarations = ElementTree.fromstring(xml)
        if not any(
            e.get("PartName") == "/" + main
            and e.get("ContentType") == MIME[ext] + ".main+xml"
            for e in declarations
        ):
            raise _invalid()
        if any(
            "macroenabled" in e.get("ContentType", "").lower()
            or "vba" in e.get("ContentType", "").lower()
            for e in declarations
        ):
            raise _invalid()


def _validate_ole(source, ext):
    try:
        import olefile
    except ImportError as exc:
        raise HTTPException(
            503, "Проверка старых форматов Office не настроена"
        ) from exc
    source.seek(0)
    with olefile.OleFileIO(source, raise_defects=olefile.DEFECT_INCORRECT) as ole:
        paths = [[s.casefold() for s in path] for path in ole.listdir(storages=True)]
        root_names = {p[0] for p in paths if len(p) == 1}
        required = {
            "doc": {"worddocument"},
            "xls": {"workbook", "book"},
            "ppt": {"powerpoint document"},
        }
        forbidden = {
            "macros",
            "vba",
            "_vba_project_cur",
            "objectpool",
            "encryptedpackage",
            "\x01ole10native",
        }
        if not root_names.intersection(required[ext]) or any(
            forbidden.intersection(p) for p in paths
        ):
            raise _invalid()


def _validate_file(source, filename, size):
    ext = filename.rsplit(".", 1)[1].lower()
    source.seek(0)
    head = source.read(32)
    source.seek(max(0, size - 1024))
    tail = source.read()
    try:
        if ext in OOXML_PART and head.startswith(b"PK\x03\x04"):
            _validate_ooxml(source, ext, size)
        elif ext in {"doc", "xls", "ppt"} and head.startswith(
            bytes.fromhex("d0cf11e0a1b11ae1")
        ):
            _validate_ole(source, ext)
        elif not {
            "pdf": re.match(rb"%PDF-\d\.\d", head) and tail.rstrip().endswith(b"%%EOF"),
            "png": head.startswith(b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR")
            and tail.endswith(b"IEND\xaeB`\x82"),
            "gif": head[:6] in (b"GIF87a", b"GIF89a") and tail.endswith(b";"),
            "jpg": head.startswith(b"\xff\xd8\xff") and tail.endswith(b"\xff\xd9"),
            "jpeg": head.startswith(b"\xff\xd8\xff") and tail.endswith(b"\xff\xd9"),
            "webp": head[:4] == b"RIFF"
            and head[8:12] == b"WEBP"
            and int.from_bytes(head[4:8], "little") + 8 == size,
        }.get(ext):
            raise _invalid()
    except (
        OSError,
        ValueError,
        KeyError,
        IndexError,
        RuntimeError,
        struct.error,
        zipfile.BadZipFile,
        ElementTree.ParseError,
    ) as exc:
        raise _invalid() from exc
    source.seek(0)
    return MIME[ext]


class PrivateDirectory:
    def __init__(self, root):
        self.root = Path(root)
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
        if self.root.is_symlink() or self.root.stat().st_mode & 0o077:
            raise HTTPException(503, "Хранилищу требуется отдельный закрытый каталог")

    def path(self, key):
        if not re.fullmatch("[0-9a-f]{32}", key):
            raise ValueError("Некорректный ключ объекта")
        return self.root / key

    def put(self, key, source, mime):
        fd = os.open(self.path(key), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        with os.fdopen(fd, "wb") as dest:
            shutil.copyfileobj(source, dest, CHUNK)
            dest.flush()
            os.fsync(dest.fileno())

    def open(self, key):
        return os.fdopen(os.open(self.path(key), os.O_RDONLY | os.O_NOFOLLOW), "rb")

    def delete(self, key):
        self.path(key).unlink(missing_ok=True)


class PrivateS3:
    def __init__(self, bucket):
        import boto3

        self.bucket = bucket
        self.client = boto3.client(
            "s3", endpoint_url=os.getenv("USITY_MATERIALS_S3_ENDPOINT")
        )

    def put(self, key, source, mime):
        self.client.put_object(
            Bucket=self.bucket, Key=key, Body=source, ContentType=mime
        )

    def open(self, key):
        return self.client.get_object(Bucket=self.bucket, Key=key)["Body"]

    def delete(self, key):
        self.client.delete_object(Bucket=self.bucket, Key=key)


def _storage(app, db):
    if store := getattr(app.state, "material_storage", None):
        return store
    if bucket := os.getenv("USITY_MATERIALS_S3_BUCKET"):
        try:
            app.state.material_storage = PrivateS3(bucket)
            return app.state.material_storage
        except Exception as exc:
            raise HTTPException(503, "Хранилище S3 недоступно") from exc
    directory = os.getenv("USITY_MATERIALS_DIR")
    bind = db.get_bind()
    if (
        not directory
        and bind.dialect.name == "sqlite"
        and bind.url.database not in (None, "", ":memory:")
    ):
        directory = Path(bind.url.database).resolve().parent / "materials"
    if not directory:
        raise HTTPException(503, "Не настроено файловое хранилище")
    return PrivateDirectory(directory)


def _drain(db, store, key=None):
    # Row locks serialize deletion with publication. On transient store errors
    # leave the record for a subsequent file mutation (including after restart).
    try:
        query = (
            select(BlobCleanup)
            .order_by(BlobCleanup.due)
            .limit(32)
            .with_for_update(skip_locked=True)
        )
        query = (
            query.where(BlobCleanup.blob_key == key)
            if key
            else query.where(BlobCleanup.due <= utc_now())
        )
        for job in db.scalars(query).all():
            store.delete(job.blob_key)
            db.delete(job)
        db.commit()
    except Exception:
        db.rollback()
        log.warning("Material blob cleanup deferred", exc_info=True)


def _categories(db, group_id):
    return [
        *CATEGORIES,
        *db.scalars(
            select(Category.name)
            .where(Category.group_id == group_id)
            .order_by(Category.normalized)
        ),
    ]


def _validate_catalog(db, group_id, body):
    if body.category not in _categories(db, group_id):
        raise HTTPException(422, "Неизвестная категория")
    subjects = set(subject_group_counts(db, group_id))
    if not subjects and body.subjects:
        subjects.update(
            db.scalars(
                select(Lesson.subject).where(Lesson.group_id == group_id).distinct()
            )
        )
    if not subjects.issuperset(body.subjects):
        raise HTTPException(422, "Неизвестный предмет")


def _reviewer(member):
    return member.role in ("owner", "admin")


def _visible(group_id, member):
    group_visibility = Material.status == "published"
    if _reviewer(member):
        group_visibility = Material.status.in_(("pending", "published"))
    return select(Material).where(
        Material.group_id == group_id,
        (Material.creator == member.user_id)
        | ((Material.scope == "group") & group_visibility),
    )


def _item(db, group_id, member, item_id, lock=False):
    query = _visible(group_id, member).where(Material.id == item_id)
    row = db.scalar(query.with_for_update() if lock else query)
    if not row:
        raise HTTPException(404, "Материал недоступен")
    return row


def _json(row):
    return {
        key: getattr(row, key)
        for key in (
            "id",
            "scope",
            "status",
            "title",
            "category",
            "subjects",
            "url",
            "filename",
            "size",
            "mime",
            "created_at",
        )
    }


def _publish(db, group_id, member, body, **fields):
    _validate_catalog(db, group_id, body)
    row = Material(
        group_id=group_id,
        creator=member.user_id,
        status="published"
        if body.scope == "personal" or _reviewer(member)
        else "pending",
        **body.model_dump(exclude={"subjects"}),
        subjects=list(dict.fromkeys(body.subjects)),
        **fields,
    )
    db.add(row)
    db.flush()
    result = _json(row)
    db.commit()
    return result


def install_material_library(app, DB, Member):
    path = "/groups/{group_id}/materials"

    @app.get(path)
    def catalog(group_id: str, db: DB, member: Member):
        require_group(member, group_id)
        rows = db.scalars(
            _visible(group_id, member).order_by(Material.created_at.desc(), Material.id)
        )
        return {
            "items": [_json(row) for row in rows],
            "categories": _categories(db, group_id),
        }

    @app.post(path + "/categories", status_code=201)
    def add_category(group_id: str, body: CategoryInput, db: DB, member: Member):
        require_group(member, group_id, admin=True)
        normalized = body.name.casefold()
        if normalized in {s.casefold() for s in CATEGORIES}:
            raise HTTPException(409, "Категория уже существует")
        db.add(Category(group_id=group_id, name=body.name, normalized=normalized))
        try:
            db.commit()
        except IntegrityError as exc:
            db.rollback()
            raise HTTPException(409, "Категория уже существует") from exc
        return {"name": body.name}

    @app.post(path + "/links", status_code=201)
    def add_link(group_id: str, body: LinkInput, db: DB, member: Member):
        require_group(member, group_id)
        return _publish(db, group_id, member, body)

    @app.post(path + "/files", status_code=201)
    async def upload(
        group_id: str,
        request: Request,
        db: DB,
        member: Member,
        x_material_metadata: Annotated[str, Header(max_length=16384)],
    ):
        require_group(member, group_id)
        try:
            raw = base64.b64decode(x_material_metadata, altchars=b"-_", validate=True)
            body = FileInput.model_validate_json(raw)
        except (ValueError, ValidationError) as exc:
            raise HTTPException(422, "Некорректные параметры файла") from exc
        length = request.headers.get("content-length")
        if length and (
            not re.fullmatch(r"[0-9]{1,18}", length) or int(length) > MAX_FILE_BYTES
        ):
            raise HTTPException(413, "Файл превышает 100 МБ")
        _validate_catalog(db, group_id, body)
        db.rollback()  # Release SQLite's write reservation during network I/O.
        size = 0
        with tempfile.TemporaryFile() as staged:
            async for chunk in request.stream():
                size += len(chunk)
                if size > MAX_FILE_BYTES:
                    raise HTTPException(413, "Файл превышает 100 МБ")
                if chunk:
                    await run_in_threadpool(staged.write, chunk)

            def finish():
                mime = _validate_file(staged, body.filename, size)
                store = _storage(app, db)
                _drain(db, store)
                key = uuid4().hex
                db.add(BlobCleanup(blob_key=key, due=utc_now() + timedelta(hours=1)))
                db.commit()
                try:
                    job = db.get(BlobCleanup, key, with_for_update=True)
                    if job is None:
                        raise HTTPException(409, "Время загрузки истекло")
                    active = authenticate(db, request.headers.get("authorization"))
                    require_group(active, group_id)
                    store.put(key, staged, mime)
                    db.delete(job)
                    return _publish(
                        db, group_id, active, body, blob_key=key, size=size, mime=mime
                    )
                except Exception as exc:
                    db.rollback()
                    _drain(db, store, key)
                    if isinstance(exc, HTTPException):
                        raise
                    raise HTTPException(503, "Не удалось сохранить файл") from exc

            return await run_in_threadpool(finish)

    @app.head(path + "/{item_id}/download")
    @app.get(path + "/{item_id}/download")
    def download(group_id: str, item_id: str, request: Request, db: DB, member: Member):
        require_group(member, group_id)
        row = _item(db, group_id, member, item_id)
        if not row.blob_key or row.status == "rejected":
            raise HTTPException(404, "Файл недоступен")
        headers = {
            "Content-Length": str(row.size),
            "Cache-Control": "private, no-store",
            "X-Content-Type-Options": "nosniff",
            "Content-Disposition": "attachment; filename*=UTF-8''"
            + quote(row.filename, safe=""),
        }
        mime = row.mime
        if request.method == "HEAD":
            return Response(headers=headers, media_type=mime)
        try:
            body = _storage(app, db).open(row.blob_key)
        except Exception as exc:
            raise HTTPException(503, "Не удалось прочитать файл") from exc
        db.rollback()

        def chunks():
            with closing(body):
                yield from iter(lambda: body.read(CHUNK), b"")

        return StreamingResponse(
            chunks(),
            media_type=mime,
            headers=headers,
            background=BackgroundTask(body.close),
        )

    def remove_blob(db, row):
        key = row.blob_key
        if key:
            db.add(BlobCleanup(blob_key=key, due=utc_now()))
            row.blob_key = None
        return key

    def commit_removal(db, key):
        db.commit()
        if key:
            _drain(db, _storage(app, db), key)

    @app.post(path + "/{item_id}/decision")
    def decide(group_id: str, item_id: str, body: Decision, db: DB, member: Member):
        require_group(member, group_id, admin=True)
        row = _item(db, group_id, member, item_id, lock=True)
        if row.scope != "group" or row.status != "pending":
            raise HTTPException(409, "Материал уже рассмотрен")
        row.reviewed_by = member.user_id
        row.status = "published" if body.action == "approve" else "rejected"
        key = remove_blob(db, row) if body.action == "reject" else None
        result = _json(row)
        commit_removal(db, key)
        return result

    @app.delete(path + "/{item_id}")
    def delete_material(group_id: str, item_id: str, db: DB, member: Member):
        require_group(member, group_id)
        row = _item(db, group_id, member, item_id, lock=True)
        if row.scope == "group" and not _reviewer(member):
            raise HTTPException(403, "Групповыми материалами управляет администратор")
        key = remove_blob(db, row)
        db.delete(row)
        commit_removal(db, key)
        return {"deleted": True}
